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
        // Match the live preview's preprocessing: drop YAML front matter and
        // rewrite Docs/Learn `:::image:::` directives into standard Markdown
        // images so the rest of the pipeline picks them up.
        let cleaned = MarkdownAttributedRenderer.rewriteDocsImageDirectives(
            in: MarkdownAttributedRenderer.stripFrontMatter(markdown)
        )
        let document = Document(parsing: cleaned)
        var renderer = HTMLRenderer(baseURL: baseURL)
        let body = renderer.visit(document)
        return Self.wrapInDocument(body: body, bodyCSS: renderer.bodyCSS)
    }

    /// Render just the inner-body HTML (no `<html>`/`<head>` wrapper).
    /// Used by `PreviewViewController` which supplies its own themed wrapper.
    static func renderBody(_ markdown: String, baseURL: URL? = nil) -> String {
        let document = Document(parsing: markdown)
        var renderer = HTMLRenderer(baseURL: baseURL)
        return renderer.visit(document)
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
        return "<h\(heading.level) style=\"\(css)\">\(inner)</h\(heading.level)>\n"
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
        // Pass raw HTML through unchanged (matches CommonMark semantics).
        html.rawHTML
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
        let inner = visitChildren(listItem)
        if let checked = listItem.checkbox {
            let mark = checked == .checked ? "checked" : ""
            return "<li style=\"\(liCSS)list-style:none;\"><input type=\"checkbox\" \(mark) disabled style=\"margin-right:6px;\">\(inner)</li>\n"
        }
        return "<li style=\"\(liCSS)\">\(inner)</li>\n"
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
        inlineHTML.rawHTML
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
        return "<img src=\"\(resolvedSrc)\" alt=\"\(alt)\"\(title) style=\"max-width:100%;height:auto;display:block;margin:8px 0;\">"
    }

    // MARK: - Image inlining

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
        let encoded = source.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? source
        if let resolved = URL(string: encoded, relativeTo: baseURL)?.absoluteURL,
           resolved.isFileURL {
            return resolved
        }
        return baseURL.appendingPathComponent(source)
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
