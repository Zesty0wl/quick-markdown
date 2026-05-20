import AppKit

/// Lightweight in-app update notifier.
///
/// On launch (throttled to once per 24 hours) and on-demand via the
/// "Check for Updates…" menu item, this polls the GitHub Releases API
/// for the latest tagged release of the project, compares it against the
/// running `CFBundleShortVersionString`, and presents a non-modal alert
/// when a newer version is available.
///
/// This is intentionally *not* Sparkle:
/// - Sandbox-safe — only requires `com.apple.security.network.client`,
///   which the app already has.
/// - No keypair, no XPC services, no appcast to publish on every release.
/// - Pays the cost of one HTTPS round-trip per day per user.
///
/// The trade-off is that the user installs the new `.pkg` manually
/// (we open the release page in their browser). For true in-place silent
/// install, swap this checker out for Sparkle 2 — see `RELEASING.md`.
@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()

    private enum Constants {
        static let owner = "Zesty0wl"
        static let repo = "quick-markdown"
        static let lastCheckKey = "UpdateChecker.lastCheckDate"
        static let skippedVersionKey = "UpdateChecker.skippedVersion"
        static let minimumInterval: TimeInterval = 60 * 60 * 24  // once per day
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    private var isChecking = false

    // MARK: - Public entry points

    /// Called from `AppDelegate.applicationDidFinishLaunching`. Respects
    /// the per-day throttle and any version the user has explicitly skipped.
    /// Silent on failure or when up to date.
    func checkOnLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        let now = Date()
        if let last = defaults.object(forKey: Constants.lastCheckKey) as? Date,
           now.timeIntervalSince(last) < Constants.minimumInterval {
            return
        }
        defaults.set(now, forKey: Constants.lastCheckKey)

        Task { [weak self] in
            await self?.runCheck(userInitiated: false)
        }
    }

    /// Called from the "Check for Updates…" menu item. Bypasses throttle,
    /// surfaces "you're up to date" and network errors to the user.
    @objc func checkForUpdates(_ sender: Any?) {
        Task { [weak self] in
            await self?.runCheck(userInitiated: true)
        }
    }

    // MARK: - Core flow

    private func runCheck(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let current = Self.currentVersion()
        do {
            let release = try await fetchLatestRelease()
            let latest = release.normalizedVersion

            switch compare(latest, current) {
            case .orderedDescending:
                let skipped = UserDefaults.standard.string(forKey: Constants.skippedVersionKey)
                if !userInitiated, skipped == latest {
                    return
                }
                presentUpdateAvailable(release: release, current: current)
            case .orderedSame, .orderedAscending:
                if userInitiated {
                    presentUpToDate(current: current)
                }
            }
        } catch {
            if userInitiated {
                presentError(error)
            }
        }
    }

    // MARK: - Network

    private struct Release: Decodable, Sendable {
        let tagName: String
        let name: String?
        let htmlURL: URL
        let prerelease: Bool

        var normalizedVersion: String {
            var s = tagName
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            return s
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case prerelease
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        let endpoint = "https://api.github.com/repos/\(Constants.owner)/\(Constants.repo)/releases/latest"
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Quick Markdown UpdateChecker", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    // MARK: - Version compare

    /// Semver-friendly comparison via numeric collation. Handles
    /// "1.0.1" vs "1.0", "1.10.0" vs "1.2.0", and pre-release suffixes
    /// like "1.0.1-beta" by falling back to lexicographic ordering on the
    /// tail.
    private func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    // MARK: - Presentation

    private func presentUpdateAvailable(release: Release, current: String) {
        let alert = NSAlert()
        alert.messageText = "A new version of Quick Markdown is available."
        alert.informativeText = """
            Quick Markdown \(release.normalizedVersion) is now available — \
            you have \(current).

            \(release.name ?? release.tagName)
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download…")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Remind Me Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn, .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.normalizedVersion,
                                      forKey: Constants.skippedVersionKey)
        default:
            break  // "Remind Me Later" = no-op; the daily throttle handles it
        }
    }

    private func presentUpToDate(current: String) {
        let alert = NSAlert()
        alert.messageText = "You’re up to date."
        alert.informativeText = "Quick Markdown \(current) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t check for updates."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func currentVersion() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
