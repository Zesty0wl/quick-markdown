import Foundation

/// Bundled, offline copies of Highlight.js, KaTeX and Mermaid, plus GitHub's
/// emoji shortcodes. Nothing is fetched
/// from a CDN. Xcode flattens the `WebAssets` folder into the bundle's
/// Resources directory, so files are looked up by name alone.
enum WebAssets {
    static let highlightScript = load("highlight/highlight.min.js")
    static let highlightLightCSS = load("highlight/github.min.css")
    static let highlightDarkCSS = load("highlight/github-dark.min.css")
    static let katexScript = load("katex/katex.min.js")
    static let mermaidScript = load("mermaid/mermaid.js")
    static let mermaidCSS = load("mermaid/mermaid.css")

    /// KaTeX's stylesheet with its `woff2` fonts inlined as `data:` URLs,
    /// so equations render the same in the Preview (loaded with the
    /// document's folder as base URL) and in PDF export.
    static let katexCSS: String = {
        var css = load("katex/katex.min.css")
        let pattern = #"url\(fonts/([^)]+\.woff2)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return css
        }
        let source = css as NSString
        for match in regex.matches(
            in: css,
            range: NSRange(location: 0, length: source.length)
        ).reversed() {
            let filename = source.substring(with: match.range(at: 1))
            guard let data = data("katex/fonts/\(filename)") else { continue }
            let replacement = "url(data:font/woff2;base64,\(data.base64EncodedString()))"
            css = (css as NSString).replacingCharacters(in: match.range,
                                                         with: replacement)
        }
        return css
    }()

    static func highlightCSS(prefersDark: Bool) -> String {
        prefersDark ? highlightDarkCSS : highlightLightCSS
    }

    /// A bundled data file, such as `emoji-shortcodes.json`.
    static func data(named name: String) -> Data? {
        data(name)
    }

    private static func load(_ relativePath: String) -> String {
        guard let data = data(relativePath) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func data(_ relativePath: String) -> Data? {
        guard let resourceURL = Bundle(for: BundleToken.self).resourceURL else {
            return nil
        }
        let filename = URL(fileURLWithPath: relativePath).lastPathComponent
        let url = resourceURL.appendingPathComponent(filename)
        return try? Data(contentsOf: url)
    }

    private final class BundleToken {}
}
