import WebKit

/// Turns ` ```mermaid ` code blocks in a loaded page into SVG diagrams,
/// using the bundled, offline Mermaid build (`mermaid/mermaid.js`, which
/// exposes `QuickMarkdownMermaid.renderAll`). A diagram that fails to parse
/// keeps its source block, with a short message above it.
@MainActor
enum MermaidRenderer {
    static func render(in webView: WKWebView, prefersDark: Bool = false) async throws {
        let hasDiagrams = try await webView.evaluateJavaScript(
            "Boolean(document.querySelector('pre > code.language-mermaid'))"
        ) as? Bool ?? false
        // Only load the 3 MB script into pages that need it.
        guard hasDiagrams else { return }
        guard !WebAssets.mermaidScript.isEmpty else {
            throw NSError(domain: "QuickMarkdown.Mermaid", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The Mermaid renderer is unavailable."])
        }
        // Load once per page. Later calls (after the Preview updates in
        // place) reuse it; `renderAll` only picks up blocks not yet drawn.
        let isLoaded = try await webView.evaluateJavaScript(
            "typeof window.QuickMarkdownMermaid !== 'undefined'"
        ) as? Bool ?? false
        if !isLoaded {
            _ = try await webView.evaluateJavaScript(WebAssets.mermaidScript)
        }
        _ = try await webView.callAsyncJavaScript(
            "return await QuickMarkdownMermaid.renderAll({ dark: dark });",
            arguments: ["dark": prefersDark],
            in: nil,
            contentWorld: .page
        )
    }
}
