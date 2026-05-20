import AppKit

/// Hosts the editor + read-only preview + reload banner + status bar for a
/// `MarkdownDocument`.
///
/// The window has two visual modes:
///  * **Source** — the editable rich-text editor (`EditorViewController`).
///    Markdown source is the canonical text; the styler decorates it with
///    headings, bold, lists, etc. but markers stay visible so the user can
///    edit them.
///  * **Preview** — a read-only `PreviewViewController` that renders the
///    same source with `MarkdownAttributedRenderer`, stripping markers and
///    YAML front matter. The preview is re-rendered lazily on entry and
///    again whenever the source changes while preview is active.
final class DocumentWindowController: NSWindowController, NSWindowDelegate {

    // MARK: - Children

    private let editor = EditorViewController()
    private let preview = PreviewViewController()
    private let banner = ReloadBannerView()
    private let statusBar = StatusBarView()
    private var bannerHeightConstraint: NSLayoutConstraint!
    private var bannerVisible = false

    /// Toolbar segmented control: [Preview | Source].
    private let modeSegmented: NSSegmentedControl = {
        let s = NSSegmentedControl(labels: ["Preview", "Source"],
                                   trackingMode: .selectOne,
                                   target: nil,
                                   action: nil)
        s.segmentStyle = .texturedRounded
        s.selectedSegment = 1   // Default to Source so the user lands in the editor.
        return s
    }()

    enum WindowMode { case preview, source }
    fileprivate var currentMode: WindowMode = .source

    // MARK: - Observers

    private nonisolated(unsafe) var externalChangeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var conflictObserver: NSObjectProtocol?
    private nonisolated(unsafe) var textChangeObserver: NSObjectProtocol?

    /// Debounced status-bar refresh trigger so we don't allocate formatters
    /// on every keystroke.
    private var pendingStatusRefresh: DispatchWorkItem?

    /// Per-window read-aloud controller. Created lazily on first use so we
    /// don't allocate an AVSpeechSynthesizer for docs that never trigger
    /// speech.
    private lazy var speech: SpeechController = {
        let controller = SpeechController()
        controller.onStateChange = { [weak self] _ in
            // Re-validate format buttons AND the Speak / Stop buttons so
            // their icons + enablement flip in lockstep with the synth.
            self?.invalidateFormatToolbarItems()
            self?.window?.menu?.update()
            NSApp.mainMenu?.update()
        }
        controller.onWordRangeChange = { [weak self] range in
            guard let self else { return }
            switch self.currentMode {
            case .preview:
                self.preview.highlightSpokenRange(
                    range,
                    offsetIntoPreview: self.speechOffsetIntoPreview
                )
            case .source:
                self.highlightSourceForSpokenRange(range)
            }
        }
        return controller
    }()

    /// Tracks the offset into the preview's text storage of the substring
    /// currently being spoken. Set when speech starts; consumed by the
    /// word-range callback to translate utterance-relative ranges into
    /// preview-relative ranges.
    private var speechOffsetIntoPreview: Int = 0

    /// Rendered → source word map active for the current source-mode
    /// utterance. Built when speech starts in source mode and consulted on
    /// every `willSpeakRange` callback to highlight the matching word in
    /// the markdown source editor.
    private var sourceSpeechMap: SpeechSourceMap?

    /// Offset (in the source string) at which the current source-mode
    /// utterance begins. Non-zero only when the user is speaking a
    /// selection rather than the whole document. Added to every
    /// `SpeechSourceMap` result so the highlight lands at the right
    /// position in the editor.
    private var sourceSpeechOffset: Int = 0

    /// Read-only accessors used by `SpeechToolbarItem` so the toolbar icon
    /// (play / pause / resume) and the Stop button's enablement track the
    /// synthesiser state. Kept `fileprivate` so the subclass below can use
    /// them without exposing `speech` more widely.
    fileprivate var speechState: SpeechController.State { speech.state }
    fileprivate var speechIsActive: Bool { speech.isActive }

