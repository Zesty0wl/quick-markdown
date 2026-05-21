import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Force our custom NSDocumentController to be used. Must happen
        // before AppKit's restoration machinery calls
        // `NSDocumentController.shared`.
        _ = QuickMarkdownDocumentController.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenuBuilder.install()
        NSApp.activate(ignoringOtherApps: true)
        // First-launch only: explain why we need home-folder access and
        // surface the TCC prompts up front rather than mid-edit.
        HomeAccessOnboarding.runIfNeeded()
        // Throttled (once / 24h) GitHub Releases poll. No-op on failure
        // and when up to date. See `UpdateChecker` for the rationale.
        UpdateChecker.shared.checkOnLaunchIfNeeded()
    }

    /// Cold launch with no command-line files / no autorestored docs:
    /// greet the user with a blank untitled document so they can paste
    /// Markdown straight in and flip to the Preview pane.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        // We intentionally do not restore document windows on launch — a
        // fresh untitled doc is what the user sees on cold launch.
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive after the last document closes so the user can come
        // back to the app via the Dock without re-launching. We'll spawn a
        // new untitled doc on re-activation (see `applicationShouldHandleReopen`).
        false
    }

    /// Re-dock click on macOS: if there are no visible windows, mint a fresh
    /// untitled doc rather than leaving the user staring at nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSDocumentController.shared.newDocument(nil)
        }
        return true
    }
}

/// Custom NSDocumentController. We keep the subclass around so we can swap
/// in additional behaviour later (custom open-panel filtering, untitled-doc
/// naming, etc.) without touching the rest of the app.
@MainActor
final class QuickMarkdownDocumentController: NSDocumentController {

    /// Restore autosaved documents on launch — but only when there's
    /// something worth bringing back. AppKit calls this for every entry
    /// AppKit thinks should be reopened:
    ///
    /// * `urlOrNil != nil` — a previously-saved file. Always restore; the
    ///   user explicitly committed it to disk.
    /// * `urlOrNil == nil` — an autosaved *draft* of a never-saved
    ///   Untitled window. Restore it only when the draft has real content
    ///   (any non-whitespace byte). Empty drafts are leftover ghosts from
    ///   prior launches and we silently drop + clean them up so they
    ///   don't keep haunting us.
    override func reopenDocument(for urlOrNil: URL?,
                                 withContentsOf contentsURL: URL,
                                 display displayDocument: Bool,
                                 completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        if urlOrNil != nil {
            super.reopenDocument(for: urlOrNil,
                                 withContentsOf: contentsURL,
                                 display: displayDocument,
                                 completionHandler: completionHandler)
            return
        }

        if Self.draftHasMeaningfulContent(at: contentsURL) {
            super.reopenDocument(for: urlOrNil,
                                 withContentsOf: contentsURL,
                                 display: displayDocument,
                                 completionHandler: completionHandler)
            return
        }

        try? FileManager.default.removeItem(at: contentsURL)
        completionHandler(nil, false, nil)
    }

    /// Returns true if the autosaved draft at `url` is worth restoring on
    /// launch — i.e. its UTF-8 decoded contents contain at least one
    /// non-whitespace character. We check the bytes rather than the file
    /// size so a draft consisting of a few stray newlines from a bug or
    /// from `MarkdownTextStorage`'s placeholder writes still counts as a
    /// ghost.
    private static func draftHasMeaningfulContent(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whenever we open a file (from File > Open, Open Recent, drag-drop,
    /// or Finder double-click), if the frontmost window holds an empty
    /// untitled document we close it after the new one is on screen.
    /// This avoids leaving a useless blank window behind when the user is
    /// "navigating" rather than collecting multiple docs.
    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        let candidate = emptyUntitledDocumentToReplace()
        super.openDocument(withContentsOf: url,
                           display: displayDocument) { newDoc, wasAlreadyOpen, error in
            if let candidate, newDoc !== candidate, error == nil {
                // Close the empty placeholder. No need to prompt — it has
                // no content and no fileURL, so nothing can be lost.
                candidate.close()
            }
            completionHandler(newDoc, wasAlreadyOpen, error)
        }
    }

    /// Returns the frontmost `MarkdownDocument` if it is untitled, has no
    /// edits, and contains no content. `nil` otherwise — in which case the
    /// new document should open into a fresh window as before.
    private func emptyUntitledDocumentToReplace() -> MarkdownDocument? {
        // Prefer the document attached to the key window so the user's
        // current focus drives the decision.
        let candidate: NSDocument? =
            NSApp.keyWindow?.windowController?.document as? NSDocument
            ?? NSApp.mainWindow?.windowController?.document as? NSDocument
            ?? documents.last
        guard let doc = candidate as? MarkdownDocument,
              doc.fileURL == nil,
              !doc.isDocumentEdited,
              doc.content.isEmpty
        else { return nil }
        return doc
    }
}

// MARK: - Drag-and-drop helpers

extension QuickMarkdownDocumentController {

    /// File extensions we accept as document drops (from windows or the Dock
    /// tile). Kept in sync with `CFBundleDocumentTypes` in Info.plist.
    static let droppableMarkdownExtensions: Set<String> = ["md", "markdown"]

    /// Pulls markdown file URLs out of a dragging pasteboard. Returns `nil`
    /// when the drag carries no markdown file, so callers can cleanly fall
    /// through to whatever default drop behaviour the view has (text
    /// insertion for the editor, navigation for the web preview, etc.).
    ///
    /// Implementation note: we deliberately avoid
    /// `readObjects(forClasses: [NSURL.self], options:)` here. That call
    /// constructs `NSURL` objects from the pasteboard, which triggers
    /// file coordination / `stat()` on each URL — and on network mounts,
    /// iCloud placeholders, or slow DFS shares that synchronously stalls
    /// the main thread for several seconds (visible as a beach-ball while
    /// the user is just hovering a drag over the window). Instead we read
    /// the file URL as a string per pasteboard item (which Finder writes
    /// eagerly into the in-memory pasteboard) and parse it. No I/O.
    static func markdownURLs(in sender: any NSDraggingInfo) -> [URL]? {
        let pb = sender.draggingPasteboard
        // Cheap bail-out: nothing on the pasteboard can be read as a file
        // URL. `canReadItem(withDataConformingToTypes:)` only checks the
        // type list; it does not materialise any data.
        let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue
        guard pb.canReadItem(withDataConformingToTypes: [fileURLType]),
              let items = pb.pasteboardItems
        else { return nil }

        var mdURLs: [URL] = []
        for item in items {
            guard let urlString = item.string(forType: .fileURL),
                  let url = URL(string: urlString),
                  url.isFileURL
            else { continue }
            if droppableMarkdownExtensions.contains(url.pathExtension.lowercased()) {
                mdURLs.append(url)
            }
        }
        return mdURLs.isEmpty ? nil : mdURLs
    }

    /// Open the supplied markdown URLs. Routes through the standard
    /// `openDocument(withContentsOf:display:completionHandler:)` so the
    /// existing "replace the empty untitled window if there is one, else
    /// spawn a new one" logic in `openDocument` applies uniformly to
    /// File > Open, Dock drops, and in-window drops.
    @MainActor
    static func openMarkdownURLs(_ urls: [URL]) {
        let controller = NSDocumentController.shared
        for url in urls {
            controller.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }
}


