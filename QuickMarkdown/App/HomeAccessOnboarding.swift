import AppKit

/// One-time first-launch flow that nudges macOS into showing its TCC
/// permission sheets for the user's Desktop / Documents / Downloads folders
/// up front, rather than mid-edit when the user is opening their first
/// Markdown file with images.
///
/// **Why this is needed even with the sandbox temporary-exception.**
/// `com.apple.security.temporary-exception.files.home-relative-path.read-only`
/// satisfies the *sandbox* layer for sibling-image reads, but TCC is a
/// separate gate. The first time the app touches `~/Desktop`, `~/Documents`,
/// or `~/Downloads`, macOS still pops the standard "Quick Markdown would
/// like to access files in your Desktop folder" sheet. Triggering all three
/// at the start of the user's first session means they get one explanatory
/// alert followed by three system prompts, instead of being surprised by a
/// prompt every time they double-click a Markdown file in a different
/// folder.
///
/// We *don't* persist any state ourselves — TCC already remembers each
/// per-folder grant on its own (keyed by the app's code-signing identity).
/// We only persist the UserDefaults flag so we don't re-run the welcome
/// alert on subsequent launches.
@MainActor
enum HomeAccessOnboarding {

    /// UserDefaults key that records whether we've already shown the
    /// welcome alert. Bumping the suffix forces the alert to re-appear
    /// for existing users (useful if we change the copy materially).
    private static let didOnboardKey = "didOnboardHomeAccess.v1"

    /// Folders the alert primes. We intentionally avoid Pictures / Movies /
    /// Music because those aren't typical Markdown-asset locations and we
    /// don't want to ask for access the user wouldn't expect.
    private static let primedSubfolders = ["Desktop", "Documents", "Downloads"]

    /// Shows the welcome alert (once) and then touches each protected
    /// folder so macOS surfaces its TCC prompts in sequence. Safe to call
    /// from `applicationDidFinishLaunching` — if onboarding has already
    /// happened this method returns immediately.
    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: didOnboardKey) else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Welcome to Quick Markdown"
        alert.informativeText = """
            Quick Markdown opens Markdown files and renders the images they \
            reference (PNG, JPEG, SVG, …). macOS will ask you to grant access \
            to your Desktop, Documents, and Downloads folders so those images \
            can be loaded without prompting every time.

            Click Continue to grant access now, or Later to decide per-folder \
            when you first open a file.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            // User chose Later — don't burn the flag, so we'll ask again
            // next launch. Spammy if they keep clicking Later, but
            // strictly better than silently never asking again.
            return
        }

        primeAllFolders()
        UserDefaults.standard.set(true, forKey: didOnboardKey)
    }

    /// Walks each primed subfolder and issues a `contentsOfDirectory` call
    /// purely to provoke TCC's prompt-on-first-access. Results are
    /// discarded; we don't care whether the listing succeeds, only that
    /// the OS surfaced (and the user resolved) the access dialog.
    private static func primeAllFolders() {
        let fm = FileManager.default
        let home = realHomeDirectory()
        for name in primedSubfolders {
            let folder = home.appendingPathComponent(name)
            _ = try? fm.contentsOfDirectory(at: folder,
                                            includingPropertiesForKeys: nil,
                                            options: [.skipsHiddenFiles])
        }
    }

    /// Returns the user's *real* home directory (e.g. `/Users/jane`).
    /// `NSHomeDirectory()` returns the sandbox container path
    /// (`~/Library/Containers/<bundle-id>/Data`) which would defeat the
    /// purpose of priming — TCC keys on the canonical home subpaths.
    private static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()),
           let cString = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: cString))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}