    private var markdownDocument: MarkdownDocument? {
        document as? MarkdownDocument
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 700, height: 500)
        window.titlebarAppearsTransparent = false
        window.center()
        window.setFrameAutosaveName("QuickMarkdownDocumentWindow")
        self.init(window: window)
        window.delegate = self
        configureViews()
        configureToolbar()
        applyWindowMode(.source)
    }

    override var document: AnyObject? {
        didSet { wireDocument() }
    }

    // MARK: - View hierarchy

    private func configureViews() {
        guard let window = window else { return }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = container

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        bannerHeightConstraint = banner.heightAnchor.constraint(equalToConstant: 0)
        container.addSubview(banner)

        editor.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editor.view)

        preview.view.translatesAutoresizingMaskIntoConstraints = false
        preview.view.isHidden = true
        container.addSubview(preview.view)

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBar)

        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            banner.topAnchor.constraint(equalTo: container.topAnchor),
            bannerHeightConstraint,

            editor.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.view.topAnchor.constraint(equalTo: banner.bottomAnchor),
            editor.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            preview.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.view.topAnchor.constraint(equalTo: banner.bottomAnchor),
            preview.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        banner.onReload = { [weak self] in
            self?.handleBannerReload()
        }
        banner.onKeep = { [weak self] in
            self?.handleBannerKeep()
        }
    }

    private func wireDocument() {
        teardownObservers()
        guard let doc = markdownDocument else { return }

        editor.attach(doc)
        window?.title = doc.displayName

        externalChangeObserver = NotificationCenter.default.addObserver(
            forName: MarkdownDocument.contentDidChangeExternallyNotification,
            object: doc,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let doc = self.markdownDocument else { return }
                self.editor.applyExternalReload(from: doc)
                self.preview.isStale = true
                if self.currentMode == .preview {
                    self.preview.render(source: doc.content,
                                        baseURL: doc.fileURL?.deletingLastPathComponent())
                }
                self.hideBannerIfNeeded()
                self.refreshStatusBar()
            }
        }

        conflictObserver = NotificationCenter.default.addObserver(
            forName: MarkdownDocument.contentConflictDetectedNotification,
            object: doc,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showBanner()
            }
        }

        textChangeObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification,
            object: editor.textView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.preview.isStale = true
                self.scheduleStatusBarRefresh()
            }
        }

        refreshStatusBar()

        // Default landing mode: if the document was loaded from a file (i.e.
        // there's actual content to look at), greet the user with the
        // rendered preview. New untitled documents stay in Source so the
        // caret is ready to type.
        let preferredMode: WindowMode = (doc.fileURL != nil) ? .preview : .source
        if preferredMode != currentMode {
            applyWindowMode(preferredMode)
        }
    }

    private func teardownObservers() {
        for token in [externalChangeObserver, conflictObserver, textChangeObserver] {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        externalChangeObserver = nil
        conflictObserver = nil
        textChangeObserver = nil
    }

    // MARK: - Window mode (Preview / Source)

    @objc private func segmentedModeChanged(_ sender: NSSegmentedControl) {
        let next: WindowMode = sender.selectedSegment == 0 ? .preview : .source
        applyWindowMode(next)
    }

    /// Menu action (`View > Toggle Preview / Source`, ⌘⇧P). Flips between the
    /// two top-level window modes.
    @objc func toggleWindowMode(_ sender: Any?) {
        applyWindowMode(currentMode == .preview ? .source : .preview)
    }

    /// Action wired to the menu items inside the toolbar item's overflow
    /// menuFormRepresentation. `sender.tag` is `0` for Preview, `1` for Source.
    @objc fileprivate func selectWindowMode(_ sender: NSMenuItem) {
        applyWindowMode(sender.tag == 0 ? .preview : .source)
    }

    private func applyWindowMode(_ mode: WindowMode) {
        currentMode = mode
        modeSegmented.selectedSegment = (mode == .preview) ? 0 : 1
        switch mode {
        case .preview:
            if preview.isStale, let doc = markdownDocument {
                preview.render(source: doc.content,
                               baseURL: doc.fileURL?.deletingLastPathComponent())
            }
            preview.view.isHidden = false
            editor.view.isHidden = true
            window?.makeFirstResponder(preview.view)
        case .source:
            editor.displayMode = .plainSource
            editor.view.isHidden = false
            preview.view.isHidden = true
            window?.makeFirstResponder(editor.textView)
        }
        invalidateFormatToolbarItems()
    }

    // MARK: - Toolbar

    private static let toolbarIdentifier =
        NSToolbar.Identifier("QuickMarkdownDocumentToolbar")
    private static let openItemIdentifier    = NSToolbarItem.Identifier("QMD.open")
    private static let newItemIdentifier     = NSToolbarItem.Identifier("QMD.new")
    private static let saveItemIdentifier    = NSToolbarItem.Identifier("QMD.save")
    private static let boldItemIdentifier    = NSToolbarItem.Identifier("QMD.bold")
    private static let italicItemIdentifier  = NSToolbarItem.Identifier("QMD.italic")
    private static let headingItemIdentifier = NSToolbarItem.Identifier("QMD.heading")
    private static let listItemIdentifier    = NSToolbarItem.Identifier("QMD.list")
    private static let linkItemIdentifier    = NSToolbarItem.Identifier("QMD.link")
    private static let codeItemIdentifier    = NSToolbarItem.Identifier("QMD.code")
    private static let exportItemIdentifier  = NSToolbarItem.Identifier("QMD.exportPDF")
    private static let readingItemIdentifier = NSToolbarItem.Identifier("QMD.reading")
    private static let speakItemIdentifier   = NSToolbarItem.Identifier("QMD.speak")
    private static let stopSpeakingItemIdentifier = NSToolbarItem.Identifier("QMD.stopSpeaking")
    private static let modeItemIdentifier    = NSToolbarItem.Identifier("QMD.mode")

    private func configureToolbar() {
        guard let window = window else { return }
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        modeSegmented.target = self
        modeSegmented.action = #selector(segmentedModeChanged(_:))
    }

    // MARK: - Toolbar action wrappers

    /// Format action wrappers — toolbar items send their actions to a
    /// concrete target (this controller). We forward to the editor so the
    /// undo coalescing and selection logic in `EditorViewController+Format`
    /// runs against the real text view.
    @objc private func toolbarBold(_ sender: Any?)    { runFormatAction { $0.formatBold(sender) } }
    @objc private func toolbarItalic(_ sender: Any?)  { runFormatAction { $0.formatItalic(sender) } }
    @objc private func toolbarLink(_ sender: Any?)    { runFormatAction { $0.formatLink(sender) } }
    @objc private func toolbarCode(_ sender: Any?)    { runFormatAction { $0.formatCode(sender) } }
    @objc private func toolbarList(_ sender: Any?)    { runFormatAction { $0.formatUnorderedList(sender) } }

    @objc private func toolbarHeading(_ sender: NSPopUpButton) {
        // Item 0 is the placeholder title row; items 1..3 are H1..H3.
        let idx = sender.indexOfSelectedItem
        guard idx >= 1 && idx <= 3 else { return }
        runFormatAction {
            switch idx {
            case 1: $0.formatHeading1(sender)
            case 2: $0.formatHeading2(sender)
            default: $0.formatHeading3(sender)
            }
        }
        sender.selectItem(at: 0)
    }

    @objc private func toolbarExportPDF(_ sender: Any?) {
        exportAsPDF(sender)
    }

    @objc private func toolbarPickTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = ReadingTheme(rawValue: raw) else { return }
        ReadingPreferences.shared.setTheme(theme)
        refreshReadingPopupChecks()
    }

    @objc private func toolbarPickFont(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let family = ReadingFontFamily(rawValue: raw) else { return }
        ReadingPreferences.shared.setFontFamily(family)
        refreshReadingPopupChecks()
    }

    /// Opens the official OpenDyslexic download page. Surfaced from the
    /// Reading popup when the dyslexia-friendly font is not yet installed.
    @objc private func openDyslexicDownloadPage(_ sender: Any?) {
        if let url = URL(string: "https://opendyslexic.org") {
            NSWorkspace.shared.open(url)
        }
    }

    /// After a theme / font change, walk the Reading pulldown's menu and
    /// flip the checkmarks so the user sees which row is active.
    private func refreshReadingPopupChecks() {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items where item.itemIdentifier == Self.readingItemIdentifier {
            guard let popup = item.view as? NSPopUpButton,
                  let menu = popup.menu else { continue }
            let theme = ReadingPreferences.shared.theme
            let font  = ReadingPreferences.shared.fontFamily
            for entry in menu.items {
                guard let raw = entry.representedObject as? String else { continue }
                if entry.action == #selector(toolbarPickTheme(_:)) {
                    entry.state = (raw == theme.rawValue) ? .on : .off
                } else if entry.action == #selector(toolbarPickFont(_:)) {
                    entry.state = (raw == font.rawValue) ? .on : .off
                }
            }
        }
    }

    @objc private func toolbarOpen(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    @objc private func toolbarNew(_ sender: Any?) {
        do {
            try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc private func toolbarSave(_ sender: Any?) {
        markdownDocument?.save(sender)
    }

    /// Run a format-action closure against the editor. If the user is in
    /// Preview mode, switch to Source first so the edit lands in a visible
    /// view, then re-show the preview when done.
    private func runFormatAction(_ block: (EditorViewController) -> Void) {
        let returnToPreview = currentMode == .preview
        if currentMode == .preview {
            applyWindowMode(.source)
        }
        block(editor)
        if returnToPreview {
            applyWindowMode(.preview)
        }
    }

    /// Re-validate every toolbar item so the format buttons can disable
    /// themselves when we're in Preview mode.
    private func invalidateFormatToolbarItems() {
        window?.toolbar?.items.forEach { $0.validate() }
    }

    // MARK: - Edit / File actions

    @objc func copyFormatted(_ sender: Any?) {
        guard let doc = markdownDocument else { return }
        let content = doc.content as NSString
        let selection = editor.textView.selectedRange()
        let safeLocation = max(0, min(selection.location, content.length))
        let safeLength = max(0, min(selection.length, content.length - safeLocation))
        let source: String
        if safeLength > 0 {
            source = content.substring(with: NSRange(location: safeLocation,
                                                     length: safeLength))
        } else {
            source = doc.content
        }
        FormattedPasteboardWriter.writeFormatted(markdownSource: source)
    }

    @objc func exportAsPDF(_ sender: Any?) {
        guard let doc = markdownDocument, let window = window else { return }
        let panel = NSSavePanel()
        panel.title = "Export as PDF"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        if let fileURL = doc.fileURL {
            panel.directoryURL = fileURL.deletingLastPathComponent()
            panel.nameFieldStringValue = fileURL.deletingPathExtension()
                .lastPathComponent + ".pdf"
        } else {
            panel.nameFieldStringValue = doc.displayName + ".pdf"
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let baseURL = doc.fileURL?.deletingLastPathComponent()
            PDFExporter.generate(markdownSource: doc.content,
                                 baseURL: baseURL) { result in
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: url, options: .atomic)
                    } catch {
                        self?.presentExportError(error)
                    }
                case .failure(let error):
                    self?.presentExportError(error)
                }
            }
        }
    }

    @MainActor
    private func presentExportError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Could not export PDF"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: - Speech (read-aloud)

    /// `Edit > Speech > Start Speaking` (⌥⌘.). If text is selected, speak the
    /// selection; otherwise speak the entire document. In preview mode we
    /// speak the rendered plain text and highlight each word as it is read;
    /// in source mode we render the markdown selection (or whole doc) to
    /// plain text first so the user doesn't hear backticks and asterisks,
    /// and use a fuzzy word map (`SpeechSourceMap`) to highlight the
    /// matching word back in the markdown source as the audio plays.
    @objc func startSpeaking(_ sender: Any?) {
        guard let doc = markdownDocument else { return }

        switch currentMode {
        case .preview:
            let payload = preview.speechPayload()
            guard !payload.text.isEmpty else { NSSound.beep(); return }
            speechOffsetIntoPreview = payload.offsetIntoPreview
            sourceSpeechMap = nil
            sourceSpeechOffset = 0
            speech.speak(payload.text)

        case .source:
            let content = doc.content as NSString
            let selection = editor.textView.selectedRange()
            let safeLocation = max(0, min(selection.location, content.length))
            let safeLength = max(0, min(selection.length, content.length - safeLocation))
            let isSelection = safeLength > 0
            let sourceSubstring: String = isSelection
                ? content.substring(with: NSRange(location: safeLocation, length: safeLength))
                : doc.content
            let offsetIntoSource = isSelection ? safeLocation : 0

            let rendered = MarkdownAttributedRenderer.render(
                sourceSubstring,
                baseURL: doc.fileURL?.deletingLastPathComponent()
            ).string
            guard !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep(); return
            }
            speechOffsetIntoPreview = 0
            sourceSpeechMap = SpeechSourceMap(source: sourceSubstring,
                                              rendered: rendered)
            sourceSpeechOffset = offsetIntoSource
            speech.speak(rendered)
        }
    }

    /// `Edit > Speech > Stop Speaking` (⌃⌘.).
    @objc func stopSpeaking(_ sender: Any?) {
        speech.stop()
        preview.highlightSpokenRange(NSRange(location: NSNotFound, length: 0))
        editor.highlightSpokenRange(NSRange(location: NSNotFound, length: 0))
        speechOffsetIntoPreview = 0
        sourceSpeechMap = nil
        sourceSpeechOffset = 0
    }

    /// `Edit > Speech > Pause/Resume Speaking`. The menu item title flips
    /// between "Pause Speaking" and "Resume Speaking" via menu validation.
    @objc func togglePauseSpeaking(_ sender: Any?) {
        speech.togglePause()
    }

    /// Translate a rendered-string range from the speech synthesiser to a
    /// markdown-source range via `sourceSpeechMap`, then highlight it in the
    /// editor. Clears the editor highlight when the range can't be mapped
    /// (e.g. spoken word has no matching source token, or speech ended).
    private func highlightSourceForSpokenRange(_ range: NSRange) {
        guard range.location != NSNotFound, range.length > 0 else {
            editor.highlightSpokenRange(NSRange(location: NSNotFound, length: 0))
            return
        }
        guard let map = sourceSpeechMap,
              let sourceRange = map.sourceRange(for: range) else {
            // Leave the previous highlight in place rather than flickering it
            // off for unmatched words like "the", "a", punctuation, etc.
            return
        }
        let translated = NSRange(
            location: sourceRange.location + sourceSpeechOffset,
            length: sourceRange.length
        )
        editor.highlightSpokenRange(translated)
    }

    // MARK: - Status bar

    private func scheduleStatusBarRefresh() {
        pendingStatusRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshStatusBar()
            }
        }
        pendingStatusRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func refreshStatusBar() {
        guard let doc = markdownDocument else { return }
        statusBar.update(.init(
            content: doc.content,
            fileURL: doc.fileURL,
            isEdited: doc.isDocumentEdited,
            fileModificationDate: doc.fileModificationDate
        ))
    }

    // MARK: - Banner

    @MainActor
    private func showBanner() {
        guard !bannerVisible else { return }
        bannerVisible = true
        banner.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            bannerHeightConstraint.constant = 36
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    @MainActor
    private func hideBannerIfNeeded() {
        guard bannerVisible else { return }
        bannerVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            bannerHeightConstraint.constant = 0
            window?.contentView?.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.banner.isHidden = true
            }
        }
    }

    @MainActor
    private func handleBannerReload() {
        markdownDocument?.acceptPendingExternalContent()
    }

    @MainActor
    private func handleBannerKeep() {
        markdownDocument?.dismissPendingExternalContent()
        hideBannerIfNeeded()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        refreshStatusBar()
    }

    deinit {
        for token in [externalChangeObserver, conflictObserver, textChangeObserver] {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}

// MARK: - NSToolbarDelegate

extension DocumentWindowController: NSToolbarDelegate {

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.openItemIdentifier:
            return makeImageItem(itemIdentifier,
                                 symbol: "folder",
                                 label: "Open",
                                 tooltip: "Open a Markdown file (⌘O)",
                                 action: #selector(toolbarOpen(_:)))
        case Self.newItemIdentifier:
            return makeImageItem(itemIdentifier,
                                 symbol: "square.and.pencil",
                                 label: "New",
                                 tooltip: "New document (⌘N)",
                                 action: #selector(toolbarNew(_:)))
        case Self.saveItemIdentifier:
            return makeImageItem(itemIdentifier,
                                 symbol: "tray.and.arrow.down",
                                 label: "Save",
                                 tooltip: "Save (⌘S)",
                                 action: #selector(toolbarSave(_:)))
        case Self.boldItemIdentifier:
            return makeFormatItem(itemIdentifier,
                                  symbol: "bold",
                                  label: "Bold",
                                  tooltip: "Bold (⌘B)",
                                  action: #selector(toolbarBold(_:)))
        case Self.italicItemIdentifier:
            return makeFormatItem(itemIdentifier,
                                  symbol: "italic",
                                  label: "Italic",
                                  tooltip: "Italic (⌘I)",
                                  action: #selector(toolbarItalic(_:)))
        case Self.headingItemIdentifier:
            return makeHeadingPopupItem(itemIdentifier)
        case Self.listItemIdentifier:
            return makeFormatItem(itemIdentifier,
                                  symbol: "list.bullet",
                                  label: "List",
                                  tooltip: "Bulleted list",
                                  action: #selector(toolbarList(_:)))
        case Self.linkItemIdentifier:
            return makeFormatItem(itemIdentifier,
                                  symbol: "link",
                                  label: "Link",
                                  tooltip: "Insert link (⌘K)",
                                  action: #selector(toolbarLink(_:)))
        case Self.codeItemIdentifier:
            return makeFormatItem(itemIdentifier,
                                  symbol: "chevron.left.forwardslash.chevron.right",
                                  label: "Code",
                                  tooltip: "Inline code (⌘E)",
                                  action: #selector(toolbarCode(_:)))
        case Self.exportItemIdentifier:
            return makeImageItem(itemIdentifier,
                                 symbol: "arrow.up.doc",
                                 label: "Export PDF",
                                 tooltip: "Export as PDF (⌘⇧E)",
                                 action: #selector(toolbarExportPDF(_:)))
        case Self.readingItemIdentifier:
            return makeReadingPopupItem(itemIdentifier)
        case Self.speakItemIdentifier:
            let item = SpeechToolbarItem(itemIdentifier: itemIdentifier, kind: .speak)
            item.label = "Speak"
            item.paletteLabel = "Read Aloud"
            item.target = self
            item.windowControllerRef = self
            item.isBordered = true
            // Initial state — validate() will keep this in sync afterwards.
            item.image = NSImage(systemSymbolName: "speaker.wave.2",
                                 accessibilityDescription: "Read aloud")
            item.toolTip = "Read aloud (\u{2325}\u{2318}.)"
            item.action = #selector(startSpeaking(_:))
            return item
        case Self.stopSpeakingItemIdentifier:
            let item = SpeechToolbarItem(itemIdentifier: itemIdentifier, kind: .stop)
            item.label = "Stop"
            item.paletteLabel = "Stop Reading"
            item.toolTip = "Stop reading (\u{2303}\u{2318}.)"
            item.target = self
            item.action = #selector(stopSpeaking(_:))
            item.windowControllerRef = self
            item.isBordered = true
            item.image = NSImage(systemSymbolName: "stop.fill",
                                 accessibilityDescription: "Stop reading")
            return item
        case Self.modeItemIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "View"
            item.paletteLabel = "Display Mode"
            item.toolTip = "Switch between Preview and Source (⌘⌥P)"
            item.view = modeSegmented

            // Overflow-menu fallback: when the toolbar collapses into the
            // chevron, AppKit renders this NSMenuItem (with its submenu)
            // instead of the segmented control. The two children let the
            // user pick Preview or Source directly from the chevron.
            let submenu = NSMenu(title: "View")
            let previewItem = NSMenuItem(
                title: "Preview",
                action: #selector(selectWindowMode(_:)),
                keyEquivalent: ""
            )
            previewItem.tag = 0
            previewItem.target = self
            let sourceItem = NSMenuItem(
                title: "Source",
                action: #selector(selectWindowMode(_:)),
                keyEquivalent: ""
            )
            sourceItem.tag = 1
            sourceItem.target = self
            submenu.addItem(previewItem)
            submenu.addItem(sourceItem)
            submenu.autoenablesItems = true

            let menuRep = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            menuRep.submenu = submenu
            item.menuFormRepresentation = menuRep
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        [
            Self.openItemIdentifier,
            Self.newItemIdentifier,
            Self.saveItemIdentifier,
            .space,
            Self.boldItemIdentifier,
            Self.italicItemIdentifier,
            Self.headingItemIdentifier,
            Self.listItemIdentifier,
            Self.linkItemIdentifier,
            Self.codeItemIdentifier,
            .space,
            Self.exportItemIdentifier,
            Self.readingItemIdentifier,
            .space,
            Self.speakItemIdentifier,
            Self.stopSpeakingItemIdentifier,
            .flexibleSpace,
            Self.modeItemIdentifier,
        ]
    }

    func toolbarAllowedItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        [
            Self.openItemIdentifier,
            Self.newItemIdentifier,
            Self.saveItemIdentifier,
            Self.boldItemIdentifier,
            Self.italicItemIdentifier,
            Self.headingItemIdentifier,
            Self.listItemIdentifier,
            Self.linkItemIdentifier,
            Self.codeItemIdentifier,
            Self.exportItemIdentifier,
            Self.readingItemIdentifier,
            Self.speakItemIdentifier,
            Self.stopSpeakingItemIdentifier,
            Self.modeItemIdentifier,
            .flexibleSpace,
            .space,
        ]
    }

    // MARK: Toolbar item factories

    private func makeImageItem(_ id: NSToolbarItem.Identifier,
                               symbol: String,
                               label: String,
                               tooltip: String,
                               action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tooltip
        item.target = self
        item.action = action
        item.isBordered = true
        if let image = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: label) {
            item.image = image
        }
        return item
    }

    private func makeFormatItem(_ id: NSToolbarItem.Identifier,
                                symbol: String,
                                label: String,
                                tooltip: String,
                                action: Selector) -> NSToolbarItem {
        let item = FormatToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tooltip
        item.target = self
        item.action = action
        item.isBordered = true
        if let image = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: label) {
            item.image = image
        }
        item.windowControllerRef = self
        return item
    }

    private func makeHeadingPopupItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 48, height: 24),
                                  pullsDown: true)
        popup.bezelStyle = .toolbar
        popup.isBordered = true
        popup.target = self
        popup.action = #selector(toolbarHeading(_:))

        // Item 0 is the always-visible title (the SF Symbol).
        let titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        titleItem.image = NSImage(systemSymbolName: "textformat.size",
                                  accessibilityDescription: "Heading")
        popup.menu?.addItem(titleItem)
        popup.menu?.addItem(NSMenuItem(title: "Heading 1",
                                       action: nil,
                                       keyEquivalent: ""))
        popup.menu?.addItem(NSMenuItem(title: "Heading 2",
                                       action: nil,
                                       keyEquivalent: ""))
        popup.menu?.addItem(NSMenuItem(title: "Heading 3",
                                       action: nil,
                                       keyEquivalent: ""))

        let item = FormatToolbarItem(itemIdentifier: id)
        item.label = "Heading"
        item.paletteLabel = "Heading"
        item.toolTip = "Set heading level"
        item.view = popup
        item.windowControllerRef = self
        return item
    }

    /// Build the Reading pulldown — a single toolbar item that exposes the
    /// theme choices (top section) and the font choices (bottom section).
    /// We use representedObject on each NSMenuItem to carry the enum case so
    /// the action knows what to apply.
    private func makeReadingPopupItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 48, height: 24),
                                  pullsDown: true)
        popup.bezelStyle = .toolbar
        popup.isBordered = true

        // Item 0: always-visible title (SF Symbol).
        let titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        titleItem.image = NSImage(systemSymbolName: "textformat",
                                  accessibilityDescription: "Reading appearance")
        popup.menu?.addItem(titleItem)

        let themeHeader = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeHeader.isEnabled = false
        popup.menu?.addItem(themeHeader)
        let currentTheme = ReadingPreferences.shared.theme
        for theme in ReadingTheme.allCases {
            let it = NSMenuItem(title: theme.displayName,
                                action: #selector(toolbarPickTheme(_:)),
                                keyEquivalent: "")
            it.target = self
            it.representedObject = theme.rawValue
            it.state = (theme == currentTheme) ? .on : .off
            popup.menu?.addItem(it)
        }

        popup.menu?.addItem(.separator())

        let fontHeader = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        fontHeader.isEnabled = false
        popup.menu?.addItem(fontHeader)
        let currentFont = ReadingPreferences.shared.fontFamily
        for family in ReadingFontFamily.allCases {
            let it = NSMenuItem(title: family.displayName,
                                action: #selector(toolbarPickFont(_:)),
                                keyEquivalent: "")
            it.target = self
            it.representedObject = family.rawValue
            it.isEnabled = family.isAvailable
            if !family.isAvailable {
                it.title = "\(family.displayName) (not installed)"
            }
            it.state = (family == currentFont) ? .on : .off
            popup.menu?.addItem(it)
        }

        // If the dyslexia-friendly font isn't installed, give the user a
        // one-click route to the OpenDyslexic download page.
        if !ReadingFontFamily.dyslexic.isAvailable {
            let getIt = NSMenuItem(
                title: "Get OpenDyslexic Font…",
                action: #selector(openDyslexicDownloadPage(_:)),
                keyEquivalent: ""
            )
            getIt.target = self
            getIt.indentationLevel = 1
            popup.menu?.addItem(getIt)
        }

        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Reading"
        item.paletteLabel = "Reading Appearance"
        item.toolTip = "Background colour, text colour, and font"
        item.view = popup
        return item
    }
}

