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
}


