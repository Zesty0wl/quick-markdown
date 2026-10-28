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

    /// As GitHub: no smart punctuation, so quotes stay straight and `--`
    /// stays two hyphens (command-line flags in prose survive).
    static let parseOptions: ParseOptions = [.disableSmartOpts]

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
            let document = Document(parsing: cleaned, options: Self.parseOptions)
            var renderer = HTMLRenderer(baseURL: baseURL)
            let body = renderer.visit(document)
            return Self.wrapInDocument(body: body, bodyCSS: renderer.bodyCSS)
        }
        let (rewritten, equations) = Self.extractEquations(from: cleaned)
        let document = Document(parsing: rewritten, options: Self.parseOptions)
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
        let document = Document(parsing: rewritten, options: Self.parseOptions)
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
        var plainText = Self.plainText(heading)
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

    /// Collect the plain-text content by concatenating every `Text` and
    /// `InlineCode` descendant. Used for heading slugs (mirroring the input
    /// GitHub's slugger sees: emphasis and link wrappers are ignored) and
    /// for image alt text, which must not contain markup.
    private static func plainText(_ markup: any Markup) -> String {
        var out = ""
        for child in markup.children {
            if let t = child as? Markdown.Text {
                out += t.string
            } else if let c = child as? InlineCode {
                out += c.code
            } else if child is SoftBreak || child is LineBreak {
                out += " "
            } else {
                out += plainText(child)
            }
        }
        return out
    }

    /// GitHub-flavour heading slug: lowercase, strip everything that isn't
    /// a letter or number (in any script) / space / hyphen / underscore,
    /// then replace each space with a hyphen. Consecutive removed
    /// punctuation collapses into the surrounding spaces, which produces
    /// the familiar `--` runs in slugs like `part-65--sync-an-out-of-date-fork`
    /// (from `Part 6.5 — Sync an out-of-date fork`). `## Café` is `#café`.
    static func slugify(_ text: String) -> String {
        let lower = text.lowercased()
        var stripped = ""
        stripped.reserveCapacity(lower.count)
        for scalar in lower.unicodeScalars {
            let keep: Bool
            switch scalar.properties.generalCategory {
            case .lowercaseLetter, .uppercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter, .decimalNumber, .letterNumber,
                 .otherNumber, .nonspacingMark, .spacingMark:
                keep = true
            default:
                keep = scalar == "-" || scalar == "_" || scalar == " "
            }
            if keep { stripped.unicodeScalars.append(scalar) }
        }
        return stripped.replacingOccurrences(of: " ", with: "-")
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        let inner = visitChildren(paragraph)
        // As on GitHub, paragraphs directly inside a tight list's items
        // render bare, so the list isn't spaced out like a loose one.
        if let item = paragraph.parent as? ListItem, Self.isInTightList(item) {
            return inner + "\n"
        }
        return "<p style=\"\(pCSS)\">\(inner)</p>\n"
    }

    // MARK: - List tightness

    private static func isInTightList(_ item: ListItem) -> Bool {
        guard let list = item.parent else { return false }
        return isTight(list)
    }

    /// CommonMark's rule: a list is loose if any of its items are separated
    /// by blank lines, or any item directly contains two block elements
    /// with a blank line between them. swift-markdown doesn't expose cmark's
    /// tight flag, so this reads the source lines instead.
    static func isTight(_ list: any Markup) -> Bool {
        let items = Array(list.children)
        for (index, item) in items.enumerated() {
            if index + 1 < items.count, Self.blankLineBetween(item, items[index + 1]) {
                return false
            }
            let blocks = Array(item.children)
            for j in blocks.indices.dropLast() where Self.blankLineBetween(blocks[j], blocks[j + 1]) {
                return false
            }
        }
        return true
    }

    private static func blankLineBetween(_ first: any Markup, _ second: any Markup) -> Bool {
        guard let end = lastLine(of: first),
              let start = second.range?.lowerBound.line else { return false }
        return start > end + 1
    }

    /// The last source line with content: containers end where their last
    /// child does, so trailing blank lines inside an item don't count.
    private static func lastLine(of markup: any Markup) -> Int? {
        let isContainer = markup is ListItem
            || markup is UnorderedList || markup is OrderedList
        if isContainer, let last = Array(markup.children).last {
            return lastLine(of: last)
        }
        return markup.range?.upperBound.line
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
            let inlines = Array(paragraph.children)
            let rest = inlines.firstIndex(where: { $0 is SoftBreak || $0 is LineBreak })
                .map { renderSequence(inlines[($0 + 1)...], in: paragraph) } ?? ""
            if !rest.isEmpty {
                out += "<p style=\"\(pCSS)\">\(rest)</p>\n"
            }
        }
        return out + "</div>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        // The language is the info string's first word (` ```ruby startline=3 `).
        let language = codeBlock.language?
            .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard richRendering, !language.isEmpty else {
            let code = Self.escape(codeBlock.code)
            let languageClass = language.isEmpty
                ? "" : " class=\"language-\(Self.escapeAttr(language))\""
            return "<pre style=\"\(preCSS)\"><code\(languageClass)>\(code)</code></pre>\n"
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
        rewriteImageSources(in: Self.filterTags(html.rawHTML))
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
        let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
        return "<ol\(start) style=\"\(olCSS)\">\n\(inner)</ol>\n"
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
        // 2. **Inline first line.** The checkbox goes inside the first
        //    paragraph's content (bare in a tight list, inside its `<p>` in
        //    a loose one), so it sits on the same baseline as the item's
        //    text instead of on a row of its own. Matches GitHub's markup
        //    for both tight and loose task lists.
        if let checked = listItem.checkbox {
            let mark = checked == .checked ? "checked" : ""
            let taskIndex = taskItemCounter
            taskItemCounter += 1
            // `disabled` keeps the checkbox non-interactive for export
            // consumers (Word, Outlook, PDF). The live preview strips it on
            // load and wires up its own click handler — see `renderHTML` in
            // `PreviewViewController`.
            let checkbox = "<input type=\"checkbox\" \(mark) disabled data-task-index=\"\(taskIndex)\" style=\"margin-right:4px;vertical-align:middle;\"> "
            let tight = Self.isInTightList(listItem)
            var inner = ""
            var placed = false
            for child in listItem.children {
                if !placed, let paragraph = child as? Paragraph {
                    let content = checkbox + visitChildren(paragraph)
                    inner += tight ? content + "\n" : "<p style=\"\(pCSS)\">\(content)</p>\n"
                    placed = true
                } else {
                    inner += visit(child)
                }
            }
            if !placed { inner = checkbox + inner }
            return "<li class=\"task-list-item\" style=\"\(liCSS)list-style:none;\">\(inner)</li>\n"
        }
        let inner = visitChildren(listItem)
        return "<li style=\"\(liCSS)\">\(inner)</li>\n"
    }

    mutating func visitTable(_ table: Markdown.Table) -> String {
        // Column alignment goes in an `align` attribute as well as inline
        // CSS: the Preview strips `style` attributes, so the attribute is
        // what keeps `:---:` columns centred there.
        let alignments = table.columnAlignments
        func align(_ column: Int) -> (attribute: String, css: String) {
            guard column < alignments.count, let alignment = alignments[column] else {
                return ("", "")
            }
            let value: String
            switch alignment {
            case .left: value = "left"
            case .center: value = "center"
            case .right: value = "right"
            }
            return (" align=\"\(value)\"", "text-align:\(value);")
        }
        var out = "<table style=\"\(tableCSS)\">\n"
        // Header
        var head = "<thead><tr>"
        for (column, cell) in table.head.cells.enumerated() {
            let a = align(column)
            head += "<th\(a.attribute) style=\"\(thCSS)\(a.css)\">\(visitChildren(cell))</th>"
        }
        head += "</tr></thead>\n"
        out += head
        // Body (omitted when the table has no rows, as cmark does)
        let rows = Array(table.body.rows)
        if !rows.isEmpty {
            out += "<tbody>\n"
            for (i, row) in rows.enumerated() {
                let zebra = (i % 2 == 1) ? "background:#fafafa;" : ""
                out += "<tr style=\"\(zebra)\">"
                for (column, cell) in row.cells.enumerated() {
                    let a = align(column)
                    out += "<td\(a.attribute) style=\"\(tdCSS)\(a.css)\">\(visitChildren(cell))</td>"
                }
                out += "</tr>\n"
            }
            out += "</tbody>\n"
        }
        out += "</table>\n"
        return out
    }

    mutating func visitText(_ text: Markdown.Text) -> String {
        renderText(text.string, in: text.parent)
    }

    /// Escapes text and, outside links and images, turns bare URLs and
    /// email addresses into links (GitHub's extended autolinks).
    private func renderText(_ string: String, in container: (any Markup)?) -> String {
        var ancestor = container
        while let node = ancestor {
            if node is Link || node is Markdown.Image { return Self.escape(string) }
            ancestor = node.parent
        }
        return Self.autolinked(string)
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
        rewriteImageSources(in: Self.filterTags(inlineHTML.rawHTML))
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
        let href = link.destination.map { Self.escapeAttr(Self.safeURL(Self.normalizeURL($0))) } ?? ""
        let title = link.title.map { " title=\"\(Self.escapeAttr($0))\"" } ?? ""
        return "<a href=\"\(href)\"\(title) style=\"color:#0066cc;text-decoration:underline;\">\(visitChildren(link))</a>"
    }

    mutating func visitImage(_ image: Markdown.Image) -> String {
        // Alt text is plain text: markup inside `![...]` must not end up
        // in the attribute (it would break the tag).
        let alt = Self.escapeAttr(Self.plainText(image))
        let title = image.title.map { " title=\"\(Self.escapeAttr($0))\"" } ?? ""
        let rawSrc = image.source ?? ""
        let resolvedSrc: String
        if let dataURL = inlineDataURL(forSource: rawSrc) {
            resolvedSrc = dataURL
        } else {
            resolvedSrc = Self.escapeAttr(Self.normalizeURL(rawSrc))
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
        renderSequence(markup.children, in: markup)
    }

    /// Renders nodes in order, joining consecutive `Text` nodes first:
    /// cmark splits text at characters like `&`, `!` and brackets, and an
    /// autolink can span those splits.
    private mutating func renderSequence(_ nodes: some Sequence<any Markup>,
                                         in container: any Markup) -> String {
        var out = ""
        var pendingText = ""
        for child in nodes {
            if let text = child as? Markdown.Text {
                pendingText += text.string
                continue
            }
            if !pendingText.isEmpty {
                out += renderText(pendingText, in: container)
                pendingText = ""
            }
            out += visit(child)
        }
        if !pendingText.isEmpty {
            out += renderText(pendingText, in: container)
        }
        return out
    }

    // MARK: - URLs

    /// Percent-encodes a link or image destination the way cmark does:
    /// ASCII letters, digits and URL punctuation pass through (including
    /// existing `%XX` escapes); spaces, backslashes, brackets, quotes and
    /// non-ASCII bytes are encoded.
    static func normalizeURL(_ url: String) -> String {
        let safe = Set("-_.+!*'(),%#@?=;:/&$~".utf8)
        var out = ""
        out.reserveCapacity(url.utf8.count)
        for byte in url.utf8 {
            let isAlphanumeric = (0x30...0x39).contains(byte)
                || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            if isAlphanumeric || safe.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Drops script URLs from links, as GitHub does.
    static func safeURL(_ url: String) -> String {
        let scheme = url.prefix { $0 != ":" }.lowercased()
        return ["javascript", "vbscript"].contains(scheme) ? "" : url
    }

    // MARK: - Raw HTML

    /// GitHub's tag filter: these tags are shown as text rather than
    /// interpreted, so a Markdown file can't run scripts, embed frames or
    /// restyle the page.
    static func filterTags(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"<(?=/?(?:title|textarea|style|xmp|iframe|noembed|noframes|script|plaintext)(?:[\s/>]|$))"#,
            with: "&lt;",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    // MARK: - Autolinks

    /// GitHub's extended autolinks (cmark-gfm's rules): `www.` domains,
    /// `http://`, `https://` and `ftp://` URLs, email addresses, and
    /// `mailto:` / `xmpp:` addresses in plain text become links. Trailing
    /// punctuation, unbalanced closing parentheses and trailing entity-like
    /// `&name;` text stay outside the link, as on GitHub.
    static func autolinked(_ text: String) -> String {
        let chars = Array(text)
        guard chars.contains(where: { $0 == "." || $0 == ":" }),
              chars.contains(where: { $0 == "w" || $0 == ":" || $0 == "@" }) else {
            return escape(text)
        }
        var out = ""
        var plainStart = 0
        var i = 0
        while i < chars.count {
            if let match = autolinkMatch(chars, at: i) {
                out += escape(String(chars[plainStart..<i]))
                let label = String(chars[i..<(i + match.length)])
                let href = escapeAttr(normalizeURL(match.prefix + label))
                out += "<a href=\"\(href)\" style=\"color:#0066cc;text-decoration:underline;\">\(escape(label))</a>"
                i += match.length
                plainStart = i
            } else {
                i += 1
            }
        }
        out += escape(String(chars[plainStart...]))
        return out
    }

    private static func autolinkMatch(_ c: [Character], at i: Int) -> (length: Int, prefix: String)? {
        let previous: Character? = i > 0 ? c[i - 1] : nil
        let wwwBoundary = previous == nil || previous!.isWhitespace || "*_~(".contains(previous!)
        if wwwBoundary, hasPrefix(c, at: i, "www."),
           let length = extendedURLLength(c, from: i, domainStart: i, requireDot: true) {
            return (length, "http://")
        }
        // A scheme just mustn't be glued to a preceding word.
        let schemeBoundary = previous.map { !($0.isASCII && $0.isLetter) } ?? true
        if schemeBoundary {
            for scheme in ["http://", "https://", "ftp://"] where hasPrefix(c, at: i, scheme) {
                if let length = extendedURLLength(c, from: i, domainStart: i + scheme.count,
                                                  requireDot: false) {
                    return (length, "")
                }
            }
            for scheme in ["mailto:", "xmpp:"] where hasPrefix(c, at: i, scheme) {
                if let email = emailLength(c, from: i + scheme.count) {
                    var length = scheme.count + email
                    // xmpp addresses can carry a /resource.
                    if scheme == "xmpp:", i + length < c.count, c[i + length] == "/" {
                        var end = i + length + 1
                        while end < c.count, c[end].isLetter || c[end].isNumber || "@.".contains(c[end]) {
                            end += 1
                        }
                        while end > i + length + 1, c[end - 1] == "." { end -= 1 }
                        length = end - i
                    }
                    return (length, "")
                }
            }
        }
        let isLocal: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_+".contains($0)) }
        if isLocal(c[i]), previous.map({ !isLocal($0) && $0 != "@" }) ?? true,
           let length = emailLength(c, from: i) {
            return (length, "mailto:")
        }
        return nil
    }

    private static func hasPrefix(_ c: [Character], at i: Int, _ prefix: String) -> Bool {
        let p = Array(prefix)
        guard i + p.count <= c.count else { return false }
        for (k, ch) in p.enumerated() where c[i + k].lowercased() != String(ch) { return false }
        return true
    }

    private static func isDomainCharacter(_ ch: Character) -> Bool {
        !ch.isASCII || ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "."
    }

    /// Length of a URL starting at `start` whose domain begins at
    /// `domainStart`, or nil when the domain isn't valid.
    private static func extendedURLLength(_ c: [Character], from start: Int, domainStart: Int,
                                          requireDot: Bool) -> Int? {
        var end = domainStart
        while end < c.count, isDomainCharacter(c[end]) { end += 1 }
        var domainEnd = end
        while domainEnd > domainStart, c[domainEnd - 1] == "." { domainEnd -= 1 }
        let segments = String(c[domainStart..<domainEnd]).split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= (requireDot ? 2 : 1), !segments.contains(where: \.isEmpty),
              !segments.suffix(2).contains(where: { $0.contains("_") }) else { return nil }
        // The path runs to whitespace or `<`.
        while end < c.count, !c[end].isWhitespace, c[end] != "<" { end += 1 }
        // Trim trailing punctuation, unbalanced `)` and entity-like `&x;`.
        trimming: while end > domainEnd {
            let last = c[end - 1]
            if "?!.,:*_~'\"".contains(last) {
                end -= 1
            } else if last == ")" {
                let link = c[start..<end]
                if link.filter({ $0 == ")" }).count > link.filter({ $0 == "(" }).count {
                    end -= 1
                } else {
                    break trimming
                }
            } else if last == ";" {
                var k = end - 2
                while k >= start, c[k].isASCII, c[k].isLetter || c[k].isNumber { k -= 1 }
                if k >= start, c[k] == "&", k < end - 2 {
                    end = k
                } else {
                    break trimming
                }
            } else {
                break trimming
            }
        }
        return end - start
    }

    /// Length of an email address starting at `start`, or nil.
    private static func emailLength(_ c: [Character], from start: Int) -> Int? {
        var at = start
        while at < c.count, c[at].isASCII, c[at].isLetter || c[at].isNumber || ".-_+".contains(c[at]) { at += 1 }
        guard at > start, at < c.count, c[at] == "@" else { return nil }
        var end = at + 1
        while end < c.count, c[end].isASCII, c[end].isLetter || c[end].isNumber || "-_.".contains(c[end]) { end += 1 }
        while end > at + 1, c[end - 1] == "." { end -= 1 }
        let domain = String(c[(at + 1)..<end])
        let segments = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2, !segments.contains(where: \.isEmpty),
              let last = domain.last, last != "-", last != "_" else { return nil }
        return end - start
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
