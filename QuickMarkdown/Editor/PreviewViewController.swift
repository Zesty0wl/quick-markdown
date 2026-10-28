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

    /// Bumped on every render so a slow Mermaid pass from an earlier page
    /// doesn't restore scroll over a newer one.
    private var renderGeneration = 0

    /// Shell signature of the page currently in the web view, once it has
    /// finished loading. `nil` while a full load is in flight.
    private var loadedShellSignature: String?
    private var pendingShellSignature: String?

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
        renderGeneration += 1
        loadedShellSignature = nil
        pendingShellSignature = Self.shellSignature
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

    /// Shows new content for the same document without reloading the page,
    /// so nothing flashes and the reader keeps their place: the block at
    /// the top of the window stays put when text changes above or below
    /// it, and a reader at the bottom follows text added there. Used when
    /// the file changes on disk (for example while an agent edits it).
    /// Falls back to a full `render` if the page isn't loaded yet or its
    /// theme, font or folder has changed.
    func update(source: String, baseURL: URL? = nil) {
        guard loadedShellSignature == Self.shellSignature,
              baseURL == lastRenderedBaseURL else {
            render(source: source, baseURL: baseURL)
            return
        }
        renderGeneration += 1
        let generation = renderGeneration
        lastRenderedSource = source
        isStale = false
        let body = Self.renderBody(source: source, baseURL: baseURL)
        let prefersDark = ReadingPreferences.shared.theme.prefersDark
        let css = HTMLRenderer.richContentCSS(for: body, prefersDark: prefersDark)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.webView.callAsyncJavaScript(
                    "qmStageContent(html);", arguments: ["html": body],
                    in: nil, contentWorld: .page)
                do {
                    try await MermaidRenderer.render(in: self.webView, prefersDark: prefersDark)
                } catch {
                    NSLog("[QuickMarkdown] Mermaid rendering failed: %@", error.localizedDescription)
                }
                // A newer update or a full render has taken over.
                guard self.renderGeneration == generation else { return }
                _ = try await self.webView.callAsyncJavaScript(
                    "return qmCommitContent(css);", arguments: ["css": css],
                    in: nil, contentWorld: .page)
            } catch {
                NSLog("[QuickMarkdown] In-place preview update failed: %@", error.localizedDescription)
                guard self.renderGeneration == generation else { return }
                self.render(source: source, baseURL: baseURL)
            }
        }
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

    /// The page's content: everything that changes when the document does.
    /// Internal so the spec conformance tests render exactly what the
    /// Preview shows.
    static func renderBody(source: String, baseURL: URL?) -> String {
        let cleaned = MarkdownAttributedRenderer.rewriteFootnotes(
            in: MarkdownAttributedRenderer.rewriteDocsImageDirectives(
                in: MarkdownAttributedRenderer.stripFrontMatter(source)
            ),
            style: .html
        )
        return HTMLRenderer.renderBody(cleaned, baseURL: baseURL)
    }

    /// Identifies the page shell (theme and font). An in-place update is
    /// only possible while this matches the loaded page.
    private static var shellSignature: String {
        "\(ReadingPreferences.shared.theme)|\(ReadingPreferences.shared.fontFamily)"
    }

    /// Build a complete HTML page with theme-aware CSS.
    private static func renderHTML(source: String, baseURL: URL?) -> String {
        let theme = ReadingPreferences.shared.theme
        let font = ReadingPreferences.shared.fontFamily
        let body = renderBody(source: source, baseURL: baseURL)
        // Only the page's own script (carrying this nonce) may run: scripts
        // and event-handler attributes in a document's raw HTML don't.
        // Scripts the app injects with evaluateJavaScript (Mermaid, in-place
        // updates) aren't subject to the policy.
        let scriptNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")

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
        let richContentCSS = HTMLRenderer.richContentCSS(for: body,
                                                         prefersDark: theme.prefersDark)
        let alertColorCSS = HTMLRenderer.AlertKind.allCases.map { kind in
            ".qm-alert-\(kind.rawValue) { --qm-alert: \(theme.prefersDark ? kind.darkColor : kind.color); }"
        }.joined(separator: "\n")

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
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(scriptNonce)'; style-src 'unsafe-inline'; img-src data: file: http: https:; media-src data: file: http: https:; font-src data: file:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style id="qm-rich-css">\(richContentCSS)</style>
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
        /* GitHub-style alerts (`> [!NOTE]` and friends). */
        .qm-alert {
            border-left: 4px solid var(--qm-alert);
            margin: 0 0 16px; padding: 0 0 0 16px;
        }
        .qm-alert > :last-child { margin-bottom: 0; }
        .qm-alert-title {
            display: flex; align-items: center; gap: 8px;
            color: var(--qm-alert); font-weight: 600; margin: 0 0 8px;
        }
        .qm-alert-icon { flex: none; }
        \(alertColorCSS)
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
        li.task-list-item > input[type="checkbox"],
        li.task-list-item > p > input[type="checkbox"] {
            margin: 0 4px 0 -20px;
            vertical-align: middle;
        }
        /* Nested lists in tight items sit close, as on GitHub. */
        li > ul, li > ol { margin-bottom: 0; }
        /* Footnotes section, as on GitHub. */
        .footnotes {
            border-top: 1px solid \(borderClr);
            margin-top: 32px; padding-top: 12px;
            font-size: 14px; color: \(secondaryFg);
        }
        .footnote-backref, sup.footnote-ref a { text-decoration: none; }
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
        /* Column alignment from the `:---:` row (more specific than th/td). */
        th[align="left"], td[align="left"] { text-align: left; }
        th[align="center"], td[align="center"] { text-align: center; }
        th[align="right"], td[align="right"] { text-align: right; }
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
        </head><body><div id="qm-content">\(body)</div>
        <script nonce="\(scriptNonce)">
        // Copy from the preview: hand Swift the selection as clean semantic
        // HTML instead of letting WebKit serialise it. WebKit's default copy
        // bakes every element's computed style into the markup — including
        // the theme's `color` and `background` from `body` — so each pasted
        // paragraph lands in Mail / Outlook / Word with a hard-coded text
        // colour and an opaque background. Invisible in a light compose
        // window; in dark mode every paragraph shows as a grey box, for the
        // sender and for recipients alike. Writing via `clipboardData` from
        // JS is no better: WebKit sanitises script-written HTML through the
        // same serialiser and re-adds `color`. So we strip preview-only
        // attributes here and let FormattedPasteboardWriter put the result
        // on the pasteboard with no colours at all.
        document.addEventListener('copy', function(e) {
            var sel = window.getSelection();
            if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return;
            var content = document.createElement('div');
            for (var i = 0; i < sel.rangeCount; i++) {
                content.appendChild(sel.getRangeAt(i).cloneContents());
            }
            // Equations paste as their TeX source (`$…$`, `$$…$$`). KaTeX's
            // markup falls apart once its classes and inline styles go.
            [['.katex-display', '$$'], ['.katex', '$']].forEach(function(kind) {
                content.querySelectorAll(kind[0]).forEach(function(el) {
                    var tex = el.querySelector('annotation[encoding="application/x-tex"]');
                    if (!tex) return;
                    el.replaceWith(document.createTextNode(
                        kind[1] + tex.textContent + kind[1]));
                });
            });
            // Theme classes, heading anchor ids, task-list indices, inline
            // style: none of it belongs in the pasted document.
            content.querySelectorAll('*').forEach(function(el) {
                ['style', 'class', 'id', 'data-task-index'].forEach(function(a) {
                    el.removeAttribute(a);
                });
            });
            e.preventDefault();
            window.webkit.messageHandlers.quickMarkdown.postMessage({
                type: 'copySelection',
                html: content.innerHTML,
                text: sel.toString()
            });
        });
        // After load (and after each in-place update), send plain text to
        // Swift for speech and wire up the task-list checkboxes.
        function qmEnhance() {
            window.webkit.messageHandlers.quickMarkdown.postMessage({
                type: 'plainText',
                text: document.getElementById('qm-content').innerText
            });
            // Enable interactive task-list checkboxes. The HTML renderer
            // emits `<input type="checkbox" disabled data-task-index="N">`
            // (the `disabled` keeps it inert for export consumers like Word
            // and PDF); we strip `disabled` and route click events back to
            // Swift, which flips the Nth `[ ]` / `[x]` marker in the source.
            document.querySelectorAll('#qm-content input[data-task-index]').forEach(function(el) {
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
        }
        window.addEventListener('load', qmEnhance);
        // In-place updates (the file changed on disk, e.g. an agent is
        // editing it). New content is staged hidden so Mermaid can draw its
        // diagrams first, then swapped in with the reader's place kept.
        function qmStageContent(html) {
            var old = document.getElementById('qm-staging');
            if (old) old.remove();
            var staging = document.createElement('div');
            staging.id = 'qm-staging';
            staging.setAttribute('aria-hidden', 'true');
            staging.style.cssText = 'visibility:hidden;height:0;overflow:hidden;';
            staging.innerHTML = html;
            document.getElementById('qm-content').after(staging);
        }
        function qmCommitContent(css) {
            var staging = document.getElementById('qm-staging');
            if (!staging) return false;
            var anchor = qmCaptureAnchor();
            currentHighlight = null;
            document.getElementById('qm-rich-css').textContent = css;
            document.getElementById('qm-content').replaceChildren(...staging.childNodes);
            staging.remove();
            qmRestoreAnchor(anchor);
            qmEnhance();
            return true;
        }
        // Where the reader is: pinned to the bottom (following new text),
        // or the first visible top-level block and how far down the window
        // it sits, so text added or removed above doesn't move the view.
        function qmCaptureAnchor() {
            var maxY = document.documentElement.scrollHeight - window.innerHeight;
            if (window.scrollY > 0 && window.scrollY >= maxY - 40) return { bottom: true };
            var blocks = document.getElementById('qm-content').children;
            for (var i = 0; i < blocks.length; i++) {
                var rect = blocks[i].getBoundingClientRect();
                if (rect.bottom > 0) {
                    return { index: i, count: blocks.length,
                             key: qmBlockKey(blocks[i]), offset: rect.top };
                }
            }
            return null;
        }
        function qmBlockKey(el) {
            return el.tagName + '|' + (el.textContent || '').trim().slice(0, 120);
        }
        function qmRestoreAnchor(anchor) {
            if (!anchor) return;
            if (anchor.bottom) {
                window.scrollTo(0, document.documentElement.scrollHeight);
                return;
            }
            // The same block, nearest its old position (allowing for blocks
            // added or removed above it). If it's gone, the scroll offset
            // stays as it was.
            var blocks = document.getElementById('qm-content').children;
            var shifted = anchor.index + blocks.length - anchor.count;
            var best = -1, bestDistance = Infinity;
            for (var i = 0; i < blocks.length; i++) {
                if (qmBlockKey(blocks[i]) !== anchor.key) continue;
                var distance = Math.min(Math.abs(i - anchor.index), Math.abs(i - shifted));
                if (distance < bestDistance) { best = i; bestDistance = distance; }
            }
            if (best < 0) return;
            window.scrollBy(0, blocks[best].getBoundingClientRect().top - anchor.offset);
        }
        // Speech highlighting: wrap character range in a span.
        var currentHighlight = null;
        function highlightRange(start, length) {
            clearHighlight();
            if (start < 0 || length <= 0) return;
            var walker = document.createTreeWalker(document.getElementById('qm-content'), NodeFilter.SHOW_TEXT);
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

    /// Called when the page has loaded: draws any Mermaid diagrams, which
    /// changes the page height, then restores the scroll position.
    fileprivate func finishRendering() {
        let generation = renderGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await MermaidRenderer.render(
                    in: self.webView,
                    prefersDark: ReadingPreferences.shared.theme.prefersDark
                )
            } catch {
                NSLog("[QuickMarkdown] Mermaid rendering failed: %@", error.localizedDescription)
            }
            guard self.renderGeneration == generation else { return }
            self.loadedShellSignature = self.pendingShellSignature
            self.restoreScroll()
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

    /// The preview's `copy` handler sends the selection here (see the
    /// `<script>` in `renderHTML`). Writes it to the general pasteboard as
    /// colour-free HTML plus plain text.
    fileprivate func didCopySelection(html: String, text: String) {
        FormattedPasteboardWriter.writeHTMLFragment(html, plainText: text)
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
        } else if type == "copySelection",
                  let html = dict["html"] as? String,
                  let text = dict["text"] as? String {
            owner?.didCopySelection(html: html, text: text)
        }
    }

    @MainActor
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.finishRendering()
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
            openLocalLink(url)
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
            if url.isFileURL {
                openLocalLink(url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    /// Open a local `file://` link clicked in the preview. If the resolved
    /// path doesn't exist on disk — typically because the document author
    /// wrote a relative path that doesn't line up with the document's
    /// actual location — fall back to revealing the nearest existing
    /// ancestor in Finder and beep, so the user gets feedback instead of
    /// the click silently doing nothing.
    @MainActor
    private func openLocalLink(_ url: URL) {
        // Drop any fragment before existence checks / opening — file URLs
        // with `#frag` are not valid filesystem paths.
        var target = url
        if url.fragment != nil {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.fragment = nil
            if let stripped = comps?.url { target = stripped }
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            if NSWorkspace.shared.open(target) { return }
        }

        // Target missing or LaunchServices refused to open it. Walk up the
        // path until we find a directory that does exist and reveal it in
        // Finder so the user can see where the link pointed.
        NSSound.beep()
        var probe = target.deletingLastPathComponent()
        while probe.path != "/" && !fm.fileExists(atPath: probe.path) {
            probe = probe.deletingLastPathComponent()
        }
        if fm.fileExists(atPath: probe.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
        NSLog("[QuickMarkdown] Preview link target not found: %@", target.path)
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
