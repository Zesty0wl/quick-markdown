import AppKit
import WebKit
import XCTest
@testable import QuickMarkdown

/// Opt-in: renders sample documents through the real Preview page in an
/// off-screen web view and saves PNGs, for checking layout by eye without
/// opening the app. Run with
///
///     xcodebuild … test -only-testing:QuickMarkdownTests/PreviewSnapshotTests \
///       TEST_RUNNER_QM_SNAPSHOTS=1
///
/// The PNGs land in the test host's temporary directory (printed).
@MainActor
final class PreviewSnapshotTests: XCTestCase {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    func testSnapshotSampleDocuments() async throws {
        guard ProcessInfo.processInfo.environment["QM_SNAPSHOTS"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_QM_SNAPSHOTS=1 to write Preview snapshots")
        }
        for name in ["04-extensions", "03-mermaid"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "md"))
            let source = try String(contentsOf: url, encoding: .utf8)
            let html = PreviewViewController.renderHTML(source: source, baseURL: nil)

            let frame = NSRect(x: 0, y: 0, width: 900, height: 800)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
            webView.appearance = NSAppearance(
                named: ReadingPreferences.shared.theme.prefersDark ? .darkAqua : .aqua)
            window.contentView = webView
            let waiter = LoadWaiter()
            webView.navigationDelegate = waiter
            await withCheckedContinuation { continuation in
                waiter.continuation = continuation
                webView.loadHTMLString(html, baseURL: nil)
            }
            try await MermaidRenderer.render(in: webView,
                                             prefersDark: ReadingPreferences.shared.theme.prefersDark)
            // Grow to the full page height, then snapshot.
            let height = try await webView.evaluateJavaScript(
                "document.documentElement.scrollHeight") as? Double ?? 800
            window.setContentSize(NSSize(width: 900, height: min(height, 6000)))
            webView.frame = NSRect(x: 0, y: 0, width: 900, height: min(height, 6000))
            try await Task.sleep(nanoseconds: 300_000_000)
            let image = try await webView.takeSnapshot(configuration: nil)
            let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try png.write(to: out)
            print("SNAPSHOT \(out.path)")
        }
    }
}
