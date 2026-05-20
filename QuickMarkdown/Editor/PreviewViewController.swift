import AppKit
import WebKit

/// Read-only WKWebView that displays a fully-rendered Markdown preview.
/// Uses `HTMLRenderer` to produce HTML, which gives us proper CSS table
/// layout, responsive column sizing, and full GFM styling — matching
/// GitHub's rendering.
@MainActor
final class PreviewViewController: NSViewController {

    private var webView: WKWebView!

    /// Spinner shown while the WKWebView loads content.
    private var spinner: NSProgressIndicator!

    /// Last source we rendered. Cached so theme changes can re-render.
    private var lastRenderedSource: String = ""

    /// Folder URL of the document being previewed, used by the renderer to
    /// resolve relative image paths.
    private var lastRenderedBaseURL: URL?

    /// True when the rendered content does not match the source the user is
    /// editing.
    var isStale: Bool = true

    private nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    // MARK: - Scroll preservation

    /// Saved scroll fraction (0–1) to restore after re-render.
    private var savedScrollFraction: Double = 0

    // MARK: - Speech support

    /// Plain text extracted from the rendered HTML. Populated after each
    /// render via JavaScript.
    private var cachedPlainText: String = ""

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true

        // Message handler for scroll-position save and plain-text extraction.
        let handler = WebMessageHandler(owner: self)
        config.userContentController.add(handler, name: "quickMarkdown")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = handler

        // Transparent background so the theme background shows through.
        webView.setValue(false, forKey: "drawsBackground")

        root.addSubview(webView)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isDisplayedWhenStopped = false
        root.addSubview(spinner)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
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

    // MARK: - Render

    func render(source: String, baseURL: URL? = nil) {
        lastRenderedSource = source
        lastRenderedBaseURL = baseURL

        spinner.startAnimation(nil)

        // Save current scroll position before replacing content.
        webView.evaluateJavaScript(
            "window.pageYOffset / Math.max(1, document.body.scrollHeight - window.innerHeight)"
        ) { [weak self] result, _ in
            if let frac = result as? Double, frac.isFinite {
                self?.savedScrollFraction = frac
            }
        }

        let html = Self.renderHTML(source: source, baseURL: baseURL)
        webView.loadHTMLString(html, baseURL: baseURL)
        isStale = false
    }

