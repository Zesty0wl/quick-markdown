import AppKit
import Markdown

/// `NSTextStorage` subclass that stores raw Markdown source as plain text and
/// re-applies display attributes (fonts, colours, paragraph spacing) after every
/// edit. Characters are never inserted or removed by the styler — only attributes
/// change. The buffer is always the truth.
///
/// Marker-reveal behaviour: Markdown markers (`**`, `*`, `` ` ``, leading `#`,
/// list bullets, link `[text](url)` syntax, table pipes, fence ` ``` `) are
/// drawn at full opacity when the cursor is inside their paragraph and dimmed
/// to a tertiary-label colour otherwise.
final class MarkdownTextStorage: NSTextStorage {

    enum DisplayMode {
        case livePreview   // Phase 2 default: rendered with marker reveal
        case plainSource   // Phase 3: uniform monospace with regex highlight
    }

    // MARK: - Backing store

    private let backing = NSMutableAttributedString()

    // MARK: - Public knobs

    /// Current display mode. Changing this triggers a full restyle.
    var displayMode: DisplayMode = .plainSource {
        didSet {
            guard displayMode != oldValue else { return }
            forceRestyle()
        }
    }

    /// Caret/selection location. Drives marker reveal in `.livePreview` mode.
    /// Setting this triggers a (cheap) style-only restyle if the affected
    /// paragraph changes.
    var cursorLocation: Int = 0 {
        didSet {
            guard displayMode == .livePreview else { return }
            // Lightweight restyle — same buffer, same AST, just different reveal.
            scheduleRestyle(reason: .cursorMove)
        }
    }

    // MARK: - Required NSTextStorage overrides

    override var string: String {
        backing.string
    }

    override func attributes(at location: Int,
                             effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    // MARK: - Edit processing

    override func processEditing() {
        // First let NSTextStorage do its bookkeeping (fixes attribute runs etc.).
        super.processEditing()
        // Only restyle when characters changed; pure attribute edits (e.g. our
        // own restyle pass) must not recurse.
        if editedMask.contains(.editedCharacters) {
            scheduleRestyle(reason: .textChange)
        }
    }

    // MARK: - Restyle scheduling (debounce)

    private enum RestyleReason { case textChange, cursorMove }
    private var pendingWork: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.05

    private func scheduleRestyle(reason: RestyleReason) {
        pendingWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performRestyle()
        }
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
    }

    /// Forces a synchronous restyle. Used when display mode flips.
    func forceRestyle() {
        pendingWork?.cancel()
        performRestyle()
    }

    private func performRestyle() {
        let fullRange = NSRange(location: 0, length: backing.length)
        guard fullRange.length > 0 else { return }

        let source = backing.string

        // We are mutating attributes from within an edit batch. We must NOT
        // call replaceCharacters here and must NOT change length.
        beginEditing()

        switch displayMode {
        case .livePreview:
            applyLivePreviewAttributes(source: source, fullRange: fullRange)
        case .plainSource:
            applyPlainSourceAttributes(source: source, fullRange: fullRange)
        }

        // Tell text storage that attributes changed across the whole range so
        // the layout manager re-lays out.
        edited(.editedAttributes, range: fullRange, changeInLength: 0)
        endEditing()
    }

    // MARK: - Live preview styling

    private func applyLivePreviewAttributes(source: String, fullRange: NSRange) {
        // 1. Reset everything to body defaults.
        backing.setAttributes(MarkdownStyles.defaultAttributes, range: fullRange)

        // 2. Parse with swift-markdown (GFM extensions enabled by default).
        let document = Document(parsing: source, options: [.parseBlockDirectives])

        // 3. Walk the AST applying attributes.
        let offsets = LineOffsetIndex(source: source)
        let activeParagraph = paragraphRange(for: cursorLocation, in: source)
        var styler = LivePreviewStyler(
            storage: backing,
            source: source,
            offsets: offsets,
            activeParagraph: activeParagraph
        )
        styler.visit(document)
    }

    // MARK: - Plain source styling (Phase 3)

    private func applyPlainSourceAttributes(source: String, fullRange: NSRange) {
        backing.setAttributes(MarkdownStyles.plainSourceAttributes, range: fullRange)

        // Regex pass for colourisation.
        PlainSourceHighlighter.apply(to: backing, source: source)
    }

    // MARK: - Paragraph computation

    /// Returns the NSRange in `source` covering the paragraph containing `location`.
    /// Paragraphs are delimited by blank lines.
    private func paragraphRange(for location: Int, in source: String) -> NSRange {
        let ns = source as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = max(0, min(location, ns.length - 1))
        // Walk backwards to last blank line.
        var start = clamped
        while start > 0 {
            let prev = start - 1
            if ns.character(at: prev) == 0x0A,
               prev > 0,
               ns.character(at: prev - 1) == 0x0A {
                break
            }
            start -= 1
        }
        // Walk forwards to next blank line.
        var end = clamped
        while end < ns.length {
            if ns.character(at: end) == 0x0A,
               end + 1 < ns.length,
               ns.character(at: end + 1) == 0x0A {
                end += 1
                break
            }
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Line offset index

/// Maps swift-markdown's 1-based (line, column) source positions to NSString
/// character offsets in the original source.
struct LineOffsetIndex {
    private let lineStarts: [Int]
    private let totalLength: Int

    init(source: String) {
        var starts: [Int] = [0]
        let ns = source as NSString
        let len = ns.length
        for i in 0..<len where ns.character(at: i) == 0x0A {
            starts.append(i + 1)
        }
        lineStarts = starts
        totalLength = len
    }

    /// Convert a swift-markdown `SourceLocation` (1-based line, 1-based column)
    /// to a UTF-16 offset in the source. swift-markdown columns are 1-based on
    /// Unicode scalar boundaries, which is close enough to UTF-16 for ASCII and
    /// most prose text. (Phase 2 acceptable; edge case: multi-scalar emoji in
    /// markers — rare in practice.)
    func offset(for location: SourceLocation) -> Int {
        let lineIndex = max(0, location.line - 1)
        guard lineIndex < lineStarts.count else { return totalLength }
        let lineStart = lineStarts[lineIndex]
        let columnOffset = max(0, location.column - 1)
        return min(totalLength, lineStart + columnOffset)
    }

    /// Convert a swift-markdown `SourceRange` to an `NSRange`. Returns nil if
    /// the source range has no resolvable bounds.
    func nsRange(for range: SourceRange?) -> NSRange? {
        guard let range else { return nil }
        let start = offset(for: range.lowerBound)
        let end = offset(for: range.upperBound)
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
