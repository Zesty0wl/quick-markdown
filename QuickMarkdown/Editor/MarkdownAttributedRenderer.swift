import AppKit
import Markdown

/// Renders a Markdown source string into an `NSAttributedString` suitable for
/// a read-only preview view. Unlike `MarkdownTextStorage` (which keeps the
/// raw source visible and layers attributes on top), this renderer produces
/// fully rendered output: `#` markers, `**` wrappers, `[label](url)` syntax,
/// list bullets, etc. are NOT present in the result string.
///
/// YAML front matter (a `---` fence at the top of the document) is stripped
/// before parsing so it doesn't appear in the preview.
///
/// `@MainActor`-isolated because it instantiates `NSTextAttachment` /
/// `NSImage` for inline image rendering, both of which are main-actor types
/// in the macOS 14+ SDK.
@MainActor
struct MarkdownAttributedRenderer: @preconcurrency MarkupVisitor {

    typealias Result = NSAttributedString

    /// Folder URL the document was loaded from, used to resolve relative
    /// image paths (e.g. `media/diagram.svg`). `nil` for untitled docs —
    /// inline images fall back to a text placeholder in that case.
    private let baseURL: URL?

    /// When `true`, list items are rendered with `NSTextList` paragraph
    /// attributes (no inline `• ` / `1. ` marker text in the string) so that
    /// AppKit's RTF serializer emits a proper `\listtable` and Word for
    /// Mac / Outlook tag the paragraphs as List Bullet / List Number
    /// instead of treating the marker as literal text.
    ///
    /// `false` keeps the preview behaviour (marker characters baked into
    /// the string with a single-level indent paragraph style).
    private let forPasteboard: Bool

    /// Active NSTextList ancestor chain while a list subtree is being
    /// visited. Outermost first. Only populated when `forPasteboard == true`.
    private var listStack: [NSTextList] = []

    init(baseURL: URL? = nil, forPasteboard: Bool = false) {
        self.baseURL = baseURL
        self.forPasteboard = forPasteboard
    }

    // MARK: - Public entry point