// MARK: - Toolbar item that disables itself in Preview mode

/// Format toolbar items need to be disabled while the window is in Preview
/// mode (Preview is read-only). `NSToolbarItem.validate()` is called by AppKit
/// after key-window changes and whenever we ask via `invalidateFormatToolbarItems()`.
final class FormatToolbarItem: NSToolbarItem {

    weak var windowControllerRef: DocumentWindowController?

    override func validate() {
        let isSource = (windowControllerRef?.currentMode ?? .source) == .source
        if let control = view as? NSControl {
            control.isEnabled = isSource
        } else {
            isEnabled = isSource
        }
    }
}

// MARK: - Toolbar item for the Speak / Stop buttons

/// Toolbar buttons whose icon and primary action change with the synthesiser
/// state:
///
/// * `.speak`: idle  → speaker icon, action = startSpeaking;
///             speaking → pause icon, action = togglePauseSpeaking;
///             paused → play icon,  action = togglePauseSpeaking.
/// * `.stop`:  enabled whenever speech is active, otherwise greyed out.
///
/// State refresh is driven by `invalidateFormatToolbarItems()` (which calls
/// `validate()` on every toolbar item), kicked off from the
/// `SpeechController.onStateChange` callback.
final class SpeechToolbarItem: NSToolbarItem {

