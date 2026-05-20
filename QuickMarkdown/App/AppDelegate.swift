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

    /// Skip autosaved-document restoration on launch entirely. AppKit
    /// otherwise re-opens the most-recent autosaved untitled docs, which
    /// would stack a half-restored window on top of the fresh untitled doc
    /// we mint via `applicationShouldOpenUntitledFile`.
    override func reopenDocument(for urlOrNil: URL?,
                                 withContentsOf contentsURL: URL,
                                 display displayDocument: Bool,
                                 completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        if urlOrNil == nil {
            completionHandler(nil, false, nil)
            return
        }
        super.reopenDocument(for: urlOrNil,
                             withContentsOf: contentsURL,
                             display: displayDocument,
                             completionHandler: completionHandler)
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