    /// Build a complete HTML page with theme-aware CSS.
    private static func renderHTML(source: String, baseURL: URL?) -> String {
        let theme = ReadingPreferences.shared.theme
        let font = ReadingPreferences.shared.fontFamily

        let cleaned = MarkdownAttributedRenderer.rewriteDocsImageDirectives(
            in: MarkdownAttributedRenderer.stripFrontMatter(source)
        )
        let body = HTMLRenderer.renderBody(cleaned, baseURL: baseURL)

        let bg = theme.background.cssHex
        let fg = theme.foreground.cssHex
        let secondaryFg = theme.secondaryForeground.cssHex
        let codeBg = theme.codeBackground.cssHex
        let codeFg = theme.codeForeground.cssHex
        let linkClr = theme.linkColor.cssHex
        let borderClr = theme.tableBorder.cssHex
        let headerBg = theme.tableHeaderBackground.cssHex
        let stripeBg = theme.tableStripe.cssHex
        let bqAccent = NSColor.controlAccentColor.cssHex

        let bodyFont: String
        switch font {
        case .system:  bodyFont = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif"
        case .serif:   bodyFont = "'New York', 'Iowan Old Style', Georgia, serif"
        case .rounded: bodyFont = "-apple-system-ui-serif, 'SF Pro Rounded', -apple-system, sans-serif"
        case .dyslexic: bodyFont = "'OpenDyslexic', -apple-system, sans-serif"
        }

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <style>
        * { box-sizing: border-box; }
        body {
            font-family: \(bodyFont);
            font-size: 16px; line-height: 1.6;
            color: \(fg); background: \(bg);
            padding: 24px;
            -webkit-text-size-adjust: none;
        }
        a { color: \(linkClr); }
        h1 { font-size: 32px; font-weight: 700; margin: 24px 0 8px; line-height: 1.3; padding-bottom: 6px; border-bottom: 1px solid \(borderClr); }
        h2 { font-size: 24px; font-weight: 600; margin: 24px 0 8px; line-height: 1.3; padding-bottom: 6px; border-bottom: 1px solid \(borderClr); }
        h3 { font-size: 20px; font-weight: 600; margin: 20px 0 8px; }
        h4 { font-size: 18px; font-weight: 600; margin: 16px 0 8px; }
        h5 { font-size: 16px; font-weight: 600; margin: 16px 0 8px; }
        h6 { font-size: 15px; font-weight: 600; margin: 16px 0 8px; color: \(secondaryFg); }
        p { margin: 0 0 12px; }
        blockquote {
            border-left: 3px solid \(bqAccent);
            margin: 0 0 16px; padding: 0 0 0 16px;
            color: \(secondaryFg); font-style: italic;
        }
        code {
            font-family: 'SF Mono', Menlo, Monaco, Consolas, monospace;
            font-size: 14px; background: \(codeBg); color: \(codeFg);
            border-radius: 4px; padding: 2px 4px;
        }
        pre {
            font-family: 'SF Mono', Menlo, Monaco, Consolas, monospace;
            font-size: 14px; background: \(codeBg); color: \(codeFg);
            border: 1px solid \(borderClr); border-radius: 4px;
            padding: 8px; overflow: auto; line-height: 1.45;
        }
        pre code { background: none; padding: 0; border-radius: 0; }
        ul, ol { margin: 0 0 12px; padding-left: 24px; }
        li { margin: 0 0 4px; }
        hr { border: none; border-top: 1px solid \(borderClr); margin: 24px 0; }
        img { max-width: 100%; height: auto; display: block; margin: 8px 0; }
        table {
            border-collapse: collapse; margin: 0 0 16px;
            width: 100%;
        }
        th {
            border: 1px solid \(borderClr);
            padding: 8px 13px;
            background: \(headerBg);
            text-align: left; font-weight: 600;
        }
        td {
            border: 1px solid \(borderClr);
            padding: 8px 13px;
            text-align: left;
        }
        tr:nth-child(even) td { background: \(stripeBg); }
        .qm-highlight {
            background: rgba(255, 230, 0, 0.45);
            border-radius: 2px;
        }
        </style>
        </head><body>\(body)
        <script>
        // After load, send plain text to Swift for speech and restore scroll.
        window.addEventListener('load', function() {
            window.webkit.messageHandlers.quickMarkdown.postMessage({
                type: 'plainText',
                text: document.body.innerText
            });
        });
        // Speech highlighting: wrap character range in a span.
        var currentHighlight = null;
        function highlightRange(start, length) {
            clearHighlight();
            if (start < 0 || length <= 0) return;
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            var pos = 0;
            while (walker.nextNode()) {
                var node = walker.currentNode;
                var nodeLen = node.textContent.length;
                if (pos + nodeLen > start) {
                    var offset = start - pos;
                    var end = Math.min(offset + length, nodeLen);
                    var range = document.createRange();
                    range.setStart(node, offset);
                    range.setEnd(node, end);
                    var span = document.createElement('span');
                    span.className = 'qm-highlight';
                    range.surroundContents(span);
                    currentHighlight = span;
                    span.scrollIntoView({ block: 'center', behavior: 'smooth' });
                    return;
                }
                pos += nodeLen;
            }
        }
        function clearHighlight() {
            if (currentHighlight) {
                var parent = currentHighlight.parentNode;
                while (currentHighlight.firstChild)
                    parent.insertBefore(currentHighlight.firstChild, currentHighlight);
                parent.removeChild(currentHighlight);
                currentHighlight = null;
            }
        }
        </script>
        </body></html>
        """
    }

    private func applyTheme() {
        let theme = ReadingPreferences.shared.theme
        // WKWebView background is transparent; set the superview bg.
        view.layer?.backgroundColor = theme.background.cgColor
        if !lastRenderedSource.isEmpty {
            render(source: lastRenderedSource, baseURL: lastRenderedBaseURL)
        }
    }

    /// Restore scroll position after page loads.
    fileprivate func restoreScroll() {
        spinner.stopAnimation(nil)
        let frac = savedScrollFraction
        webView.evaluateJavaScript("""
            var maxY = document.body.scrollHeight - window.innerHeight;
            window.scrollTo(0, maxY * \(frac));
        """)
    }

    fileprivate func didReceivePlainText(_ text: String) {
        cachedPlainText = text
    }
}

// MARK: - WKScriptMessageHandler + WKNavigationDelegate

/// Separate class to avoid making PreviewViewController conform to
/// NSObjectProtocol from WKScriptMessageHandler (which requires NSObject).
private final class WebMessageHandler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private weak var owner: PreviewViewController?

    init(owner: PreviewViewController) {
        self.owner = owner
    }

    @MainActor
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }
        if type == "plainText", let text = dict["text"] as? String {
            owner?.didReceivePlainText(text)
        }
    }

    @MainActor
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.restoreScroll()
    }

    // Block external navigation — only allow local content.
    @MainActor
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - Speech (read-aloud)

extension PreviewViewController {

    /// Plain-text contents of the rendered preview.
    var plainText: String {
        cachedPlainText
    }

    /// Current selection is not supported in WKWebView speech — return nil.
    var selectedTextRange: NSRange? {
        nil
    }

    func speechPayload() -> (text: String, offsetIntoPreview: Int) {
        (plainText, 0)
    }

    /// Highlight the currently-spoken word via JavaScript.
    func highlightSpokenRange(_ range: NSRange, offsetIntoPreview: Int = 0) {
        if range.location == NSNotFound || range.length == 0 {
            webView.evaluateJavaScript("clearHighlight()")
            return
        }
        let start = range.location + offsetIntoPreview
        webView.evaluateJavaScript("highlightRange(\(start), \(range.length))")
    }
}
