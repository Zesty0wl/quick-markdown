import AppKit

/// Writes a Markdown source fragment to `NSPasteboard.general` in three
/// flavours: HTML (inline-styled), RTF, and plain Markdown text. Outlook for
/// Mac and Microsoft Word both prefer HTML; older RTF-only consumers fall
/// back to RTF; everything else gets the raw source.
enum FormattedPasteboardWriter {

    @MainActor
    static func writeFormatted(markdownSource: String,
                               to pasteboard: NSPasteboard = .general) {
        let html = HTMLRenderer.renderDocument(markdownSource)
        // Use the pasteboard-mode renderer so list items carry NSTextList
        // paragraph attributes. AppKit's RTF serializer turns those into a
        // proper `\listtable` / `\ls` group, which Word for Mac and Outlook
        // recognise as native bullet / numbered paragraphs (instead of
        // treating the marker as literal "- " text).
        let attributed = MarkdownAttributedRenderer.renderForPasteboard(markdownSource)
        let rtf = RTFRenderer.data(from: attributed)

        pasteboard.clearContents()

        var items: [NSPasteboard.PasteboardType: Any] = [:]
        if let htmlData = html.data(using: .utf8) {
            items[.html] = htmlData
        }
        if let rtf {
            items[.rtf] = rtf
        }
        items[.string] = markdownSource

        // NSPasteboard accepts one writeObjects pass; for multiple types on a
        // single item we use `setData(_:forType:)` after declaring the types.
        pasteboard.declareTypes(Array(items.keys), owner: nil)
        for (type, value) in items {
            switch value {
            case let d as Data:
                pasteboard.setData(d, forType: type)
            case let s as String:
                pasteboard.setString(s, forType: type)
            default:
                break
            }
        }
    }

    /// Writes an already-rendered HTML fragment — the preview's current
    /// selection, with preview-only attributes stripped — plus its plain
    /// text. The fragment is wrapped in `HTMLRenderer.selectionFragmentCSS`
    /// so pastes match `writeFormatted` in font and spacing but carry no
    /// colours, leaving the receiving app's theme in charge.
    ///
    /// Written from Swift rather than via `clipboardData.setData` in the
    /// page because WebKit sanitises script-written HTML through its own
    /// serialiser, which re-inlines the computed `color`.
    @MainActor
    static func writeHTMLFragment(_ fragment: String,
                                  plainText: String,
                                  to pasteboard: NSPasteboard = .general) {
        let html = "<div style=\"\(HTMLRenderer.selectionFragmentCSS)\">\(fragment)</div>"
        pasteboard.clearContents()
        pasteboard.declareTypes([.html, .string], owner: nil)
        if let data = html.data(using: .utf8) {
            pasteboard.setData(data, forType: .html)
        }
        pasteboard.setString(plainText, forType: .string)
    }
}
