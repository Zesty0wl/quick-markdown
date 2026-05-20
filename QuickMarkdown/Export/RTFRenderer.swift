import AppKit
import Markdown

/// Builds a fully-styled `NSAttributedString` from raw Markdown source, with
/// **no marker dimming** — used by the Copy Formatted and RTF export paths.
///
/// We reuse the live-preview styler by setting `activeParagraph` to cover the
/// entire source, so every marker is treated as "in the active paragraph" and
/// rendered at full opacity.
enum AttributedStringRenderer {

    static func render(markdownSource: String) -> NSAttributedString {
        let backing = NSMutableAttributedString(
            string: markdownSource,
            attributes: MarkdownStyles.defaultAttributes
        )
        let document = Document(parsing: markdownSource)
        let offsets = LineOffsetIndex(source: markdownSource)
        let fullRange = NSRange(location: 0, length: (markdownSource as NSString).length)
        var styler = LivePreviewStyler(
            storage: backing,
            source: markdownSource,
            offsets: offsets,
            activeParagraph: fullRange
        )
        styler.visit(document)
        return backing
    }
}

/// Serialises a styled `NSAttributedString` to RTF bytes.
enum RTFRenderer {

    static func data(from attributed: NSAttributedString) -> Data? {
        let fullRange = NSRange(location: 0, length: attributed.length)
        return try? attributed.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
}
