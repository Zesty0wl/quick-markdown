import AppKit
import Markdown

/// Walks a swift-markdown `Document` AST and applies display attributes to
/// the live-preview backing store. Markers near the cursor are full-opacity;
/// markers elsewhere are dimmed.
struct LivePreviewStyler: MarkupWalker {

    let storage: NSMutableAttributedString
    let source: String
    let offsets: LineOffsetIndex
    /// Range in `source` covering the paragraph the cursor is currently in.
    let activeParagraph: NSRange

    // MARK: - Entry point

    mutating func visit(_ markup: Markdown.Document) {
        descendInto(markup)
    }

    // MARK: - Block-level

    mutating func visitHeading(_ heading: Heading) {
        guard let range = nsRange(of: heading) else { return }
        let font = MarkdownStyles.headingFont(level: heading.level)
        addAttributes([
            .font: font,
            .paragraphStyle: MarkdownStyles.headingParagraphStyle(),
            .foregroundColor: MarkdownStyles.foreground,
        ], range: range)

        // Leading `#`s plus trailing space.
        let markerLen = min(heading.level + 1, range.length)
        let markerRange = NSRange(location: range.location, length: markerLen)
        applyMarkerColor(in: markerRange, paragraphRange: range)
        descendInto(heading)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        if let range = nsRange(of: paragraph) {
            addAttributes([
                .paragraphStyle: MarkdownStyles.bodyParagraphStyle(),
            ], range: range)
        }
        descendInto(paragraph)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        guard let range = nsRange(of: blockQuote) else {
            descendInto(blockQuote)
            return
        }
        addAttributes([
            .paragraphStyle: MarkdownStyles.blockquoteParagraphStyle(),
            .foregroundColor: MarkdownStyles.blockquoteText,
            .font: italicized(MarkdownStyles.bodyFont()),
        ], range: range)
        // The leading `> ` on each line is a marker we should dim when inactive.
        // Easy approach: find each `> ` occurrence within the range.
        dimLeadingMarkerLines(prefix: "> ", in: range)
        descendInto(blockQuote)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let range = nsRange(of: codeBlock) else { return }
        addAttributes([
            .font: MarkdownStyles.monospacedFont(),
            .foregroundColor: MarkdownStyles.codeForeground,
            .backgroundColor: MarkdownStyles.codeBackground,
            .paragraphStyle: MarkdownStyles.codeBlockParagraphStyle(),
        ], range: range)
        // Fenced code blocks: dim the ``` lines if cursor not inside.
        dimLeadingMarkerLines(prefix: "```", in: range)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let range = nsRange(of: inlineCode) else { return }
        addAttributes([
            .font: MarkdownStyles.monospacedFont(),
            .foregroundColor: MarkdownStyles.codeForeground,
            .backgroundColor: MarkdownStyles.codeBackground,
        ], range: range)
        // First and last char are the backticks.
        if range.length >= 2 {
            dimMarker(at: range.location, length: 1, paragraphRange: range)
            dimMarker(at: range.location + range.length - 1, length: 1, paragraphRange: range)
        }
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        guard let range = nsRange(of: thematicBreak) else { return }
        applyMarkerColor(in: range, paragraphRange: range)
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        styleList(unorderedList, level: nestingLevel(of: unorderedList))
        descendInto(unorderedList)
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        styleList(orderedList, level: nestingLevel(of: orderedList))
        descendInto(orderedList)
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let range = nsRange(of: listItem) {
            let level = nestingLevel(of: listItem)
            addAttributes([
                .paragraphStyle: MarkdownStyles.listParagraphStyle(level: level),
            ], range: range)
            // Dim the leading marker (`- `, `* `, `+ `, or `1. `).
            dimListMarker(in: range)
        }
        descendInto(listItem)
    }