    enum Kind { case speak, stop }

    let kind: Kind
    weak var windowControllerRef: DocumentWindowController?

    init(itemIdentifier: NSToolbarItem.Identifier, kind: Kind) {
        self.kind = kind
        super.init(itemIdentifier: itemIdentifier)
    }

    override func validate() {
        guard let wc = windowControllerRef else { return }
        switch kind {
        case .speak:
            switch wc.speechState {
            case .idle:
                image = NSImage(systemSymbolName: "speaker.wave.2",
                                accessibilityDescription: "Read aloud")
                toolTip = "Read aloud (\u{2325}\u{2318}.)"
                action = #selector(DocumentWindowController.startSpeaking(_:))
                label = "Speak"
            case .speaking:
                image = NSImage(systemSymbolName: "pause.fill",
                                accessibilityDescription: "Pause reading")
                toolTip = "Pause reading"
                action = #selector(DocumentWindowController.togglePauseSpeaking(_:))
                label = "Pause"
            case .paused:
                image = NSImage(systemSymbolName: "play.fill",
                                accessibilityDescription: "Resume reading")
                toolTip = "Resume reading"
                action = #selector(DocumentWindowController.togglePauseSpeaking(_:))
                label = "Resume"
            }
            isEnabled = true
        case .stop:
            isEnabled = wc.speechIsActive
        }
    }
}

