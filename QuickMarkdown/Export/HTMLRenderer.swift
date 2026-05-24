import AppKit
import Markdown

/// Renders a swift-markdown AST to a complete HTML document with **inline CSS only**.
/// No `<style>` blocks and no external stylesheets — required for Outlook for
/// Mac and Microsoft Word to keep formatting after paste (PRD §7.1).
///
/// Phase 4 supports the GFM subset we render in the live preview:
/// headings, paragraphs, emphasis, strong, strikethrough, code (inline & block),
/// blockquote, lists (ordered/unordered, task lists), tables, links, images,
/// thematic breaks, hard line breaks.
struct HTMLRenderer: MarkupVisitor {

    typealias Result = String

    /// Used to resolve relative image `src` values to on-disk files so they
    /// can be inlined as `data:` URLs. When `nil`, relative images fall back
    /// to their original `src` (which may not load in downstream consumers).
    private let baseURL: URL?

    /// Running count of task-list items encountered during the AST walk.
    /// Stamped onto each task `<input>` as `data-task-index="N"` so the live
    /// preview can map a click back to the Nth `- [ ]` / `- [x]` marker in
    /// the source. (Export consumers like Word / PDF ignore the attribute.)
    private var taskItemCounter: Int = 0

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL
    }

    // MARK: - Style strings (inline CSS)

    private let bodyCSS = "font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',Helvetica,Arial,sans-serif;font-size:16px;line-height:1.6;color:#1d1d1f;max-width:740px;margin:0 auto;"
    private let codeCSS = "font-family:'SF Mono',Menlo,Monaco,Consolas,monospace;font-size:14px;background:#f5f5f5;color:#1d1d1f;border-radius:4px;padding:2px 4px;"
    private let preCSS = "font-family:'SF Mono',Menlo,Monaco,Consolas,monospace;font-size:14px;background:#f5f5f5;color:#1d1d1f;border:1px solid #e0e0e0;border-radius:4px;padding:8px;overflow:auto;line-height:1.45;"
    private let blockquoteCSS = "border-left:3px solid #007aff;margin:0 0 16px 0;padding:0 0 0 16px;color:#3c3c43;font-style:italic;"
    private let h1CSS = "font-size:32px;font-weight:700;margin:24px 0 8px 0;line-height:1.3;"
    private let h2CSS = "font-size:24px;font-weight:600;margin:24px 0 8px 0;line-height:1.3;"
    private let h3CSS = "font-size:20px;font-weight:600;margin:20px 0 8px 0;line-height:1.3;"
    private let h4CSS = "font-size:18px;font-weight:600;margin:16px 0 8px 0;"
    private let h5CSS = "font-size:16px;font-weight:600;margin:16px 0 8px 0;"
    private let h6CSS = "font-size:15px;font-weight:600;margin:16px 0 8px 0;color:#3c3c43;"
    private let pCSS  = "margin:0 0 12px 0;"
    private let ulCSS = "margin:0 0 12px 0;padding-left:24px;"
    private let olCSS = "margin:0 0 12px 0;padding-left:24px;"
    private let liCSS = "margin:0 0 4px 0;"
    private let tableCSS = "border-collapse:collapse;margin:0 0 16px 0;width:auto;"
    private let thCSS = "border:1px solid #e0e0e0;padding:6px 10px;background:#f5f5f5;text-align:left;font-weight:600;"
    private let tdCSS = "border:1px solid #e0e0e0;padding:6px 10px;text-align:left;"
    private let hrCSS = "border:none;border-top:1px solid #e0e0e0;margin:24px 0;"

    // MARK: - Public entry point

    static func renderDocument(_ markdown: String, baseURL: URL? = nil) -> String {
        // Match the live preview's preprocessing: drop YAML front matter,
        // rewrite Docs/Learn `:::image:::` directives into standard Markdown
        // images, and rewrite GFM-style `[^foo]` footnotes (which swift-
        // markdown doesn't parse) into inline HTML refs + a footnotes
        // section, so the rest of the pipeline picks them up.
        let cleaned = MarkdownAttributedRenderer.rewriteFootnotes(
            in: MarkdownAttributedRenderer.rewriteDocsImageDirectives(
                in: MarkdownAttributedRenderer.stripFrontMatter(markdown)
            ),
            style: .html
        )
        let document = Document(parsing: cleaned)
        var renderer = HTMLRenderer(baseURL: baseURL)
        let body = renderer.visit(document)
        return Self.wrapInDocument(body: body, bodyCSS: renderer.bodyCSS)
    }

    /// Render just the inner-body HTML (no `<html>`/`<head>` wrapper).
    /// Used by `PreviewViewController` which supplies its own themed CSS.
    /// Inline `style` attributes are stripped so the preview stylesheet
    /// controls all visual presentation (colors, padding, column widths).
    static func renderBody(_ markdown: String, baseURL: URL? = nil) -> String {
        let document = Document(parsing: markdown)
        var renderer = HTMLRenderer(baseURL: baseURL)
        let raw = renderer.visit(document)
        return raw.replacingOccurrences(
            of: #" style="[^"]*""#,
            with: "",
            options: .regularExpression
        )
    }

    private static func wrapInDocument(body: String, bodyCSS: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head><body style="\(bodyCSS)">\(body)</body></html>
        """
    }

    // MARK: - Default

    mutating func defaultVisit(_ markup: any Markup) -> String {
        var out = ""
        for child in markup.children {
            out += visit(child)
        }
        return out
    }

    // MARK: - Blocks

    mutating func visitHeading(_ heading: Heading) -> String {
        let inner = visitChildren(heading)
        let css: String
        switch heading.level {
        case 1: css = h1CSS
        case 2: css = h2CSS
        case 3: css = h3CSS
        case 4: css = h4CSS
        case 5: css = h5CSS
        default: css = h6CSS
        }
        // Emit a GitHub-flavour slug as the heading's `id` so in-document
        // fragment links (`[See later](#section-name)`, GitHub TOCs, etc.)
        // actually scroll the preview. swift-markdown doesn't auto-generate
        // these — without them the WKWebView resolves the fragment URL but
        // finds nothing to anchor to, and the click silently no-ops.
        let slug = Self.slugify(Self.headingPlainText(heading))
        let idAttr = slug.isEmpty ? "" : " id=\"\(Self.escapeAttr(slug))\""
        return "<h\(heading.level)\(idAttr) style=\"\(css)\">\(inner)</h\(heading.level)>\n"
    }

    /// Collect the heading's plain-text content by concatenating every
    /// `Text` and `InlineCode` descendant. Mirrors the input that GitHub's
    /// slugger sees (it ignores emphasis / link wrappers and uses the
    /// rendered text).
    private static func headingPlainText(_ markup: any Markup) -> String {
        var out = ""
        for child in markup.children {
            if let t = child as? Markdown.Text {
                out += t.string
            } else if let c = child as? InlineCode {
                out += c.code
            } else {
                out += headingPlainText(child)
            }
        }
        return out
    }

    /// GitHub-flavour heading slug: lowercase, strip everything that isn't
    /// alphanumeric / space / hyphen / underscore, then replace each space
    /// with a hyphen. Consecutive removed punctuation collapses into the
    /// surrounding spaces, which produces the familiar `--` runs in
    /// slugs like `part-65--sync-an-out-of-date-fork` (from
    /// `Part 6.5 — Sync an out-of-date fork`).
    static func slugify(_ text: String) -> String {
        let lower = text.lowercased()
        var stripped = ""
        stripped.reserveCapacity(lower.count)
        for scalar in lower.unicodeScalars {
            if (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || scalar == "-" || scalar == "_" || scalar == " " {
                stripped.unicodeScalars.append(scalar)
            }
        }
        return stripped.replacingOccurrences(of: " ", with: "-")
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        let inner = visitChildren(paragraph)
        return "<p style=\"\(pCSS)\">\(inner)</p>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        let inner = visitChildren(blockQuote)
        return "<blockquote style=\"\(blockquoteCSS)\">\(inner)</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let code = Self.escape(codeBlock.code)
        return "<pre style=\"\(preCSS)\"><code>\(code)</code></pre>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        // Pass raw HTML through, but rewrite any `<img src="…">` so local
        // sources are base64-inlined the same way Markdown `![]()` images
        // are. Without this, an `<img>` inside a `<div align="center">`
        // (commonly used for centred README hero shots) renders as a
        // broken-image placeholder in the sandboxed preview because
        // WKWebView can't pick the file up off disk.
        rewriteImageSources(in: html.rawHTML)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr style=\"\(hrCSS)\">\n"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        let inner = visitChildren(list)
        return "<ul style=\"\(ulCSS)\">\n\(inner)</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        let inner = visitChildren(list)
        return "<ol style=\"\(olCSS)\">\n\(inner)</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        // Task list items (GFM `- [ ]` / `- [x]`) need two things to render
        // correctly in both the preview WebView and downstream consumers
        // like Word / Outlook:
        //
        // 1. **No bullet.** We hide it via inline `list-style:none;` for the
        //    export pipeline AND via a `task-list-item` class for the live
        //    preview, because `PreviewViewController.renderBody()` strips
        //    all inline `style="..."` attributes (so the class is the only
        //    thing that survives the round-trip).
        // 2. **Inline first line.** swift-markdown wraps every list item's
        //    text in a `Paragraph`, which becomes a block-level `<p>`. An
        //    inline `<input type="checkbox">` followed by a block `<p>`
        //    breaks onto two lines — the checkbox sits on its own row and
        //    the item text drops below it. To keep the checkbox on the same
        //    baseline as its title we unwrap the FIRST paragraph child
        //    (rendering its inline content directly) and emit any
        //    subsequent block children (code blocks, additional paragraphs,
        //    nested lists for loose items) as-is. Matches GitHub's
        //    rendering for both tight and loose task lists.
        if let checked = listItem.checkbox {
            let inner = unwrapLeadingParagraph(of: listItem)
            let mark = checked == .checked ? "checked" : ""
            let taskIndex = taskItemCounter
            taskItemCounter += 1
            // `disabled` keeps the checkbox non-interactive for export
            // consumers (Word, Outlook, PDF). The live preview strips it on
            // load and wires up its own click handler — see `renderHTML` in
            // `PreviewViewController`.
            return "<li class=\"task-list-item\" style=\"\(liCSS)list-style:none;\"><input type=\"checkbox\" \(mark) disabled data-task-index=\"\(taskIndex)\" style=\"margin-right:6px;vertical-align:middle;\">\(inner)</li>\n"
        }
        let inner = visitChildren(listItem)
        return "<li style=\"\(liCSS)\">\(inner)</li>\n"
    }

    /// Renders a list item's children with the first child unwrapped if it
    /// is a `Paragraph` — emit its inline content directly instead of
    /// wrapping it in `<p>`. This keeps the leading text inline with
    /// whatever marker the `<li>` starts with (the GFM task-list checkbox,
    /// in our case) instead of dropping it onto a new line. Block children
    /// after the first paragraph (code blocks, additional paragraphs,
    /// nested lists) are emitted normally.
    private mutating func unwrapLeadingParagraph(of listItem: ListItem) -> String {
        var out = ""
        var didUnwrap = false
        for child in listItem.children {
            if !didUnwrap, let para = child as? Paragraph {
                out += visitChildren(para)
                didUnwrap = true
            } else {
                out += visit(child)
            }
        }
        return out
    }

    mutating func visitTable(_ table: Markdown.Table) -> String {
        var out = "<table style=\"\(tableCSS)\">\n"
        // Header
        var head = "<thead><tr>"
        for cell in table.head.cells {
            head += "<th style=\"\(thCSS)\">\(visitChildren(cell))</th>"
        }
        head += "</tr></thead>\n"
        out += head
        // Body
        out += "<tbody>\n"
        for (i, row) in table.body.rows.enumerated() {
            let zebra = (i % 2 == 1) ? "background:#fafafa;" : ""
            out += "<tr style=\"\(zebra)\">"
            for cell in row.cells {
                out += "<td style=\"\(tdCSS)\">\(visitChildren(cell))</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody>\n</table>\n"
        return out
    }

    // MARK: - Inlines

    mutating func visitText(_ text: Markdown.Text) -> String {
        Self.escape(text.string)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { " " }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "<br>" }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code style=\"\(codeCSS)\">\(Self.escape(inlineCode.code))</code>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        // Same image-inlining treatment as `visitHTMLBlock` so inline
        // `<img>` tags (e.g. inside a paragraph) also resolve to base64
        // data URLs in the sandboxed preview.
        rewriteImageSources(in: inlineHTML.rawHTML)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(visitChildren(emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(visitChildren(strong))</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(visitChildren(strikethrough))</del>"
    }

    mutating func visitLink(_ link: Link) -> String {
        let href = link.destination.map { Self.escapeAttr($0) } ?? ""
        let title = link.title.map { " title=\"\(Self.escapeAttr($0))\"" } ?? ""
        return "<a href=\"\(href)\"\(title) style=\"color:#0066cc;text-decoration:underline;\">\(visitChildren(link))</a>"
    }

    mutating func visitImage(_ image: Markdown.Image) -> String {
        let altRaw = visitChildren(image)
        let alt = altRaw // already escaped by visitText
        let title = image.title.map { " title=\"\(Self.escapeAttr($0))\"" } ?? ""
        let rawSrc = image.source ?? ""
        let resolvedSrc: String
        if let dataURL = inlineDataURL(forSource: rawSrc) {
            resolvedSrc = dataURL
        } else {
            resolvedSrc = Self.escapeAttr(rawSrc)
        }
        // `display:inline-block` (not `block`) so consecutive images in a
        // single paragraph — most obviously a row of README badges — flow
        // inline the way GitHub and most CommonMark renderers display them.
        // `vertical-align:middle` removes the baseline gap that inline-level
        // images otherwise leave below themselves. Standalone images still
        // sit on their own line because the surrounding `<p>` is block.
        return "<img src=\"\(resolvedSrc)\" alt=\"\(alt)\"\(title) style=\"max-width:100%;height:auto;display:inline-block;vertical-align:middle;\">"
    }

    // MARK: - Image inlining

    /// Find every `<img src="…">` (or single-quoted variant) in `raw` and
    /// rewrite the `src` to a `data:` URL when it resolves to a readable
    /// local file. Used by both `visitHTMLBlock` (block-level raw HTML) and
    /// `visitInlineHTML` (inline raw HTML) so raw-HTML images get the same
    /// sandbox-friendly inlining treatment as Markdown `![]()` images.
    /// Remote sources, data: URLs, and unresolved paths are left alone.
    private func rewriteImageSources(in raw: String) -> String {
        let pattern = #"(<img\b[^>]*?\bsrc\s*=\s*)(?:"([^"]+)"|'([^']+)')([^>]*>)"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return raw
        }
        let ns = raw as NSString
        let matches = regex.matches(
            in: raw,
            range: NSRange(location: 0, length: ns.length)
        )
        if matches.isEmpty { return raw }
        var out = ""
        out.reserveCapacity(raw.count)
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(
                location: cursor,
                length: m.range.location - cursor
            ))
            let prefix = ns.substring(with: m.range(at: 1))
            let dqRange = m.range(at: 2)
            let sqRange = m.range(at: 3)
            let src: String
            if dqRange.location != NSNotFound {
                src = ns.substring(with: dqRange)
            } else if sqRange.location != NSNotFound {
                src = ns.substring(with: sqRange)
            } else {
                src = ""
            }
            let suffix = ns.substring(with: m.range(at: 4))
            let newSrc = inlineDataURL(forSource: src) ?? src
            // Always re-emit with double quotes for consistency.
            out += "\(prefix)\"\(Self.escapeAttr(newSrc))\"\(suffix)"
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Resolve `source` (URL/path) against `baseURL`, read the bytes, and
    /// return a `data:<mime>;base64,...` URL. Returns nil for remote sources,
    /// for `data:` URLs already, or when the file cannot be read.
    private func inlineDataURL(forSource source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" || scheme == "data" {
            return nil
        }
        guard let url = Self.resolveLocalURL(source: trimmed, baseURL: baseURL),
              FileManager.default.isReadableFile(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let mime = Self.mimeType(forPathExtension: url.pathExtension.lowercased())
        let b64 = data.base64EncodedString()
        return "data:\(mime);base64,\(b64)"
    }

    /// Mirror of `ImageLoader.resolveLocalURL` so HTML rendering does not have
    /// to depend on TextKit's image attachment loader.
    private static func resolveLocalURL(source: String, baseURL: URL?) -> URL? {
        if source.hasPrefix("file://"), let url = URL(string: source) {
            return url
        }
        if source.hasPrefix("/") {
            return URL(fileURLWithPath: source)
        }
        guard let baseURL else { return nil }
        // Normalise the source: decode any existing percent-encoding (so a
        // pre-encoded `media/night%20sky.png` written by the author becomes
        // `media/night sky.png`), then re-encode for URL parsing. Without
        // the decode step `addingPercentEncoding` treats the leading `%`
        // as a literal and produces `%2520`, which resolves to a file that
        // doesn't exist on disk.
        let decoded = source.removingPercentEncoding ?? source
        let encoded = decoded.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? source
        if let resolved = URL(string: encoded, relativeTo: baseURL)?.absoluteURL,
           resolved.isFileURL {
            return resolved
        }
        return baseURL.appendingPathComponent(decoded)
    }

    private static func mimeType(forPathExtension ext: String) -> String {
        switch ext {
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "heic", "heif": return "image/heic"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Helpers

    private mutating func visitChildren(_ markup: any Markup) -> String {
        var out = ""
        for child in markup.children {
            out += visit(child)
        }
        return out
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func escapeAttr(_ s: String) -> String {
        escape(s)
    }
}
