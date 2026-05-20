import AppKit

/// Phase 3 plain-source view: applies a small set of regex-based colour passes
/// to the backing store for raw Markdown viewing.
///
/// Stubbed for Phase 2 build; Phase 3 will fill in the full pattern set.
enum PlainSourceHighlighter {

    private nonisolated(unsafe) static let patterns: [(NSRegularExpression, [NSAttributedString.Key: Any])] = {
        func make(_ pattern: String,
                  options: NSRegularExpression.Options = [.anchorsMatchLines],
                  attrs: [NSAttributedString.Key: Any]) -> (NSRegularExpression, [NSAttributedString.Key: Any])? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            return (regex, attrs)
        }
        var rules: [(NSRegularExpression, [NSAttributedString.Key: Any])] = []
        if let r = make(#"^#{1,6}\s+.*$"#, attrs: [
            .foregroundColor: NSColor.systemBlue,
            .font: NSFont.monospacedSystemFont(ofSize: MarkdownStyles.plainSourceFontSize, weight: .bold),
        ]) { rules.append(r) }
        if let r = make(#"`[^`\n]+`"#, options: [], attrs: [
            .foregroundColor: NSColor.systemOrange,
        ]) { rules.append(r) }
        if let r = make(#"\[[^\]]+\]\([^)]+\)"#, options: [], attrs: [
            .foregroundColor: NSColor.systemTeal,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]) { rules.append(r) }
        if let r = make(#"^>\s.*$"#, attrs: [
            .foregroundColor: NSColor.secondaryLabelColor,
        ]) { rules.append(r) }
        if let r = make(#"^---+\s*$"#, attrs: [
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]) { rules.append(r) }
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