    mutating func visitTable(_ table: Markdown.Table) {
        if let range = nsRange(of: table) {
            addAttributes([
                .font: MarkdownStyles.monospacedFont(size: MarkdownStyles.codeFontSize),
                .foregroundColor: MarkdownStyles.foreground,
            ], range: range)
            // Pipes are markers — dim them when inactive.
            dimCharacters(matching: "|", in: range)
            // Header divider line (e.g. `|---|---|`) dim entirely.
            dimDividerLines(in: range)
        }
        descendInto(table)
    }

    // MARK: - Inline

    mutating func visitStrong(_ strong: Strong) {
        guard let range = nsRange(of: strong) else {
            descendInto(strong)
            return
        }
        // Add bold trait to whatever font is currently there.
        applyBold(in: range)
        // Markers are 2 chars at each end.
        if range.length >= 4 {
            dimMarker(at: range.location, length: 2, paragraphRange: range)
            dimMarker(at: range.location + range.length - 2, length: 2, paragraphRange: range)
        }
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        guard let range = nsRange(of: emphasis) else {
            descendInto(emphasis)
            return
        }
        applyItalic(in: range)
        if range.length >= 2 {
            dimMarker(at: range.location, length: 1, paragraphRange: range)
            dimMarker(at: range.location + range.length - 1, length: 1, paragraphRange: range)
        }
        descendInto(emphasis)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        guard let range = nsRange(of: strikethrough) else {
            descendInto(strikethrough)
            return
        }
        addAttributes([
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: MarkdownStyles.secondaryForeground,
        ], range: range)
        if range.length >= 4 {
            dimMarker(at: range.location, length: 2, paragraphRange: range)
            dimMarker(at: range.location + range.length - 2, length: 2, paragraphRange: range)
        }
        descendInto(strikethrough)
    }

    mutating func visitLink(_ link: Link) {
        guard let range = nsRange(of: link) else {
            descendInto(link)
            return
        }
        addAttributes([
            .foregroundColor: MarkdownStyles.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: MarkdownStyles.linkColor,
        ], range: range)
        if let destination = link.destination, let url = URL(string: destination) {
            addAttributes([.link: url], range: range)
        }
        // Dim the bracket / paren syntax. Heuristic: find `]` + `(` + `)` in this range.
        dimLinkSyntax(in: range)
        descendInto(link)
    }

    mutating func visitImage(_ image: Image) {
        guard let range = nsRange(of: image) else { return }
        addAttributes([
            .foregroundColor: MarkdownStyles.secondaryForeground,
        ], range: range)
        // Whole `![alt](url)` is markup — dim when inactive.
        applyMarkerColor(in: range, paragraphRange: range)
    }

    // MARK: - Helpers

    private func nsRange(of markup: Markup) -> NSRange? {
        offsets.nsRange(for: markup.range)
    }

    private func nestingLevel<M: Markup>(of node: M) -> Int {
        var level = 0
        var parent: Markup? = node.parent
        while let p = parent {
            if p is ListItem { level += 1 }
            parent = p.parent
        }
        return max(1, level)
    }

    private mutating func styleList<M: ListItemContainer & Markup>(_ list: M, level: Int) {
        guard let range = nsRange(of: list) else { return }
        addAttributes([
            .paragraphStyle: MarkdownStyles.listParagraphStyle(level: level),
        ], range: range)
    }

    private mutating func addAttributes(_ attrs: [NSAttributedString.Key: Any],
                                        range: NSRange) {
        guard intersect(range) else { return }
        storage.addAttributes(attrs, range: clip(range))
    }

    private mutating func applyBold(in range: NSRange) {
        let clipped = clip(range)
        storage.enumerateAttribute(.font, in: clipped, options: []) { value, subRange, _ in
            let base = (value as? NSFont) ?? MarkdownStyles.bodyFont()
            let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            storage.addAttribute(.font, value: bold, range: subRange)
        }
    }

