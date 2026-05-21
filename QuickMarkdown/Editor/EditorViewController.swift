import AppKit
import Markdown

/// Hosts the Live Preview / Plain Source editor for a `MarkdownDocument`.
///
/// The editor is a single `NSTextView` backed by `MarkdownTextStorage`. The
/// storage holds raw Markdown source as plain text; display attributes are
/// reapplied after every edit (debounced ~50ms) by parsing with swift-markdown
/// and walking the AST.
@MainActor
final class EditorViewController: NSViewController {

    // MARK: - Public surface

    weak var document: MarkdownDocument?

    /// Posted on the main queue when the editor's display mode changes. The
    /// window controller listens so it can update the toolbar segmented control.
    static let displayModeDidChangeNotification =
        Notification.Name("QuickMarkdownEditorDisplayModeDidChange")

    /// Toggle the editor between rendered live-preview and plain-source view.
    var displayMode: MarkdownTextStorage.DisplayMode {
        get { textStorage.displayMode }
        set {
            guard textStorage.displayMode != newValue else { return }
            textStorage.displayMode = newValue
            // Re-seed typing attributes so newly typed characters match the
            // new mode (monospace in plain source; body font in live preview).
            switch newValue {
            case .livePreview:
                textView.typingAttributes = MarkdownStyles.defaultAttributes
            case .plainSource:
                textView.typingAttributes = MarkdownStyles.plainSourceAttributes
            }
            NotificationCenter.default.post(
                name: Self.displayModeDidChangeNotification,
                object: self
            )
        }
    }

    /// Menu action target. Wired by `View > Toggle Preview / Source` and by
    /// the toolbar segmented control.
    @objc func toggleDisplayMode(_ sender: Any?) {
        displayMode = (displayMode == .livePreview) ? .plainSource : .livePreview
    }

    // MARK: - Private views

    private let scrollView = NSScrollView()
    // Constructed in loadView() with our own text-storage stack so we never
    // get the auto-created NSTextContainer that NSTextView() makes by default.
    // That auto-container is what causes "given container does not appear in
    // the list of containers for this NSLayoutManager" during state restoration.
    var textView: NonAssistingTextView!
    private let textStorage = MarkdownTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()

    /// True when we are mutating the buffer programmatically (e.g. external
    /// reload) and should not feed the change back to the document.
    private var isApplyingExternalChange = false