    static func render(_ source: String, baseURL: URL? = nil) -> NSAttributedString {
        let cleaned = rewriteDocsImageDirectives(in: stripFrontMatter(source))
        let document = Document(parsing: cleaned, options: [.parseBlockDirectives])
        var renderer = MarkdownAttributedRenderer(baseURL: baseURL)
        let body = NSMutableAttributedString(attributedString: renderer.visit(document))
        // Trim trailing blank-paragraph padding so the preview doesn't end
        // with a huge gutter.
        while body.length > 0,
              body.string.hasSuffix("\n\n") {
            body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1))
        }
        return body
    }

    /// Renders Markdown to an `NSAttributedString` tuned for the system
    /// pasteboard's RTF flavour. Differs from `render(_:baseURL:)` only in
    /// list handling: each list item carries an `NSTextList` in its
    /// paragraph style so Word / Outlook tag the paragraph as a real list
    /// item instead of pasting literal "- " text.
    static func renderForPasteboard(_ source: String,
                                    baseURL: URL? = nil) -> NSAttributedString {
        let cleaned = rewriteDocsImageDirectives(in: stripFrontMatter(source))
        let document = Document(parsing: cleaned, options: [.parseBlockDirectives])
        var renderer = MarkdownAttributedRenderer(baseURL: baseURL, forPasteboard: true)
        let body = NSMutableAttributedString(attributedString: renderer.visit(document))
        while body.length > 0,
              body.string.hasSuffix("\n\n") {
            body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1))
        }
        return body
    }

    /// swift-markdown's `BlockDirective` parser uses the `@name(args) { body }`
    /// shape and doesn't recognise Microsoft Docs / Learn's triple-colon
    /// fenced syntax (`:::image type="content" source="…" alt-text="…":::`).
    /// We rewrite those lines into standard `![alt](src)` Markdown images so
    /// the rest of the pipeline (resolution, attachment, fallback) just works.
    ///
    /// Supports both the single-line self-closing form (`:::image …:::`) and
    /// the multi-line form terminated by a bare `:::` on its own line.
    nonisolated static func rewriteDocsImageDirectives(in source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix(":::image") {
                // Gather the directive body so we can extract attributes
                // even if the closing `:::` is on a later line.
                var body = trimmed
                var consumed = 1
                if !body.hasSuffix(":::") || body == ":::image" {
                    while i + consumed < lines.count {
                        let next = lines[i + consumed].trimmingCharacters(in: .whitespaces)
                        consumed += 1
                        if next == ":::" || next.hasSuffix(":::") {
                            body += " " + next
                            break
                        }
                        body += " " + next
                    }
                }
                let attrs = parseDocsDirectiveAttributes(body)
                if let src = attrs["source"] {
                    let alt = attrs["alt-text"] ?? ""
                    let escapedAlt = alt
                        .replacingOccurrences(of: "[", with: "\\[")
                        .replacingOccurrences(of: "]", with: "\\]")
                    // Surround with blank lines so the resulting `![]()` is
                    // its own paragraph (block-level image).
                    if let last = out.last, !last.isEmpty { out.append("") }
                    out.append("![\(escapedAlt)](\(src))")
                    out.append("")
                    i += consumed
                    continue
                }
            }
            out.append(line)
            i += 1
        }
        return out.joined(separator: "\n")
    }

    /// Pulls `name="value"` pairs out of a Docs/Learn directive body. Quotes
    /// can be straight `"` or curly `“ ”`. Unquoted values terminate at
    /// whitespace.
    nonisolated static func parseDocsDirectiveAttributes(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        // Strip the leading `:::image` and trailing `:::` so we just look at
        // the attribute span.
        var s = body
        if let r = s.range(of: ":::image", options: .caseInsensitive) {
            s.removeSubrange(s.startIndex..<r.upperBound)
        }
        if s.hasSuffix(":::") {
            s = String(s.dropLast(3))
        }
        // Tokenise: greedy name="value" pairs.
        let pattern = #"([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(?:"([^"]*)"|“([^”]*)”|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return result
        }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            var value = ""
            for idx in 2...4 {
                let r = m.range(at: idx)
                if r.location != NSNotFound {
                    value = ns.substring(with: r)
                    break
                }
            }
            result[name] = value
        }
        return result
    }

    /// Drops a leading YAML front-matter block (delimited by `---` lines) so
    /// it doesn't bleed into the rendered preview.
    nonisolated static func stripFrontMatter(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---"
        else {
            return source
        }
        for i in 1..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                let rest = lines[(i + 1)...].joined(separator: "\n")
                return rest.trimmingCharacters(in: .newlines) + "\n"
            }
        }
        return source
    }

    // MARK: - Default

    mutating func defaultVisit(_ markup: any Markup) -> NSAttributedString {
        renderChildren(markup)
    }

    private mutating func renderChildren(_ markup: any Markup) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in markup.children {
            result.append(visit(child))
        }
        return result
    }

    // MARK: - Inlines

    mutating func visitText(_ text: Markdown.Text) -> NSAttributedString {
        NSAttributedString(string: text.string, attributes: bodyAttributes)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSAttributedString {
        NSAttributedString(string: " ", attributes: bodyAttributes)
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: bodyAttributes)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
        let inner = NSMutableAttributedString(attributedString: renderChildren(emphasis))
        applyTrait(.italicFontMask, to: inner)
        return inner
    }

    mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
        let inner = NSMutableAttributedString(attributedString: renderChildren(strong))
        applyTrait(.boldFontMask, to: inner)
        return inner
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSAttributedString {
        let inner = NSMutableAttributedString(attributedString: renderChildren(strikethrough))
        let full = NSRange(location: 0, length: inner.length)
        inner.addAttribute(.strikethroughStyle,
                           value: NSUnderlineStyle.single.rawValue,
                           range: full)
        inner.addAttribute(.strikethroughColor,
                           value: MarkdownStyles.secondaryForeground,
                           range: full)
        return inner
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSAttributedString {
        NSAttributedString(string: inlineCode.code, attributes: [
            .font: MarkdownStyles.monospacedFont(),
            .foregroundColor: MarkdownStyles.codeForeground,
            .backgroundColor: MarkdownStyles.codeBackground,
        ])
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> NSAttributedString {
        // Don't render raw HTML in the preview — show it dimmed so the user
        // knows there's hidden content.
        NSAttributedString(string: inlineHTML.rawHTML, attributes: [
            .font: MarkdownStyles.monospacedFont(),
            .foregroundColor: MarkdownStyles.dimmedMarker,
        ])
    }

    mutating func visitLink(_ link: Link) -> NSAttributedString {
        let inner = NSMutableAttributedString(attributedString: renderChildren(link))
        let full = NSRange(location: 0, length: inner.length)
        inner.addAttribute(.foregroundColor,
                           value: MarkdownStyles.linkColor,
                           range: full)
        inner.addAttribute(.underlineStyle,
                           value: NSUnderlineStyle.single.rawValue,
                           range: full)
        inner.addAttribute(.underlineColor,
                           value: MarkdownStyles.linkColor,
                           range: full)
        if let destination = link.destination,
           let url = URL(string: destination) {
            inner.addAttribute(.link, value: url, range: full)
        }
        return inner
    }

    mutating func visitImage(_ image: Markdown.Image) -> NSAttributedString {
        let alt = image.children
            .compactMap { ($0 as? Markdown.Text)?.string }
            .joined()
        if let source = image.source,
           let attachment = ImageLoader.attachment(source: source, alt: alt, baseURL: baseURL) {
            return inlineImageAttachmentString(attachment, alt: alt)
        }
        let label = alt.isEmpty ? "[Image]" : "[Image: \(alt)]"
        return NSAttributedString(string: label, attributes: [
            .font: italicized(MarkdownStyles.bodyFont()),
            .foregroundColor: MarkdownStyles.secondaryForeground,
        ])
    }

    // MARK: - Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) -> NSAttributedString {
        let inner = NSMutableAttributedString(attributedString: renderChildren(paragraph))
        // Detect "block image" paragraphs — a single image (or a few images
        // in a row with nothing else) — and give them a paragraph style
        // that doesn't multiply the attachment's tall natural line height
        // by `bodyLineHeight` (≈1.6×). Without this, a 260pt-tall SVG
        // produces a 260·1.6 = 416pt line and the user sees ~80pt of
        // empty space above AND below the image.
        let isImageOnly = inner.length > 0
            && inner.string.unicodeScalars.allSatisfy {
                $0 == UnicodeScalar(NSTextAttachment.character)
            }
        // Append the terminator BEFORE attribute-stamping so the trailing
        // "\n" (which TextKit uses to determine paragraph layout) inherits
        // the same paragraph style as the rest of the paragraph. Without
        // this the terminator's body style would re-introduce the 1.6×
        // multiplier and the trailing gap would come back.
        inner.append(blockTerminator())
        let full = NSRange(location: 0, length: inner.length)
        let paragraphStyle: NSParagraphStyle
        if isImageOnly {
            let style = NSMutableParagraphStyle()
            style.alignment = .left
            style.paragraphSpacingBefore = 8
            style.paragraphSpacing = 8
            paragraphStyle = style
        } else {
            paragraphStyle = MarkdownStyles.bodyParagraphStyle()
        }
        inner.addAttribute(.paragraphStyle, value: paragraphStyle, range: full)
        return inner
    }

    mutating func visitHeading(_ heading: Heading) -> NSAttributedString {
        let inner = NSMutableAttributedString(attributedString: renderChildren(heading))
        let full = NSRange(location: 0, length: inner.length)
        let font = MarkdownStyles.headingFont(level: heading.level)
        inner.addAttribute(.font, value: font, range: full)
        inner.addAttribute(.foregroundColor,
                           value: MarkdownStyles.foreground,
                           range: full)
        inner.addAttribute(.paragraphStyle,
                           value: MarkdownStyles.headingParagraphStyle(),
                           range: full)
        inner.append(NSAttributedString(string: "\n", attributes: [
            .font: font,
            .paragraphStyle: MarkdownStyles.headingParagraphStyle(),
        ]))
        return inner
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSAttributedString {
        let inner = NSMutableAttributedString(attributedString: renderChildren(blockQuote))
        let full = NSRange(location: 0, length: inner.length)
        inner.addAttribute(.paragraphStyle,
                           value: MarkdownStyles.blockquoteParagraphStyle(),
                           range: full)
        inner.addAttribute(.foregroundColor,
                           value: MarkdownStyles.blockquoteText,
                           range: full)
        applyTrait(.italicFontMask, to: inner)
        return inner
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        // Inner lines need paragraphSpacing=0 so they sit flush against each
        // other; the surrounding block gets vertical air via the terminator.
        let innerStyle = NSMutableParagraphStyle()
        innerStyle.lineHeightMultiple = 1.2
        innerStyle.paragraphSpacing = 0
        innerStyle.paragraphSpacingBefore = 0
        let m = NSMutableAttributedString(string: code, attributes: [
            .font: MarkdownStyles.monospacedFont(),
            .foregroundColor: MarkdownStyles.codeForeground,
            .backgroundColor: MarkdownStyles.codeBackground,
            .paragraphStyle: innerStyle,
        ])
        m.append(blockTerminator())
        return m
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> NSAttributedString {
        // Show raw HTML dimmed so the user sees it but knows it's not rendered.
        let raw = html.rawHTML.trimmingCharacters(in: .newlines)
        let m = NSMutableAttributedString(string: raw, attributes: [
            .font: MarkdownStyles.monospacedFont(),
            .foregroundColor: MarkdownStyles.dimmedMarker,
            .paragraphStyle: MarkdownStyles.bodyParagraphStyle(),
        ])
        m.append(blockTerminator())
        return m
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.0
        style.paragraphSpacingBefore = 12
        style.paragraphSpacing = 12
        let line = String(repeating: "─", count: 40)
        return NSAttributedString(string: line + "\n", attributes: [
            .font: MarkdownStyles.bodyFont(),
            .foregroundColor: MarkdownStyles.dimmedMarker,
            .paragraphStyle: style,
        ])
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> NSAttributedString {
        if forPasteboard {
            return renderPasteboardList(items: Array(list.listItems),
                                        ordered: false,
                                        startIndex: 1)
        }
        return renderList(items: Array(list.listItems), ordered: false, startIndex: 1)
    }

    mutating func visitOrderedList(_ list: OrderedList) -> NSAttributedString {
        let start = Int(list.startIndex)
        if forPasteboard {
            return renderPasteboardList(items: Array(list.listItems),
                                        ordered: true,
                                        startIndex: max(1, start))
        }
        return renderList(items: Array(list.listItems), ordered: true, startIndex: max(1, start))
    }

    private mutating func renderList(items: [ListItem],
                                     ordered: Bool,
                                     startIndex: Int) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (offset, item) in items.enumerated() {
            let line = NSMutableAttributedString()
            // Bullet / number
            let marker: String
            if let checkbox = item.checkbox {
                marker = checkbox == .checked ? "☑︎ " : "☐ "
            } else if ordered {
                marker = "\(startIndex + offset).  "
            } else {
                marker = "•  "
            }
            line.append(NSAttributedString(string: marker, attributes: [
                .font: MarkdownStyles.bodyFont(),
                .foregroundColor: MarkdownStyles.secondaryForeground,
            ]))
            // Item body — visit children but strip trailing block padding so
            // list items stay tight.
            let inner = NSMutableAttributedString(attributedString: renderChildren(item))
            while inner.length > 0, inner.string.hasSuffix("\n\n") {
                inner.deleteCharacters(in: NSRange(location: inner.length - 1, length: 1))
            }
            line.append(inner)
            if !line.string.hasSuffix("\n") {
                line.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
            }
            let style = MarkdownStyles.listParagraphStyle(level: 1)
            line.addAttribute(.paragraphStyle,
                              value: style,
                              range: NSRange(location: 0, length: line.length))
            result.append(line)
        }
        result.append(blockTerminator())
        return result
    }

    /// Pasteboard-mode list rendering. Pushes an `NSTextList` onto
    /// `listStack`, then walks each item's block children manually so we
    /// can emit one paragraph per item with the full ancestor chain in
    /// `paragraphStyle.textLists`. AppKit's RTF serializer reads that
    /// chain when writing `\listtable` and `\ls`, which Word / Outlook
    /// recognise as native bullet / numbered paragraphs.
    ///
    /// Nesting is handled by the recursive call landing in
    /// `visitUnorderedList` / `visitOrderedList`, which call back into
    /// this method and append themselves to `listStack` before visiting
    /// their items.
    ///
    /// Task list items (GFM `- [ ]` / `- [x]`) are rendered as plain
    /// paragraphs with a leading checkbox glyph — they don't go through
    /// `NSTextList` because Word has no native concept of a task list and
    /// would otherwise stamp both a bullet AND a checkbox character.
    private mutating func renderPasteboardList(items: [ListItem],
                                               ordered: Bool,
                                               startIndex: Int) -> NSAttributedString {
        let textList = NSTextList(
            markerFormat: ordered ? .decimal : .disc,
            options: 0
        )
        textList.startingItemNumber = startIndex
        listStack.append(textList)
        defer { listStack.removeLast() }

        let result = NSMutableAttributedString()
        for item in items {
            // Task list item: render as a regular indented paragraph with a
            // checkbox glyph; skip the NSTextList stamping.
            if let checkbox = item.checkbox {
                let glyph = checkbox == .checked ? "☑︎ " : "☐ "
                let body = NSMutableAttributedString()
                for child in item.children {
                    if let para = child as? Paragraph {
                        body.append(renderChildren(para))
                    } else {
                        body.append(visit(child))
                    }
                }
                let line = NSMutableAttributedString(
                    string: glyph,
                    attributes: bodyAttributes
                )
                line.append(body)
                line.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
                let style = NSMutableParagraphStyle()
                style.headIndent = CGFloat(listStack.count) * 24
                style.firstLineHeadIndent = CGFloat(max(0, listStack.count - 1)) * 24
                style.paragraphSpacing = 4
                line.addAttribute(.paragraphStyle,
                                  value: style,
                                  range: NSRange(location: 0, length: line.length))
                result.append(line)
                continue
            }

            // Regular item: walk block children. Paragraphs become list
            // paragraphs (prefixed with \t so AppKit's marker code lines up);
            // sublists recurse and push their own NSTextList; everything
            // else (code blocks, blockquotes, tables) falls back to the
            // default visit and is laid out as a continuation block.
            for child in item.children {
                if let para = child as? Paragraph {
                    let inner = NSMutableAttributedString(
                        attributedString: renderChildren(para)
                    )
                    let line = NSMutableAttributedString(
                        string: "\t",
                        attributes: bodyAttributes
                    )
                    line.append(inner)
                    line.append(NSAttributedString(
                        string: "\n",
                        attributes: bodyAttributes
                    ))
                    line.addAttribute(
                        .paragraphStyle,
                        value: pasteboardListParagraphStyle(),
                        range: NSRange(location: 0, length: line.length)
                    )
                    result.append(line)
                } else {
                    result.append(visit(child))
                }
            }
        }
        return result
    }

    /// Paragraph style for an item paragraph inside a pasteboard list.
    /// Carries the full `listStack` so nested lists serialize their
    /// ancestor chain correctly in RTF.
    private func pasteboardListParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = MarkdownStyles.bodyLineHeight
        style.paragraphSpacing = 4
        // Indent grows with nesting depth so Word's outline indentation
        // matches the bullet level even when its built-in List Bullet
        // style isn't applied.
        let level = listStack.count
        style.headIndent = CGFloat(level) * 24
        style.firstLineHeadIndent = CGFloat(max(0, level - 1)) * 24
        style.textLists = listStack
        return style
    }

    mutating func visitTable(_ table: Markdown.Table) -> NSAttributedString {
        if forPasteboard {
            return renderPasteboardTable(table)
        }
        // Simple text rendering: header row + separator + body rows. Cells
        // are tab-separated; the monospaced font keeps columns roughly aligned.
        let mono = MarkdownStyles.monospacedFont()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: mono,
            .foregroundColor: MarkdownStyles.foreground,
        ]
        let result = NSMutableAttributedString()
        let headerCells: [String] = Array(table.head.cells).map { stringForCell($0) }
        if !headerCells.isEmpty {
            let header = NSMutableAttributedString(
                string: headerCells.joined(separator: "  │  ") + "\n",
                attributes: attrs
            )
            applyTrait(.boldFontMask, to: header)
            result.append(header)
            let divider = headerCells.map { String(repeating: "─", count: max($0.count, 3)) }
                .joined(separator: "──┼──")
            result.append(NSAttributedString(string: divider + "\n", attributes: [
                .font: mono,
                .foregroundColor: MarkdownStyles.dimmedMarker,
            ]))
        }
        for row in table.body.rows {
            let cells: [String] = Array(row.cells).map { stringForCell($0) }
            result.append(NSAttributedString(
                string: cells.joined(separator: "  │  ") + "\n",
                attributes: attrs
            ))
        }
        result.append(blockTerminator())
        return result
    }

    private mutating func stringForCell(_ cell: Markdown.Table.Cell) -> String {
        renderChildren(cell).string
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Pasteboard-mode table rendering. Builds a single `NSTextTable` plus
    /// one `NSTextTableBlock` per cell, then emits a paragraph per cell
    /// whose `paragraphStyle.textBlocks` references its block. AppKit's
    /// RTF serializer turns that into proper `\trowd \cell \row` markup
    /// (verified on macOS 26), which Word for Mac pastes as a real,
    /// editable table instead of monospaced text with `│` separators.
    ///
    /// Inline cell content (bold, italic, links, inline code) is rendered
    /// by the existing inline visitors, so styling carries through.
    ///
    /// Cells with `colspan == 0` (GFM "continuation" markers from
    /// HTML-in-Markdown) are skipped — the preceding cell's column span
    /// covers them. Higher `colspan` / `rowspan` values pass through to
    /// `NSTextTableBlock`.
    private mutating func renderPasteboardTable(
        _ table: Markdown.Table
    ) -> NSAttributedString {
        let headerCells = Array(table.head.cells)
        let bodyRows = Array(table.body.rows)
        let headerCount = headerCells.reduce(0) { $0 + max(1, Int($1.colspan)) }
        let bodyCount = bodyRows
            .map { Array($0.cells).reduce(0) { $0 + max(1, Int($1.colspan)) } }
            .max() ?? 0
        let columnCount = max(headerCount, bodyCount)
        guard columnCount > 0 else { return NSAttributedString() }

        let nsTable = NSTextTable()
        nsTable.numberOfColumns = columnCount
        nsTable.collapsesBorders = true
        nsTable.hidesEmptyCells = false

        let alignments = table.columnAlignments
        let result = NSMutableAttributedString()

        var rowIndex = 0

        if !headerCells.isEmpty {
            var col = 0
            for cell in headerCells {
                let colspan = max(1, Int(cell.colspan))
                let rowspan = max(1, Int(cell.rowspan))
                guard cell.colspan != 0 else { continue }
                result.append(renderTableCell(
                    cell: cell,
                    table: nsTable,
                    row: rowIndex,
                    col: col,
                    rowSpan: rowspan,
                    colSpan: colspan,
                    alignment: col < alignments.count ? alignments[col] : nil,
                    isHeader: true
                ))
                col += colspan
            }
            // Pad short header row so the table reaches columnCount cells.
            while col < columnCount {
                result.append(renderEmptyTableCell(
                    table: nsTable,
                    row: rowIndex,
                    col: col,
                    alignment: col < alignments.count ? alignments[col] : nil,
                    isHeader: true
                ))
                col += 1
            }
            rowIndex += 1
        }

        for row in bodyRows {
            var col = 0
            for cell in Array(row.cells) {
                guard cell.colspan != 0 else { continue }
                let colspan = max(1, Int(cell.colspan))
                let rowspan = max(1, Int(cell.rowspan))
                result.append(renderTableCell(
                    cell: cell,
                    table: nsTable,
                    row: rowIndex,
                    col: col,
                    rowSpan: rowspan,
                    colSpan: colspan,
                    alignment: col < alignments.count ? alignments[col] : nil,
                    isHeader: false
                ))
                col += colspan
            }
            while col < columnCount {
                result.append(renderEmptyTableCell(
                    table: nsTable,
                    row: rowIndex,
                    col: col,
                    alignment: col < alignments.count ? alignments[col] : nil,
                    isHeader: false
                ))
                col += 1
            }
            rowIndex += 1
        }

        result.append(blockTerminator())
        return result
    }

    private mutating func renderTableCell(
        cell: Markdown.Table.Cell,
        table: NSTextTable,
        row: Int,
        col: Int,
        rowSpan: Int,
        colSpan: Int,
        alignment: Markdown.Table.ColumnAlignment?,
        isHeader: Bool
    ) -> NSAttributedString {
        let block = makeTableBlock(
            table: table,
            row: row,
            col: col,
            rowSpan: rowSpan,
            colSpan: colSpan,
            isHeader: isHeader
        )
        let content = NSMutableAttributedString(attributedString: renderChildren(cell))
        // Cells should never carry block paragraph styles (e.g. body
        // paragraphSpacing) — overwrite with the cell's own style below.
        content.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
        if isHeader {
            applyTrait(.boldFontMask, to: content)
        }
        let style = tableCellParagraphStyle(block: block, alignment: alignment)
        content.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: 0, length: content.length)
        )
        return content
    }

    private mutating func renderEmptyTableCell(
        table: NSTextTable,
        row: Int,
        col: Int,
        alignment: Markdown.Table.ColumnAlignment?,
        isHeader: Bool
    ) -> NSAttributedString {
        let block = makeTableBlock(
            table: table,
            row: row,
            col: col,
            rowSpan: 1,
            colSpan: 1,
            isHeader: isHeader
        )
        let style = tableCellParagraphStyle(block: block, alignment: alignment)
        return NSAttributedString(string: "\n", attributes: [
            .font: MarkdownStyles.bodyFont(),
            .foregroundColor: MarkdownStyles.foreground,
            .paragraphStyle: style,
        ])
    }

    private func makeTableBlock(
        table: NSTextTable,
        row: Int,
        col: Int,
        rowSpan: Int,
        colSpan: Int,
        isHeader: Bool
    ) -> NSTextTableBlock {
        let block = NSTextTableBlock(
            table: table,
            startingRow: row,
            rowSpan: rowSpan,
            startingColumn: col,
            columnSpan: colSpan
        )
        // Thin borders + a little padding so Word renders a recognisable
        // table even before the user applies a Table Style.
        block.setBorderColor(MarkdownStyles.dimmedMarker)
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            block.setWidth(0.5, type: .absoluteValueType, for: .border, edge: edge)
            block.setWidth(4, type: .absoluteValueType, for: .padding, edge: edge)
        }
        if isHeader {
            block.backgroundColor = MarkdownStyles.codeBackground
        }
        return block
    }

    private func tableCellParagraphStyle(
        block: NSTextTableBlock,
        alignment: Markdown.Table.ColumnAlignment?
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        switch alignment {
        case .left?: style.alignment = .left
        case .center?: style.alignment = .center
        case .right?: style.alignment = .right
        case nil: style.alignment = .natural
        }
        return style
    }

    // MARK: - Block directives (DocFX `:::image::: ` etc.)

    mutating func visitBlockDirective(_ directive: BlockDirective) -> NSAttributedString {
        let label: String
        switch directive.name.lowercased() {
        case "image":
            // Best-effort: pluck `source="..."` and `alt-text="..."` out of
            // the argument text. If `source` resolves to a local image we
            // render it inline; otherwise we fall through to a placeholder.
            let args = directive.argumentText.parseNameValueArguments()
            let source = args.first(where: { $0.name == "source" })?.value
            let alt = args.first(where: { $0.name == "alt-text" })?.value
                ?? source
                ?? "Image"
            if let source,
               let attachment = ImageLoader.attachment(source: source, alt: alt, baseURL: baseURL) {
                return blockImageAttachmentString(attachment, alt: alt)
            }
            label = "[Image: \(alt)]"
        case "note", "tip", "warning", "important", "caution":
            // Render directive body as a blockquote-ish block with a label.
            let header = NSMutableAttributedString(
                string: directive.name.uppercased() + "\n",
                attributes: [
                    .font: italicized(MarkdownStyles.bodyFont()),
                    .foregroundColor: MarkdownStyles.blockquoteAccent,
                    .paragraphStyle: MarkdownStyles.bodyParagraphStyle(),
                ]
            )
            let body = NSMutableAttributedString(attributedString: renderChildren(directive))
            let full = NSRange(location: 0, length: body.length)
            body.addAttribute(.paragraphStyle,
                              value: MarkdownStyles.blockquoteParagraphStyle(),
                              range: full)
            body.addAttribute(.foregroundColor,
                              value: MarkdownStyles.blockquoteText,
                              range: full)
            header.append(body)
            header.append(blockTerminator())
            return header
        default:
            label = "[\(directive.name)]"
        }
        return NSAttributedString(string: label + "\n", attributes: [
            .font: italicized(MarkdownStyles.bodyFont()),
            .foregroundColor: MarkdownStyles.secondaryForeground,
            .paragraphStyle: MarkdownStyles.bodyParagraphStyle(),
        ])
    }

    // MARK: - Helpers

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: MarkdownStyles.bodyFont(),
            .foregroundColor: MarkdownStyles.foreground,
            .paragraphStyle: MarkdownStyles.bodyParagraphStyle(),
        ]
    }

    private func blockTerminator() -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: bodyAttributes)
    }

    private func italicized(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    /// Builds an attributed string containing a single attachment character
    /// for an `![alt](src)` image that appears inline inside running text.
    /// The tool tip surfaces `alt` for accessibility / hover discovery.
    private func inlineImageAttachmentString(_ attachment: NSTextAttachment,
                                             alt: String) -> NSAttributedString {
        let m = NSMutableAttributedString(attachment: attachment)
        let full = NSRange(location: 0, length: m.length)
        if !alt.isEmpty {
            m.addAttribute(.toolTip, value: alt, range: full)
        }
        return m
    }

    /// Builds an attributed string for a `:::image:::` directive: the
    /// attachment sits on its own line(s) with a paragraph break above and
    /// below so it reads as a block illustration rather than inline glyph.
    private func blockImageAttachmentString(_ attachment: NSTextAttachment,
                                            alt: String) -> NSAttributedString {
        let m = NSMutableAttributedString(attachment: attachment)
        let full = NSRange(location: 0, length: m.length)
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.paragraphSpacing = 12
        style.paragraphSpacingBefore = 12
        m.addAttribute(.paragraphStyle, value: style, range: full)
        if !alt.isEmpty {
            m.addAttribute(.toolTip, value: alt, range: full)
        }
        m.append(blockTerminator())
        return m
    }

    /// Adds the given font trait (bold / italic) across the whole attributed
    /// string, preserving any font size or family already set on each run.
    private func applyTrait(_ trait: NSFontTraitMask,
                            to attributed: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            let base = (value as? NSFont) ?? MarkdownStyles.bodyFont()
            let converted = NSFontManager.shared.convert(base, toHaveTrait: trait)
            attributed.addAttribute(.font, value: converted, range: range)
        }
    }
}
