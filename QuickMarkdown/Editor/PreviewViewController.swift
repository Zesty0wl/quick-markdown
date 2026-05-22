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
    fileprivate var lastRenderedBaseURL: URL?

    /// True when the rendered content does not match the source the user is
    /// editing.
    var isStale: Bool = true

    /// Called when the user clicks a task-list checkbox in the preview.
    /// The Int is the 0-based index of the task item in document order.
    /// The handler is expected to flip the corresponding `[ ]` / `[x]`
    /// marker in the source.
    var onTaskToggle: ((Int) -> Void)?

    private nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    // MARK: - Scroll preservation

    /// Saved scroll fraction (0–1) to restore after re-render.
    private var savedScrollFraction: Double = 0

    // MARK: - Speech support

    /// Plain text extracted from the rendered HTML. Populated after each
    /// render via JavaScript.
    private var cachedPlainText: String = ""

    /// Strong reference to the WebKit message/navigation/UI handler.
    /// `WKWebView.navigationDelegate` and `uiDelegate` are weak; the user
    /// content controller retains the script-message handler, so in practice
    /// this would survive — but holding it here too removes any doubt and
    /// keeps the wiring obvious.
    private var webHandler: WebMessageHandler?

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true

        // Message handler for scroll-position save and plain-text extraction.
        let handler = WebMessageHandler(owner: self)
        webHandler = handler
        config.userContentController.add(handler, name: "quickMarkdown")

        webView = PreviewWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = handler
        webView.uiDelegate = handler

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

    /// Re-render the preview from `source`.
    ///
    /// - Parameter scrollFraction: If provided, the preview will land at this
    ///   normalised (0...1) scroll position after the new HTML loads. Used by
    ///   `DocumentWindowController` to map the editor's scroll position into
    ///   the preview when switching from Source to Preview. When `nil`, the
    ///   preview captures its own current scroll fraction and restores it
    ///   after the re-render (the existing "preserve scroll across re-render"
    ///   behaviour).
    func render(source: String, baseURL: URL? = nil, scrollFraction: Double? = nil) {
        lastRenderedSource = source
        lastRenderedBaseURL = baseURL

        spinner.startAnimation(nil)

        if let scrollFraction {
            savedScrollFraction = scrollFraction
        } else {
            // Save current scroll position before replacing content.
            webView.evaluateJavaScript(
                "window.pageYOffset / Math.max(1, document.body.scrollHeight - window.innerHeight)"
            ) { [weak self] result, _ in
                if let frac = result as? Double, frac.isFinite {
                    self?.savedScrollFraction = frac
                }
            }
        }

        let html = Self.renderHTML(source: source, baseURL: baseURL)
        webView.loadHTMLString(html, baseURL: baseURL)
        isStale = false
    }

    /// Read the preview's current scroll position as a fraction in `0...1`.
    /// Asynchronous because it has to bounce through WebKit.
    func currentScrollFraction(completion: @escaping @MainActor (Double) -> Void) {
        webView.evaluateJavaScript(
            "window.pageYOffset / Math.max(1, document.body.scrollHeight - window.innerHeight)"
        ) { result, _ in
            let frac: Double
            if let n = result as? Double, n.isFinite {
                frac = max(0, min(1, n))
            } else {
                frac = 0
            }
            MainActor.assumeIsolated { completion(frac) }
        }
    }

    /// Scroll the already-rendered preview to `fraction` of its scrollable
    /// range. Used by the mode switch when the preview is up-to-date and
    /// doesn't need re-rendering.
    func applyScrollFraction(_ fraction: Double) {
        savedScrollFraction = fraction
        let clamped = max(0, min(1, fraction))
        webView.evaluateJavaScript("""
            var maxY = document.body.scrollHeight - window.innerHeight;
            window.scrollTo(0, maxY * \(clamped));
        """)
    }

    /// Build a complete HTML page with theme-aware CSS.
    private static func renderHTML(source: String, baseURL: URL?) -> String {
        let theme = ReadingPreferences.shared.theme
        let font = ReadingPreferences.shared.fontFamily

        let cleaned = MarkdownAttributedRenderer.rewriteFootnotes(
            in: MarkdownAttributedRenderer.rewriteDocsImageDirectives(
                in: MarkdownAttributedRenderer.stripFrontMatter(source)
            ),
            style: .html
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
            /* Wrap long lines inside the code-block box instead of forcing
               a horizontal scrollbar. Covers two cases:
                 1. CommonMark "indented code block" interpretation of
                    over-indented list-item continuation paragraphs (6+
                    spaces under a `- ` marker — common source-authoring
                    mistake where the author aligned continuation under the
                    bold title text). Without wrap the prose just runs off
                    the right edge.
                 2. Genuine code blocks with very long lines (shell
                    pipelines, long URLs). The scrollbar above is still
                    available as a fallback for truly unbreakable runs.
               Scoped to the live preview only — the export pipeline
               (HTMLRenderer's inline CSS) keeps strict <pre> semantics so
               code pasted into Word / Outlook / PDF stays unmodified. */
            white-space: pre-wrap;
            overflow-wrap: break-word;
        }
        pre code { background: none; padding: 0; border-radius: 0; }
        ul, ol { margin: 0 0 12px; padding-left: 24px; }
        li { margin: 0 0 4px; }
        /* GFM task list items: hide the bullet (the inline `list-style:none`
           on the <li> is stripped by renderBody's style-attribute regex, so
           we rely on this class instead) and keep the checkbox + label on a
           single baseline. */
        li.task-list-item { list-style: none; }
        li.task-list-item > input[type="checkbox"] {
            margin-right: 6px;
            vertical-align: middle;
        }
        hr { border: none; border-top: 1px solid \(borderClr); margin: 24px 0; }
        /* `inline-block` (not `block`) so consecutive images in a paragraph —
           most obviously a row of README shields.io badges — flow inline the
           way GitHub renders them. Standalone images still sit on their own
           line because their surrounding `<p>` is block. `vertical-align:
           middle` removes the inline-baseline gap. */
        img { max-width: 100%; height: auto; display: inline-block; vertical-align: middle; }
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
        /* Always-visible scrollbar so the user can see scroll position
           without having to scroll first. Matches the Source view, which
           uses NSScrollView with legacy (always-visible) scrollers. */
        html { overflow-y: scroll; }
        ::-webkit-scrollbar { width: 14px; height: 14px; }
        ::-webkit-scrollbar-track {
            background: \(bg);
        }
        ::-webkit-scrollbar-thumb {
            background: \(secondaryFg);
            border-radius: 7px;
            border: 3px solid \(bg);
            background-clip: content-box;
            min-height: 30px;
        }
        ::-webkit-scrollbar-thumb:hover {
            background: \(fg);
            border: 3px solid \(bg);
            background-clip: content-box;
        }
        ::-webkit-scrollbar-corner { background: \(bg); }
        </style>
        </head><body>\(body)
        <script>
        // After load, send plain text to Swift for speech and restore scroll.
        window.addEventListener('load', function() {
            window.webkit.messageHandlers.quickMarkdown.postMessage({
                type: 'plainText',
                text: document.body.innerText
            });
            // Enable interactive task-list checkboxes. The HTML renderer
            // emits `<input type="checkbox" disabled data-task-index="N">`
            // (the `disabled` keeps it inert for export consumers like Word
            // and PDF); we strip `disabled` and route click events back to
            // Swift, which flips the Nth `[ ]` / `[x]` marker in the source.
            document.querySelectorAll('input[data-task-index]').forEach(function(el) {
                el.removeAttribute('disabled');
                el.addEventListener('click', function() {
                    var idx = parseInt(el.getAttribute('data-task-index'), 10);
                    if (!isFinite(idx)) return;
                    window.webkit.messageHandlers.quickMarkdown.postMessage({
                        type: 'toggleTask',
                        index: idx
                    });
                });
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

    fileprivate func didToggleTask(at index: Int) {
        onTaskToggle?(index)
    }
}

// MARK: - WKScriptMessageHandler + WKNavigationDelegate

/// Separate class to avoid making PreviewViewController conform to
/// NSObjectProtocol from WKScriptMessageHandler (which requires NSObject).
private final class WebMessageHandler: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
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
        } else if type == "toggleTask", let index = dict["index"] as? Int {
            owner?.didToggleTask(at: index)
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
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // We route by URL scheme rather than `navigationType == .linkActivated`
        // because WKWebView frequently classifies clicks in HTML loaded via
        // `loadHTMLString(_:baseURL:)` as `.other` instead of `.linkActivated`
        // — so a stricter check silently lets the navigation through, the
        // file:// base URL can't resolve http(s), and the click appears to
        // do nothing (or worse, WKWebView happily renders the remote page
        // inside the preview itself).
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        // External-looking schemes always go to the system browser/mail
        // client. Checked first so `target="_blank"` links (which arrive
        // with `targetFrame == nil`) are handled correctly.
        if scheme == "http" || scheme == "https" || scheme == "mailto"
            || scheme == "tel" || scheme == "sms" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        // In-page fragment navigation (footnote refs, TOC anchors): let
        // WKWebView scroll within the preview instead of opening the file:
        // URL in Finder.
        if scheme == "file",
           let frag = url.fragment, !frag.isEmpty,
           let cur = owner?.lastRenderedBaseURL,
           url.scheme == cur.scheme,
           url.host == cur.host,
           url.path == cur.path {
            decisionHandler(.allow)
            return
        }

        // Any other file:// link (relative .md sibling, image, etc.) and
        // any unrecognised scheme go to the system. We still allow the
        // initial main-frame load of our rendered page (baseURL itself)
        // and any sub-resource loads.
        if scheme == "file" {
            if navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
                return
            }
            if let cur = owner?.lastRenderedBaseURL,
               url.absoluteURL == cur.absoluteURL {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        if url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.allow)
    }

    // Handle `target="_blank"` and `window.open(...)` style requests:
    // WKWebView calls this on the UI delegate *instead of* asking the
    // navigation delegate's decidePolicy. Returning nil cancels the
    // in-webview open; we redirect to the system browser.
    @MainActor
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
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

// MARK: - Markdown file drop support

/// `WKWebView` subclass that intercepts drops of `.md` / `.markdown` files
/// and routes them through `NSDocumentController.openDocument` rather than
/// letting the web view navigate away to the dropped file URL. Drops that
/// don't carry a markdown file fall through to WKWebView's default
/// handling.
private final class PreviewWebView: WKWebView {

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if QuickMarkdownDocumentController.markdownURLs(in: sender) != nil {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if QuickMarkdownDocumentController.markdownURLs(in: sender) != nil {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let urls = QuickMarkdownDocumentController.markdownURLs(in: sender) {
            QuickMarkdownDocumentController.openMarkdownURLs(urls)
            return true
        }
        return super.performDragOperation(sender)
    }
}
