import AppKit

/// Regex-based syntax highlighting for the plain-source view, styled to
/// resemble VS Code's built-in Markdown grammar colouring. All colours
/// use the system semantic palette so they adapt to light / dark mode.
enum PlainSourceHighlighter {

    // MARK: - Colour palette (VS Code Dark+ / Light+ aligned)

    /// Heading markers and text — blue / bold.
    private static let headingColor = NSColor.systemBlue
    /// Bold markers and text — blue / bold (font weight distinguishes from heading).
    private static let boldColor = NSColor.systemBlue
    /// Italic markers and text — blue / italic (font style distinguishes from heading).
    private static let italicColor = NSColor.systemBlue
    /// Inline code and fenced code fence lines — orange (VS Code #ce9178).
    private static let codeColor = NSColor.systemOrange
    /// Link text `[...]`.
    private static let linkTextColor = NSColor.systemTeal
    /// Link URL `(...)` and reference labels.
    private static let linkURLColor = NSColor.systemCyan
    /// Blockquotes `> ...` — green (VS Code #608b4e).
    private static let quoteColor = NSColor.systemGreen
    /// List bullets / numbers.
    private static let listMarkerColor = NSColor.systemPurple
    /// YAML front-matter fences and keys.
    private static let frontMatterColor = NSColor.systemPink
    /// HTML tags.
    private static let htmlColor = NSColor.systemRed
    /// Table pipes and horizontal rules.
    private static let punctuationColor = NSColor.systemGray
    /// Task-list checkboxes `[ ]` / `[x]`.
    private static let taskColor = NSColor.systemIndigo
    /// Image `!` prefix.
    private static let imageColor = NSColor.systemMint
    /// Strikethrough `~~` — red for "deleted" semantics.
    private static let strikethroughColor = NSColor.systemRed

    // MARK: - Pattern table

    private nonisolated(unsafe) static let patterns: [(NSRegularExpression, [NSAttributedString.Key: Any])] = {
        let fontSize = MarkdownStyles.plainSourceFontSize
        let mono = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let monoBold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let monoItalic: NSFont = {
            let desc = mono.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: desc, size: fontSize) ?? mono
        }()

        func rule(_ pattern: String,
                  options: NSRegularExpression.Options = [.anchorsMatchLines],
                  attrs: [NSAttributedString.Key: Any]) -> (NSRegularExpression, [NSAttributedString.Key: Any])? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            return (regex, attrs)
        }

        var rules: [(NSRegularExpression, [NSAttributedString.Key: Any])] = []

        // --- YAML front matter (opening/closing --- and content) ---
        if let r = rule(#"^---\s*$"#, attrs: [.foregroundColor: frontMatterColor, .font: monoBold]) { rules.append(r) }
        if let r = rule(#"^[a-zA-Z_][\w.-]*:"#, attrs: [.foregroundColor: frontMatterColor]) { rules.append(r) }

        // --- Headings ---
        if let r = rule(#"^#{1,6}\s+.*$"#, attrs: [.foregroundColor: headingColor, .font: monoBold]) { rules.append(r) }

        // --- Fenced code blocks (the fence lines themselves) ---
        if let r = rule(#"^`{3,}.*$"#, attrs: [.foregroundColor: codeColor]) { rules.append(r) }
        if let r = rule(#"^~{3,}.*$"#, attrs: [.foregroundColor: codeColor]) { rules.append(r) }

        // --- Inline code ---
        if let r = rule(#"`[^`\n]+`"#, options: [], attrs: [.foregroundColor: codeColor]) { rules.append(r) }

        // --- Bold **text** and __text__ ---
        if let r = rule(#"\*\*[^*\n]+\*\*"#, options: [], attrs: [.foregroundColor: boldColor, .font: monoBold]) { rules.append(r) }
        if let r = rule(#"__[^_\n]+__"#, options: [], attrs: [.foregroundColor: boldColor, .font: monoBold]) { rules.append(r) }

        // --- Italic *text* and _text_ ---
        if let r = rule(#"(?<!\*)\*(?!\*)[^*\n]+\*(?!\*)"#, options: [], attrs: [.foregroundColor: italicColor, .font: monoItalic]) { rules.append(r) }
        if let r = rule(#"(?<!_)_(?!_)[^_\n]+_(?!_)"#, options: [], attrs: [.foregroundColor: italicColor, .font: monoItalic]) { rules.append(r) }

        // --- Strikethrough ~~text~~ ---
        if let r = rule(#"~~[^~\n]+~~"#, options: [], attrs: [.foregroundColor: strikethroughColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue]) { rules.append(r) }

        // --- Images ![alt](url) — highlight the `!` prefix ---
        if let r = rule(#"!\[[^\]]*\]\([^)]+\)"#, options: [], attrs: [.foregroundColor: imageColor]) { rules.append(r) }

        // --- Links [text](url) ---
        if let r = rule(#"\[[^\]]+\]"#, options: [], attrs: [.foregroundColor: linkTextColor]) { rules.append(r) }
        if let r = rule(#"\]\([^)]+\)"#, options: [], attrs: [.foregroundColor: linkURLColor]) { rules.append(r) }

        // --- Reference-style links [text][ref] and definitions [ref]: url ---
        if let r = rule(#"^\[[^\]]+\]:\s+.*$"#, attrs: [.foregroundColor: linkURLColor]) { rules.append(r) }

        // --- Blockquotes ---
        if let r = rule(#"^>\s.*$"#, attrs: [.foregroundColor: quoteColor, .font: monoItalic]) { rules.append(r) }

        // --- List markers (-, *, +, 1., 2.) ---
        if let r = rule(#"^(\s*)([-*+]|\d+\.)\s"#, attrs: [.foregroundColor: listMarkerColor]) { rules.append(r) }

        // --- Task list checkboxes ---
        if let r = rule(#"\[[ xX]\]"#, options: [], attrs: [.foregroundColor: taskColor, .font: monoBold]) { rules.append(r) }

        // --- Horizontal rules ---
        if let r = rule(#"^(\*{3,}|-{3,}|_{3,})\s*$"#, attrs: [.foregroundColor: punctuationColor]) { rules.append(r) }

        // --- Table pipes ---
        if let r = rule(#"\|"#, options: [], attrs: [.foregroundColor: punctuationColor]) { rules.append(r) }

        // --- HTML tags ---
        if let r = rule(#"</?[a-zA-Z][^>]*>"#, options: [], attrs: [.foregroundColor: htmlColor]) { rules.append(r) }

        // --- Docs/Learn directives :::type ::: ---
        if let r = rule(#"^:::.*$"#, attrs: [.foregroundColor: frontMatterColor]) { rules.append(r) }

        return rules
    }()

    static func apply(to storage: NSMutableAttributedString, source: String) {
        let range = NSRange(location: 0, length: (source as NSString).length)
        for (regex, attrs) in patterns {
            regex.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let match else { return }
                storage.addAttributes(attrs, range: match.range)
            }
        }
    }
}