// MARK: - Bridge so the toolbar can expose list/blockquote actions

extension EditorViewController {

    /// Convert the selected lines into a `- `-prefixed unordered list. Strips
    /// any existing `- ` prefix first so re-clicking removes the list.
    @objc func formatUnorderedList(_ sender: Any?) {
        toggleLinePrefix("- ")
    }

    /// Toggle a `> ` blockquote prefix on the selected lines.
    @objc func formatBlockquote(_ sender: Any?) {
        toggleLinePrefix("> ")
    }

    private func toggleLinePrefix(_ prefix: String) {
        let store = textView.textStorage ?? NSTextStorage()
        let ns = store.string as NSString
        let selRange = textView.selectedRange()
        let lineRange = ns.lineRange(for: selRange)
        let original = ns.substring(with: lineRange)
        let trailingNewline = original.hasSuffix("\n")
        let body = trailingNewline ? String(original.dropLast()) : original
        let lines = body.components(separatedBy: "\n")

        let allHavePrefix = lines.allSatisfy { line in
            line.isEmpty || line.hasPrefix(prefix)
        }
        let transformed: [String]
        if allHavePrefix {
            transformed = lines.map { line in
                line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
            }
        } else {
            transformed = lines.map { line in
                line.isEmpty ? line : prefix + line
            }
        }
        var replacement = transformed.joined(separator: "\n")
        if trailingNewline { replacement.append("\n") }

        guard textView.shouldChangeText(in: lineRange,
                                        replacementString: replacement) else { return }
        textView.replaceCharacters(in: lineRange, with: replacement)
        textView.didChangeText()
    }
}

// MARK: - Menu validation (speech menu items)

extension DocumentWindowController: NSMenuItemValidation {

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectWindowMode(_:)):
            menuItem.state = (menuItem.tag == 0 && currentMode == .preview) ||
                             (menuItem.tag == 1 && currentMode == .source)
                             ? .on : .off
            return true
        case #selector(startSpeaking(_:)):
            // Start is always available when there's something to read; the
            // action will beep if it turns out to be empty.
            return !speech.isSpeaking
        case #selector(stopSpeaking(_:)):
            return speech.isActive
        case #selector(togglePauseSpeaking(_:)):
            switch speech.state {
            case .speaking:
                menuItem.title = "Pause Speaking"
                return true
            case .paused:
                menuItem.title = "Resume Speaking"
                return true
            case .idle:
                menuItem.title = "Pause Speaking"
                return false
            }
        default:
            return true
        }
    }
}
