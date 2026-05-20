import AppKit

/// NSDocument backing a single Markdown file. Owns the canonical raw text.
///
/// Phase 1 introduced the read/write paths. Phase 2.5 adds `NSFilePresenter`
/// behaviour so external writes are reflected within ~150 ms (the LLM-tail
/// workflow), with a conflict path when the user has unsaved local edits.
@MainActor
final class MarkdownDocument: NSDocument {

    // MARK: - Content

    /// The raw Markdown source. Always the truth — display attributes are
    /// layered on top of this in the editor.
    ///
    /// Marked `nonisolated(unsafe)` because the NSDocument read/write hooks
    /// in the Swift 6 overlays are `nonisolated`; all mutation funnels through
    /// `setContent(_:)` and happens on a single sequenced path.
    @objc dynamic nonisolated(unsafe) private(set) var content: String = ""

    /// Silently update `content`. Used by the editor's typing writeback path.
    /// External-change notifications are NOT posted from here — see
    /// `applyExternalRead(_:hadLocalEdits:)`.
    nonisolated func setContent(_ newValue: String) {
        content = newValue
    }

    // MARK: - Notifications

    /// Posted on the main queue when the file backing this document changed
    /// outside the editor and we silently re-loaded the buffer. Observers
    /// should refresh their views and preserve scroll / cursor.
    nonisolated static let contentDidChangeExternallyNotification =
        Notification.Name("MarkdownDocumentContentDidChangeExternally")

    /// Posted on the main queue when the file changed externally but the
    /// document also has unsaved local edits. The window controller should
    /// surface a non-modal "reload / keep my changes" banner.
    nonisolated static let contentConflictDetectedNotification =
        Notification.Name("MarkdownDocumentContentConflictDetected")

    /// Pending externally-read content captured by the file presenter while
    /// the document had unsaved edits. Consumed by `acceptPendingExternalContent()`.
    private(set) var pendingExternalContent: String?

    // MARK: - NSDocument basics

    override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }
    override class var preservesVersions: Bool { false }

    override func makeWindowControllers() {
        let controller = DocumentWindowController()
        addWindowController(controller)
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadInapplicableStringEncodingError,
                userInfo: [NSLocalizedDescriptionKey: "File is not valid UTF-8."]
            )
        }
        setContent(string)
    }

    override nonisolated func data(ofType typeName: String) throws -> Data {
        guard let data = content.data(using: .utf8) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteInapplicableStringEncodingError,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode content as UTF-8."]
            )
        }
        return data
    }

    // MARK: - File presenter (Phase 2.5)

    /// Dedicated serial queue for file-change callbacks. NSDocument's default
    /// presenter queue is the main queue, which would block the UI on big
    /// reads.
    private nonisolated let _presenterQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "QuickMarkdown.MarkdownDocument.FilePresenter"
        q.qualityOfService = .userInitiated
        return q
    }()

    override nonisolated var presentedItemOperationQueue: OperationQueue {
        _presenterQueue
    }

    /// Serial queue for debouncing rapid file-change notifications.
    private nonisolated let reloadQueue = DispatchQueue(
        label: "QuickMarkdown.MarkdownDocument.ReloadDebounce")

    /// The currently-pending debounce work item. Touched only on `reloadQueue`.
    private nonisolated(unsafe) var pendingReload: DispatchWorkItem?

    private nonisolated static let debounceInterval: DispatchTimeInterval = .milliseconds(150)

    override nonisolated func presentedItemDidChange() {
        // Called on `_presenterQueue`. Bounce onto our debouncer.
        reloadQueue.async { [weak self] in
            guard let self else { return }
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.kickOffExternalRead()
            }
            self.pendingReload = work
            self.reloadQueue.asyncAfter(
                deadline: .now() + Self.debounceInterval,
                execute: work
            )
        }
    }

    /// Step 1 (off main): hop to main to snapshot `fileURL` and edit state,
    /// then dispatch the actual coordinated read off-main again.
    private nonisolated func kickOffExternalRead() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let url = self.fileURL else { return }
                self.coordinatedRead(at: url)
            }
        }
    }

    @MainActor
    private func coordinatedRead(at url: URL) {
        let presenter: NSFilePresenter = self
        let currentContent = content
        let isEdited = isDocumentEdited
        Task.detached(priority: .userInitiated) { [weak self] in
            let coordinator = NSFileCoordinator(filePresenter: presenter)
            var newString: String?
            var coordError: NSError?
            coordinator.coordinate(
                readingItemAt: url,
                options: [.withoutChanges],
                error: &coordError
            ) { resolvedURL in
                if let data = try? Data(contentsOf: resolvedURL),
                   let s = String(data: data, encoding: .utf8) {
                    newString = s
                }
            }
            guard let s = newString, s != currentContent else { return }
            await MainActor.run {
                self?.applyExternalRead(s, hadLocalEdits: isEdited)
            }
        }
    }

    @MainActor
    private func applyExternalRead(_ newString: String, hadLocalEdits: Bool) {
        if newString == content { return }
        if isDocumentEdited && hadLocalEdits {
            pendingExternalContent = newString
            NotificationCenter.default.post(
                name: Self.contentConflictDetectedNotification,
                object: self
            )
        } else {
            setContent(newString)
            updateChangeCount(.changeCleared)
            NotificationCenter.default.post(
                name: Self.contentDidChangeExternallyNotification,
                object: self
            )
        }
    }

    /// Called by the window controller when the user clicks "Reload" on the
    /// conflict banner. Replaces the buffer with the externally-read content
    /// and clears the conflict state.
    @MainActor
    func acceptPendingExternalContent() {
        guard let newString = pendingExternalContent else { return }
        pendingExternalContent = nil
        setContent(newString)
        updateChangeCount(.changeCleared)
        NotificationCenter.default.post(
            name: Self.contentDidChangeExternallyNotification,
            object: self
        )
    }

    /// Called by the window controller when the user clicks "Keep my changes".
    /// Discards the externally-read snapshot so the banner can dismiss without
    /// touching the buffer.
    @MainActor
    func dismissPendingExternalContent() {
        pendingExternalContent = nil
    }
}