    private mutating func applyItalic(in range: NSRange) {
        let clipped = clip(range)
        storage.enumerateAttribute(.font, in: clipped, options: []) { value, subRange, _ in
            let base = (value as? NSFont) ?? MarkdownStyles.bodyFont()
            let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: subRange)
        }
    }

    private func italicized(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private mutating func dimMarker(at location: Int, length: Int, paragraphRange: NSRange) {
        let range = NSRange(location: location, length: length)
        applyMarkerColor(in: range, paragraphRange: paragraphRange)
    }

    /// Apply the marker colour: dimmed when `paragraphRange` does NOT intersect
    /// the active paragraph; foreground when it does.
    private mutating func applyMarkerColor(in range: NSRange, paragraphRange: NSRange) {
        let isActive = NSIntersectionRange(paragraphRange, activeParagraph).length > 0
        let color: NSColor = isActive ? MarkdownStyles.foreground : MarkdownStyles.dimmedMarker
        addAttributes([.foregroundColor: color], range: range)
    }

    private mutating func dimLeadingMarkerLines(prefix: String, in range: NSRange) {
        let ns = source as NSString
        let clipped = clip(range)
        guard clipped.length > 0 else { return }
        let subString = ns.substring(with: clipped)
        var cursor = 0
        let lines = subString.components(separatedBy: "\n")
        for line in lines {
            let lineLen = (line as NSString).length
            if line.hasPrefix(prefix) {
                let dimRange = NSRange(location: clipped.location + cursor, length: lineLen)
                applyMarkerColor(in: dimRange, paragraphRange: range)
            }
            cursor += lineLen + 1 // +1 for newline
        }
    }

    private mutating func dimListMarker(in range: NSRange) {
        let ns = source as NSString
        let clipped = clip(range)
        guard clipped.length > 0 else { return }
        let line = ns.substring(with: clipped)
        // Find leading whitespace + ( `-` | `*` | `+` | digits+`.` ) + space
        let pattern = #"^\s*([-*+]|\d+\.)\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return }
        let markerRange = NSRange(location: clipped.location + match.range.location,
                                  length: match.range.length)
        applyMarkerColor(in: markerRange, paragraphRange: range)
    }

    private mutating func dimCharacters(matching character: Character, in range: NSRange) {
        let ns = source as NSString
        let clipped = clip(range)
        guard clipped.length > 0 else { return }
        let charValue = unichar(character.asciiValue ?? 0)
        for i in 0..<clipped.length {
            let idx = clipped.location + i
            if ns.character(at: idx) == charValue {
                applyMarkerColor(in: NSRange(location: idx, length: 1), paragraphRange: range)
            }
        }
    }

    private mutating func dimDividerLines(in range: NSRange) {
        let ns = source as NSString
        let clipped = clip(range)
        guard clipped.length > 0 else { return }
        let pattern = #"\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let sub = ns.substring(with: clipped)
        let nsLine = sub as NSString
        regex.enumerateMatches(in: sub, range: NSRange(location: 0, length: nsLine.length)) { match, _, _ in
            guard let match else { return }
            let dimRange = NSRange(location: clipped.location + match.range.location,
                                   length: match.range.length)
            applyMarkerColor(in: dimRange, paragraphRange: range)
        }
    }

    private mutating func dimLinkSyntax(in range: NSRange) {
        let ns = source as NSString
        let clipped = clip(range)
        guard clipped.length >= 4 else { return }
        let sub = ns.substring(with: clipped)
        // Dim `[`
        if sub.hasPrefix("[") {
            applyMarkerColor(in: NSRange(location: clipped.location, length: 1), paragraphRange: range)
        }
        // Dim everything from `]` onwards through end of node.
        if let closeBracketIdx = sub.firstIndex(of: "]") {
            let offset = sub.distance(from: sub.startIndex, to: closeBracketIdx)
            let dimRange = NSRange(location: clipped.location + offset,
                                   length: clipped.length - offset)
            applyMarkerColor(in: dimRange, paragraphRange: range)
        }
    }

    private func clip(_ range: NSRange) -> NSRange {
        let storageLen = storage.length
        let start = max(0, min(range.location, storageLen))
        let end = max(start, min(range.location + range.length, storageLen))
        return NSRange(location: start, length: end - start)
    }

    private func intersect(_ range: NSRange) -> Bool {
        clip(range).length > 0
    }
}