    private nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // Build the TextKit 1 chain: storage -> layoutManager -> container.
        textStorage.addLayoutManager(layoutManager)
        // Crucial for large documents: allow the layout manager to lay out
        // arbitrary ranges (just the visible region) without first laying
        // out everything that precedes it. Without this flag, the very
        // first display pass on a multi-MB markdown file forces TextKit to
        // build glyph runs and line fragments for the entire document up
        // front — 100% main-thread CPU and 10x memory before the window
        // appears.
        layoutManager.allowsNonContiguousLayout = true
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: MarkdownStyles.contentMaxWidth,
                                             height: CGFloat.greatestFiniteMagnitude)
        layoutManager.addTextContainer(textContainer)

        // Construct the text view AROUND our container so it never owns a
        // private text system that AppKit could later try to lay out.
        textView = NonAssistingTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = MarkdownStyles.editorInset
        textView.backgroundColor = ReadingPreferences.shared.theme.background
        textView.drawsBackground = true
        textView.insertionPointColor = ReadingPreferences.shared.theme.insertionPoint
        textView.delegate = self
        // Make the typing attributes match the body defaults so a fresh
        // document begins with the right font.
        textView.typingAttributes = MarkdownStyles.defaultAttributes

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // Use legacy (always-visible) scrollers rather than overlay scrollers.
        // The macOS overlay style auto-hides when not actively scrolling, and
        // for a document editor we want the user to see scroll position at all
        // times — especially after switching modes (Preview <-> Source) where
        // they need a quick orientation cue.
        scrollView.scrollerStyle = .legacy
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ReadingPreferences.shared.theme.background
        scrollView.documentView = textView
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        self.view = root

        themeObserver = NotificationCenter.default.addObserver(
            forName: ReadingPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTheme()
            }
        }
    }

    deinit {
        if let token = themeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Repaint backdrop / caret colours and force a full restyle so the new
    /// theme fonts and colours show up immediately.
    private func applyTheme() {
        let theme = ReadingPreferences.shared.theme
        textView.backgroundColor = theme.background
        scrollView.backgroundColor = theme.background
        textView.insertionPointColor = theme.insertionPoint
        // Re-seed typing attributes so newly typed characters use the new
        // font + colour even before the next AST restyle runs.
        switch textStorage.displayMode {
        case .livePreview:
            textView.typingAttributes = MarkdownStyles.defaultAttributes
        case .plainSource:
            textView.typingAttributes = MarkdownStyles.plainSourceAttributes
        }
        textStorage.forceRestyle()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let document {
            loadContent(from: document)
        }
    }

    // MARK: - Document binding

    func attach(_ document: MarkdownDocument) {
        self.document = document
        if isViewLoaded {
            loadContent(from: document)
        }
    }

    /// Replace the buffer contents with the document's current `content`.
    /// Used on initial bind. Resets cursor to the start of the document.
    func loadContent(from document: MarkdownDocument) {
        applyContent(document.content, resetCursor: true, followBottom: false)
    }

    /// Replace the buffer contents from an external (file-watcher) reload.
    /// Preserves the cursor location where possible and, if the viewport was
    /// near the bottom of the document, scrolls to the new bottom so an
    /// LLM-tail feel works (`tail -f`-style follow mode, PRD §6.6).
    func applyExternalReload(from document: MarkdownDocument) {
        let wasNearBottom = isScrolledNearBottom(threshold: 50)
        applyContent(document.content,
                     resetCursor: false,
                     followBottom: wasNearBottom)
    }

    /// Returns true when the editor's vertical scroll position is within
    /// `threshold` points of the document bottom. Used to decide whether to
    /// auto-scroll to the new bottom after an external reload.
    func isScrolledNearBottom(threshold: CGFloat) -> Bool {
        guard let clip = scrollView.contentView as NSClipView? else { return false }
        let docHeight = textView.frame.height
        let visibleBottom = clip.bounds.origin.y + clip.bounds.height
        return (docHeight - visibleBottom) <= threshold
    }

    /// Core buffer replacement. `resetCursor` resets selection to the start;
    /// otherwise we clamp the existing selection to the new length.
    /// `followBottom` overrides scroll preservation and snaps to the bottom.
    private func applyContent(_ new: String,
                              resetCursor: Bool,
                              followBottom: Bool) {
        isApplyingExternalChange = true
        defer { isApplyingExternalChange = false }

        // Capture pre-change state for restoration.
        let priorSelection = textView.selectedRange()
        let priorScrollOrigin = scrollView.contentView.bounds.origin

        if textStorage.string != new {
            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.replaceCharacters(in: fullRange, with: new)
        }

        if resetCursor {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textStorage.cursorLocation = 0
        } else {
            let clamped = NSRange(
                location: min(priorSelection.location, textStorage.length),
                length: 0
            )
            textView.setSelectedRange(clamped)
            textStorage.cursorLocation = clamped.location
        }

        textStorage.forceRestyle()

        // Restore or follow scroll. Both branches need a layout pass so the
        // new content height is realised before computing the new origin.
        // The initial-load path (`resetCursor == true && followBottom ==
        // false`) deliberately skips the layout pass: forcing TextKit to
        // lay out the entire buffer up front pegs CPU at 100% and balloons
        // memory on large files. Without it, AppKit lays out the visible
        // region lazily on first display, which is what we want.
        if followBottom {
            layoutManager.ensureLayout(for: textContainer)
            textView.needsLayout = true
            textView.layoutSubtreeIfNeeded()
            scrollToBottom()
        } else if !resetCursor {
            layoutManager.ensureLayout(for: textContainer)
            textView.needsLayout = true
            textView.layoutSubtreeIfNeeded()
            // Preserve the scroll origin (clamped to the new content size).
            let maxY = max(0, textView.frame.height
                           - scrollView.contentView.bounds.height)
            let y = min(priorScrollOrigin.y, maxY)
            scrollView.contentView.scroll(to: NSPoint(x: priorScrollOrigin.x, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func scrollToBottom() {
        let maxY = max(0, textView.frame.height
                       - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Scroll position (Preview <-> Source sync)

    /// Current vertical scroll position as a fraction in `0...1` of the
    /// scrollable range. Returns `0` if the document is shorter than the
    /// viewport (nothing to scroll).
    var scrollFraction: Double {
        guard let docView = scrollView.documentView else { return 0 }
        let visible = scrollView.contentView.bounds
        let denom = docView.bounds.height - visible.height
        guard denom > 1 else { return 0 }
        return Double(max(0, min(visible.minY, denom)) / denom)
    }

    /// Scroll so the visible top sits at `fraction` of the scrollable range.
    /// Forces a layout pass first so the call works correctly even when the
    /// view was just un-hidden by a mode switch.
    func applyScrollFraction(_ fraction: Double) {
        view.layoutSubtreeIfNeeded()
        layoutManager.ensureLayout(for: textContainer)
        textView.layoutSubtreeIfNeeded()
        guard let docView = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds
        let denom = docView.bounds.height - visible.height
        guard denom > 0 else { return }
        let y = max(0, min(CGFloat(fraction) * denom, denom))
        scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Task list toggling (from Preview)

    /// Flip the state of the Nth task-list checkbox in the source. `index`
    /// is provided by the preview, which counts task items in document /
    /// AST order; the same order matches the line order of GFM task markers
    /// in the source, so we just find the Nth match of the marker regex and
    /// flip its single inner character (`x` <-> ` `).
    ///
    /// The mutation goes through `shouldChangeText` / `didChangeText` so it
    /// is undoable and triggers `NSText.didChangeNotification` — which the
    /// window controller observes to mark the preview stale and which the
    /// `textDidChange` delegate uses to write back to the document.
    func toggleTaskItem(at index: Int) {
        guard index >= 0 else { return }
        let source = textStorage.string as NSString
        // GFM task marker: optional indent, list bullet (`-`, `*`, `+`),
        // whitespace, `[` + (space|x|X) + `]`. Captures the single inner
        // character so we can target it precisely.
        let pattern = #"^[ \t]*[-*+][ \t]+\[([ xX])\]"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else { return }
        let matches = regex.matches(
            in: source as String,
            range: NSRange(location: 0, length: source.length)
        )
        guard index < matches.count else { return }
        let innerRange = matches[index].range(at: 1)
        guard innerRange.location != NSNotFound,
              innerRange.length == 1,
              source.length >= innerRange.location + innerRange.length else { return }
        let current = source.substring(with: innerRange)
        let replacement = (current == " ") ? "x" : " "
        guard textView.shouldChangeText(in: innerRange,
                                        replacementString: replacement) else { return }
        textStorage.replaceCharacters(in: innerRange, with: replacement)
        textView.didChangeText()
    }
}

// MARK: - NSTextViewDelegate

extension EditorViewController: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        guard !isApplyingExternalChange else { return }
        guard let document else { return }
        let newContent = textStorage.string
        if document.content != newContent {
            document.setContent(newContent)
            document.updateChangeCount(.changeDone)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let location = textView.selectedRange().location
        textStorage.cursorLocation = location
    }

    func textView(_ textView: NSTextView,
                  clickedOnLink link: Any,
                  at charIndex: Int) -> Bool {
        let url: URL?
        switch link {
        case let u as URL: url = u
        case let s as String: url = URL(string: s)
        default: url = nil
        }
        if let url {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }

    /// Cell-aware Tab / Shift-Tab / Return navigation when the caret is
    /// inside a Markdown table. Tab moves to the next cell (and adds a
    /// new row when invoked from the last cell). Shift-Tab goes back.
    /// Return at the end of the last row also adds a row. Anywhere
    /// else, returns `false` so AppKit's default key handling runs.
    func textView(_ textView: NSTextView,
                  doCommandBy commandSelector: Selector) -> Bool {
        let source = textStorage.string
        let caret = textView.selectedRange().location
        guard let block = TableEditing.block(at: caret, in: source) else {
            return false
        }
        switch commandSelector {
        case #selector(NSStandardKeyBindingResponding.insertTab(_:)):
            return handleTabKeyInTable(forward: true, block: block, source: source, caret: caret)
        case #selector(NSStandardKeyBindingResponding.insertBacktab(_:)):
            return handleTabKeyInTable(forward: false, block: block, source: source, caret: caret)
        case #selector(NSStandardKeyBindingResponding.insertNewline(_:)):
            return handleReturnKeyInTable(block: block, source: source, caret: caret)
        default:
            return false
        }
    }

    private func handleTabKeyInTable(forward: Bool,
                                     block: TableEditing.Block,
                                     source: String,
                                     caret: Int) -> Bool {
        guard let (row, col) = TableEditing.cell(at: caret, in: block, source: source) else {
            return false
        }
        let totalRows = block.rows.count
        let totalCols = block.columnCount
        var nextRow = row
        var nextCol = col
        if forward {
            if col + 1 < totalCols {
                nextCol = col + 1
            } else if row + 1 < totalRows {
                nextRow = row + 1
                nextCol = 0
            } else {
                addRowAndPlaceCaret(in: block)
                return true
            }
        } else {
            if col > 0 {
                nextCol = col - 1
            } else if row > 0 {
                nextRow = row - 1
                nextCol = totalCols - 1
            } else {
                return true // already in first cell; swallow
            }
        }
        if let target = TableEditing.caretAtCellStart(row: nextRow,
                                                     col: nextCol,
                                                     in: block,
                                                     source: source) {
            // Select the existing cell text so typing replaces it
            // (Word/Excel/Pages convention on Tab navigation).
            if let end = TableEditing.caretAtCellEnd(row: nextRow,
                                                    col: nextCol,
                                                    in: block,
                                                    source: source),
               end > target {
                textView.setSelectedRange(NSRange(location: target, length: end - target))
            } else {
                textView.setSelectedRange(NSRange(location: target, length: 0))
            }
        }
        return true
    }

    private func handleReturnKeyInTable(block: TableEditing.Block,
                                        source: String,
                                        caret: Int) -> Bool {
        guard let (row, _) = TableEditing.cell(at: caret, in: block, source: source) else {
            return false
        }
        let totalRows = block.rows.count
        if row + 1 < totalRows {
            // Jump to start of next row's first cell.
            if let target = TableEditing.caretAtCellStart(row: row + 1,
                                                         col: 0,
                                                         in: block,
                                                         source: source) {
                textView.setSelectedRange(NSRange(location: target, length: 0))
            }
            return true
        }
        // On the last row: add a new one.
        addRowAndPlaceCaret(in: block)
        return true
    }

    /// Replace the block in source with a re-formatted version that has
    /// one additional empty body row, then drop the caret in the first
    /// cell of that new row.
    private func addRowAndPlaceCaret(in block: TableEditing.Block) {
        let (newText, caretOffsetInBlock) = TableEditing.appendingEmptyRow(block)
        guard textView.shouldChangeText(in: block.nsRange,
                                        replacementString: newText) else { return }
        textView.replaceCharacters(in: block.nsRange, with: newText)
        textView.didChangeText()
        let target = block.nsRange.location + caretOffsetInBlock
        textView.setSelectedRange(NSRange(location: target, length: 0))
    }

    /// Rect (in `textView` coordinates) of the caret, suitable for
    /// anchoring a popover. Returns the view's bounds origin as a
    /// last-resort fallback.
    func caretRectInTextView() -> NSRect {
        let sel = textView.selectedRange()
        if let layoutManager = textView.layoutManager,
           let container = textView.textContainer {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: sel.location, length: 0),
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                  in: container)
            // boundingRect can collapse to zero width for an insertion
            // point; widen it slightly so the popover arrow points
            // somewhere sensible.
            if rect.width < 1 { rect.size.width = 2 }
            // Offset by the text container inset.
            rect = rect.offsetBy(dx: textView.textContainerOrigin.x,
                                 dy: textView.textContainerOrigin.y)
            return rect
        }
        return NSRect(origin: textView.bounds.origin, size: NSSize(width: 2, height: 16))
    }
}

/// NSTextView subclass used by both the editor and the preview.
///
/// Currently customises two behaviours:
///
/// 1. **Calm editing** — placeholder hook for future writing-tools /
///    assistant suppression.
/// 2. **Word-friendly copy** — rewrites font sizes through
///    `ClipboardNormalizer` before serialising the selection, so headings
///    and body text pasted into Microsoft Word / Pages / Notes land at
///    sane sizes (11 pt body, ~22 pt H1) instead of the 16 / 32 pt we
///    use for on-screen reading.
final class NonAssistingTextView: NSTextView {

    /// Pasteboard types we publish on copy. Plain string + RTF cover
    /// virtually every paste target; HTML helps with web-flavoured editors
    /// (Notes, Mail's HTML compose, browser inputs).
    private static let exportTypes: [NSPasteboard.PasteboardType] = [
        .string, .rtf, .html,
    ]

    override func copy(_ sender: Any?) {
        guard writeNormalizedSelectionToGeneralPasteboard() else {
            super.copy(sender)
            return
        }
    }

    /// Available via Edit > Copy via responder chain; mirrors `copy(_:)`.
    override func writeSelection(to pboard: NSPasteboard,
                                 types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let normalized = normalizedSelection() else {
            return super.writeSelection(to: pboard, types: types)
        }
        return write(normalized, to: pboard, types: types)
    }

    @discardableResult
    private func writeNormalizedSelectionToGeneralPasteboard() -> Bool {
        guard let normalized = normalizedSelection() else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes(Self.exportTypes, owner: nil)
        return write(normalized, to: pb, types: Self.exportTypes)
    }

    /// Concatenates the user's selection (supports multi-selection) and
    /// runs it through `ClipboardNormalizer`. Returns `nil` for an empty
    /// selection so the caller can fall through to the default behaviour.
    private func normalizedSelection() -> NSAttributedString? {
        let ranges = selectedRanges
            .map { $0.rangeValue }
            .filter { $0.length > 0 }
        guard !ranges.isEmpty, let storage = textStorage else { return nil }
        let combined = NSMutableAttributedString()
        for range in ranges {
            combined.append(storage.attributedSubstring(from: range))
        }
        return ClipboardNormalizer.normalize(combined)
    }

    private func write(_ attributed: NSAttributedString,
                       to pboard: NSPasteboard,
                       types: [NSPasteboard.PasteboardType]) -> Bool {
        let full = NSRange(location: 0, length: attributed.length)
        var didWrite = false
        for type in types {
            switch type {
            case .string:
                if pboard.setString(attributed.string, forType: .string) {
                    didWrite = true
                }
            case .rtf:
                if let data = try? attributed.data(
                    from: full,
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                ), pboard.setData(data, forType: .rtf) {
                    didWrite = true
                }
            case .rtfd:
                if let data = try? attributed.data(
                    from: full,
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
                ), pboard.setData(data, forType: .rtfd) {
                    didWrite = true
                }
            case .html:
                if let data = try? attributed.data(
                    from: full,
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
                ), pboard.setData(data, forType: .html) {
                    didWrite = true
                }
            default:
                break
            }
        }
        return didWrite
    }

    // MARK: - Markdown file drop support

    /// Intercept drops of `.md` / `.markdown` files and route them through
    /// `NSDocumentController` so they open in a new (or recycled empty)
    /// window. Non-markdown drops fall through to NSTextView's default
    /// behaviour, so dropping plain text still inserts inline as expected.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if QuickMarkdownDocumentController.markdownURLs(in: sender) != nil {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if QuickMarkdownDocumentController.markdownURLs(in: sender) != nil {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let urls = QuickMarkdownDocumentController.markdownURLs(in: sender) {
            QuickMarkdownDocumentController.openMarkdownURLs(urls)
            return true
        }
        return super.performDragOperation(sender)
    }
}

// MARK: - Speech (read-aloud) highlighting

extension EditorViewController {

    /// Highlight the currently-spoken word in the source editor, or clear
    /// the highlight when `range.location == NSNotFound`. Uses the layout
    /// manager's temporary-attribute API so we don't disturb the live
    /// markdown styling applied by `MarkdownTextStorage`.
    func highlightSpokenRange(_ range: NSRange) {
        guard let layoutManager = textView.layoutManager else { return }
        let storageLength = textView.textStorage?.length ?? 0
        let fullRange = NSRange(location: 0, length: storageLength)
        layoutManager.removeTemporaryAttribute(.backgroundColor,
                                               forCharacterRange: fullRange)

        guard range.location != NSNotFound, range.length > 0 else { return }
        guard range.location >= 0,
              range.location + range.length <= storageLength else { return }

        let highlight = NSColor.systemYellow.withAlphaComponent(0.45)
        layoutManager.addTemporaryAttribute(.backgroundColor,
                                            value: highlight,
                                            forCharacterRange: range)
        textView.scrollRangeToVisible(range)
    }
}
