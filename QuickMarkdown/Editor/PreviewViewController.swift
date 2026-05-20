import AppKit

/// Read-only NSTextView that displays a fully-rendered Markdown preview.
/// The text storage holds an `NSAttributedString` produced by
/// `MarkdownAttributedRenderer` — there are no source markers and no YAML
/// front matter, so the user sees clean rendered output.
@MainActor
final class PreviewViewController: NSViewController {

    private let scrollView = NSScrollView()
    private(set) var textView: NSTextView!
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()

    /// Last source we rendered. Cached so theme changes can re-render with
    /// the new colours / font without having to know about the document.
    private var lastRenderedSource: String = ""

    /// Folder URL of the document being previewed, used by the renderer to
    /// resolve relative image paths. `nil` for untitled / unsaved docs.
    private var lastRenderedBaseURL: URL?

    /// True when the rendered content does not match the source the user is
    /// editing. `DocumentWindowController` sets this when the source changes
    /// while we are in source mode, and consumes it on the next swap to
    /// preview to know whether to re-render.
    var isStale: Bool = true

    private nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        textStorage.addLayoutManager(layoutManager)
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: MarkdownStyles.contentMaxWidth,
                                             height: CGFloat.greatestFiniteMagnitude)
        layoutManager.addTextContainer(textContainer)

        textView = NonAssistingTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = MarkdownStyles.editorInset
        textView.backgroundColor = ReadingPreferences.shared.theme.background
        textView.drawsBackground = true
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: MarkdownStyles.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
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

    /// Renders the supplied Markdown source and shows it. Preserves the
    /// previous scroll offset when possible so the view stays put across
    /// re-renders triggered by typing.
    ///
    /// `baseURL` is the document's containing folder. The renderer uses it
    /// to resolve relative image paths (`![](media/foo.png)` and DocFX
    /// `:::image source="media/foo.svg":::`).
    func render(source: String, baseURL: URL? = nil) {
        lastRenderedSource = source
        lastRenderedBaseURL = baseURL
        let priorOrigin = scrollView.contentView.bounds.origin
        let rendered = MarkdownAttributedRenderer.render(source, baseURL: baseURL)
        textStorage.beginEditing()
        textStorage.setAttributedString(rendered)
        textStorage.endEditing()
        layoutManager.ensureLayout(for: textContainer)
        textView.needsLayout = true
        textView.layoutSubtreeIfNeeded()
        // Clamp scroll to the new content height.
        let maxY = max(0, textView.frame.height
                       - scrollView.contentView.bounds.height)
        let y = min(priorOrigin.y, maxY)
        scrollView.contentView.scroll(to: NSPoint(x: priorOrigin.x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isStale = false
    }

    /// Repaint backdrop + link colours and re-render the last source so the
    /// new theme/font appears immediately.
    private func applyTheme() {
        let theme = ReadingPreferences.shared.theme
        textView.backgroundColor = theme.background
        scrollView.backgroundColor = theme.background
        textView.linkTextAttributes = [
            .foregroundColor: MarkdownStyles.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        if !lastRenderedSource.isEmpty {
            render(source: lastRenderedSource, baseURL: lastRenderedBaseURL)
        }
    }
}

// MARK: - NSTextViewDelegate (link clicks)

extension PreviewViewController: NSTextViewDelegate {

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
}

// MARK: - Speech (read-aloud)

extension PreviewViewController {

    /// Plain-text contents of the rendered preview. Suitable to hand to
    /// `SpeechController.speak(_:)` — markdown markers are already stripped
    /// by the renderer, so this reads cleanly.
    var plainText: String {
        textStorage.string
    }

    /// Current selection (in the preview text storage) or `nil` when no
    /// characters are selected.
    var selectedTextRange: NSRange? {
        let range = textView.selectedRange()
        return range.length > 0 ? range : nil
    }

    /// Returns the substring the user wants read aloud: selection if any,
    /// otherwise the entire rendered document. The returned range is the
    /// position of `text` inside `plainText`, so callers can translate
    /// word-range callbacks from the speech synthesizer back into preview
    /// text storage coordinates by adding `range.location`.
    func speechPayload() -> (text: String, offsetIntoPreview: Int) {
        if let selection = selectedTextRange {
            let ns = textStorage.string as NSString
            return (ns.substring(with: selection), selection.location)
        }
        return (plainText, 0)
    }

    /// Highlight the currently-spoken word (or clear, when `range.location`
    /// is `NSNotFound`). Uses NSLayoutManager temporary attributes so the
    /// underlying text-storage styling (code backgrounds, link colours, …)
    /// is never disturbed.
    ///
    /// `range` is in the coordinate space of `plainText`; pass the offset
    /// from `speechPayload()` so selection-based reads land on the correct
    /// characters.
    func highlightSpokenRange(_ range: NSRange, offsetIntoPreview: Int = 0) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor,
                                               forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineStyle,
                                               forCharacterRange: fullRange)

        guard range.location != NSNotFound, range.length > 0 else { return }

        let translated = NSRange(location: range.location + offsetIntoPreview,
                                 length: range.length)
        guard translated.location >= 0,
              translated.location + translated.length <= textStorage.length else {
            return
        }

        let highlight = NSColor.systemYellow.withAlphaComponent(0.45)
        layoutManager.addTemporaryAttribute(.backgroundColor,
                                            value: highlight,
                                            forCharacterRange: translated)
        textView.scrollRangeToVisible(translated)
    }
}
