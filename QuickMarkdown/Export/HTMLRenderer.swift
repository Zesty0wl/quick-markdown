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

    /// Per-base-slug occurrence counts so duplicate headings get distinct
    /// ids the way GitHub numbers them (`title`, `title-1`, `title-2`, ...).
    private var headingSlugCounts: [String: Int] = [:]

    /// When true, fenced code blocks with a known language are coloured
    /// with the bundled Highlight.js, and alerts get their icons. Off for
    /// the pasteboard, where Word and Outlook mangle both.
    private let richRendering: Bool

    /// Equations swapped out for placeholder tokens before parsing. Kept so
    /// heading slugs use the TeX source rather than the token.
    private let equations: [Equation]

    private init(baseURL: URL?, richRendering: Bool, equations: [Equation]) {
        self.baseURL = baseURL
        self.richRendering = richRendering
        self.equations = equations
    }

    init(baseURL: URL? = nil) {
        self.init(baseURL: baseURL, richRendering: false, equations: [])
    }

    // MARK: - Style strings (inline CSS)

    private let bodyCSS = "font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',Helvetica,Arial,sans-serif;font-size:16px;line-height:1.6;color:#1d1d1f;max-width:740px;margin:0 auto;"
    /// Wrapper for a fragment copied out of the live preview. Same font,
    /// size and leading as `bodyCSS` but deliberately **no colour**: the
    /// fragment is pasted into someone else's document, and any explicit
    /// text or background colour fights the receiving app's theme (most
    /// visibly as grey paragraph boxes in a dark-mode mail compose window).
    static let selectionFragmentCSS = "font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',Helvetica,Arial,sans-serif;font-size:16px;line-height:1.6;"
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

    /// - Parameter richRendering: highlight code and typeset `$…$` / `$$…$$`
    ///   equations. PDF export wants this. The pasteboard does not: Word and
    ///   Outlook drop `<style>` blocks, and KaTeX markup without its
    ///   stylesheet pastes as duplicated, jumbled text, so equations stay as
    ///   their TeX source there.
    static func renderDocument(_ markdown: String,
                               baseURL: URL? = nil,
                               richRendering: Bool = false) -> String {
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
        guard richRendering else {
            let document = Document(parsing: cleaned)
            var renderer = HTMLRenderer(baseURL: baseURL)
            let body = renderer.visit(document)
            return Self.wrapInDocument(body: body, bodyCSS: renderer.bodyCSS)
        }
        let (rewritten, equations) = Self.extractEquations(from: cleaned)
        let document = Document(parsing: rewritten)
        var renderer = HTMLRenderer(baseURL: baseURL,
                                    richRendering: true,
                                    equations: equations)
        let body = Self.restoreEquations(equations, in: renderer.visit(document))
        return Self.wrapInDocument(body: body,
                                   bodyCSS: renderer.bodyCSS,
                                   css: Self.richContentCSS(for: body, prefersDark: false))
    }

    /// Render just the inner-body HTML (no `<html>`/`<head>` wrapper).
    /// Used by `PreviewViewController` which supplies its own themed CSS.
    /// Inline `style` attributes are stripped so the preview stylesheet
    /// controls all visual presentation (colors, padding, column widths).
    /// Equations go back in after the strip, because KaTeX positions its
    /// glyphs with inline styles.
    static func renderBody(_ markdown: String, baseURL: URL? = nil) -> String {
        let (rewritten, equations) = Self.extractEquations(from: markdown)
        let document = Document(parsing: rewritten)
        var renderer = HTMLRenderer(baseURL: baseURL,
                                    richRendering: true,
                                    equations: equations)
        let raw = renderer.visit(document)
        let stripped = raw.replacingOccurrences(
            of: #" style="[^"]*""#,
            with: "",
            options: .regularExpression
        )
        return Self.restoreEquations(equations, in: stripped)
    }

    /// Highlight.js, Mermaid and KaTeX stylesheets for a rendered body, included only
    /// when the body uses them. KaTeX's carries its fonts inline and is
    /// several hundred KB, too much to add to every page.
    static func richContentCSS(for body: String, prefersDark: Bool) -> String {
        var css = ""
        if body.contains("class=\"hljs") {
            css += WebAssets.highlightCSS(prefersDark: prefersDark)
            // Match Highlight.js's `pre code.hljs` specificity so code
            // blocks keep the app's own padding and background.
            css += "\npre code.hljs{background:transparent;color:inherit;padding:0;}\n"
        }
        if body.contains("language-mermaid") {
            css += WebAssets.mermaidCSS + "\n"
        }
        if body.contains("class=\"katex") {
            css += WebAssets.katexCSS
            css += "\n.katex-display{overflow-x:auto;overflow-y:hidden;padding:0.25em 0;}\n"
        }
        return css
    }

    private static func wrapInDocument(body: String, bodyCSS: String, css: String = "") -> String {
        let style = css.isEmpty ? "" : "<style>\(css)</style>"
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">\(style)</head><body style="\(bodyCSS)">\(body)</body></html>
        """
    }

    // MARK: - Equations

    struct Equation {
        let token: String
        let source: String
        let html: String
    }

    /// Swaps each `$…$` / `$$…$$` equation for a plain-text token before the
    /// Markdown parser runs, so the KaTeX markup (whose MathML annotation
    /// repeats the TeX, `_` and `*` included) is never read as Markdown.
    private static func extractEquations(from markdown: String) -> (String, [Equation]) {
        let prefix = "QMEquation" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var equations: [Equation] = []
        let rewritten = MarkdownMathRewriter.rewrite(markdown) { expression, displayMode in
            guard let html = WebRenderingEngines.renderEquation(expression, displayMode: displayMode) else {
                return nil
            }
            let token = prefix + String(equations.count) + "End"
            equations.append(Equation(token: token, source: expression, html: html))
            return token
        }
        return (rewritten, equations)
    }

    private static func restoreEquations(_ equations: [Equation], in html: String) -> String {
        var html = html
        for equation in equations {
            html = html.replacingOccurrences(of: equation.token, with: equation.html)
        }
        return html
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
        var plainText = Self.headingPlainText(heading)
        for equation in equations {
            plainText = plainText.replacingOccurrences(of: equation.token, with: equation.source)
        }
        let baseSlug = Self.slugify(plainText)
        let occurrence = headingSlugCounts[baseSlug, default: 0]
        headingSlugCounts[baseSlug] = occurrence + 1
        let slug = occurrence == 0 ? baseSlug : "\(baseSlug)-\(occurrence)"
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
        if let alert = Self.alertKind(of: blockQuote) {
            return renderAlert(blockQuote, kind: alert)
        }
        let inner = visitChildren(blockQuote)
        return "<blockquote style=\"\(blockquoteCSS)\">\(inner)</blockquote>\n"
    }

    // MARK: - Alerts

    /// GitHub-style alerts: a block quote whose first line is exactly
    /// `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]`
    /// (any case). Rendered like GitHub's: a coloured bar and a titled
    /// header with the matching Octicon.
    enum AlertKind: String, CaseIterable {
        case note, tip, important, warning, caution

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        /// GitHub's light-theme colour, used inline for export.
        var color: String {
            switch self {
            case .note: "#0969da"
            case .tip: "#1a7f37"
            case .important: "#8250df"
            case .warning: "#9a6700"
            case .caution: "#d1242f"
            }
        }

        /// GitHub's dark-theme colour, for the Preview on dark themes.
        var darkColor: String {
            switch self {
            case .note: "#4493f8"
            case .tip: "#3fb950"
            case .important: "#ab7df8"
            case .warning: "#d29922"
            case .caution: "#f85149"
            }
        }

        /// Octicon path (16×16): info, light-bulb, report, alert, stop.
        var iconPath: String {
            switch self {
            case .note:
                "M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"
            case .tip:
                "M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z"
            case .important:
                "M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"
            case .warning:
                "M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"
            case .caution:
                "M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"
            }
        }
    }

    /// The alert type when the quote's first line is just the marker.
    private static func alertKind(of blockQuote: BlockQuote) -> AlertKind? {
        guard let paragraph = blockQuote.child(at: 0) as? Paragraph else { return nil }
        var marker = ""
        for inline in paragraph.inlineChildren {
            if inline is SoftBreak || inline is LineBreak { break }
            guard let text = inline as? Markdown.Text else { return nil }
            marker += text.string
        }
        let trimmed = marker.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]") else { return nil }
        return AlertKind(rawValue: trimmed.dropFirst(2).dropLast().lowercased())
    }

    private mutating func renderAlert(_ blockQuote: BlockQuote, kind: AlertKind) -> String {
        let icon = richRendering
            ? "<svg class=\"qm-alert-icon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path fill=\"currentColor\" d=\"\(kind.iconPath)\"></path></svg>"
            : ""
        var out = "<div class=\"qm-alert qm-alert-\(kind.rawValue)\" style=\"border-left:4px solid \(kind.color);margin:0 0 16px 0;padding:0 0 0 16px;\">"
        out += "<p class=\"qm-alert-title\" style=\"color:\(kind.color);font-weight:600;margin:0 0 8px 0;\">\(icon)\(kind.title)</p>"
        for (index, child) in blockQuote.children.enumerated() {
            guard index == 0, let paragraph = child as? Paragraph else {
                out += visit(child)
                continue
            }
            // Drop the marker line; keep the rest of the first paragraph.
            var rest = ""
            var pastMarker = false
            for inline in paragraph.inlineChildren {
                if pastMarker {
                    rest += visit(inline)
                } else if inline is SoftBreak || inline is LineBreak {
                    pastMarker = true
                }
            }
            if !rest.isEmpty {
                out += "<p style=\"\(pCSS)\">\(rest)</p>\n"
            }
        }
        return out + "</div>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let language = codeBlock.language?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        guard richRendering, !language.isEmpty else {
            let code = Self.escape(codeBlock.code)
            return "<pre style=\"\(preCSS)\"><code>\(code)</code></pre>\n"
        }
        // Unknown languages fall back to plain, escaped text. `mermaid`
        // is one of them; `MermaidRenderer` swaps those blocks for SVG
        // diagrams once the page has loaded.
        let code = WebRenderingEngines.highlight(codeBlock.code, language: language)
            ?? Self.escape(codeBlock.code)
        return "<pre style=\"\(preCSS)\"><code class=\"hljs language-\(Self.escapeAttr(language))\">\(code)</code></pre>\n"
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
