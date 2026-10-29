import XCTest
@testable import QuickMarkdown

/// Syntax beyond the CommonMark / GFM specs (GitHub extras and popular
/// extensions), rendered through the Preview pipeline.
@MainActor
final class ExtensionRenderingTests: XCTestCase {
    private func render(_ markdown: String) -> String {
        PreviewViewController.renderBody(source: markdown, baseURL: nil)
    }

    private func assertRenders(_ markdown: String, contains expected: [String],
                               excludes unexpected: [String] = [],
                               file: StaticString = #filePath, line: UInt = #line) {
        let html = render(markdown)
        for fragment in expected {
            XCTAssertTrue(html.contains(fragment), "missing \(fragment) in:\n\(html)", file: file, line: line)
        }
        for fragment in unexpected {
            XCTAssertFalse(html.contains(fragment), "unexpected \(fragment) in:\n\(html)", file: file, line: line)
        }
    }

    // MARK: Callouts

    func testGitHubAlert() {
        assertRenders("> [!NOTE]\n> Body text.", contains: ["qm-alert qm-alert-note", ">Note</p>", "Body text."])
    }

    func testObsidianCalloutWithTitle() {
        assertRenders("> [!tip] Faster builds\n> Use the cache.",
                      contains: ["qm-alert-tip", "Faster builds</p>", "Use the cache."])
    }

    func testFoldableCalloutStartsClosedInPreview() {
        assertRenders("> [!info]- Details\n> Hidden text.",
                      contains: ["<details class=\"qm-alert qm-alert-note\">", "Details</summary>"],
                      excludes: [" open>"])
        assertRenders("> [!bug]+ Open one\n> Shown.", contains: ["qm-alert-caution\" open>"])
    }

    func testUnknownCalloutTypeStaysAQuote() {
        assertRenders("> [!madeup]\n> Text.", contains: ["<blockquote"], excludes: ["qm-alert"])
    }

    // MARK: Maths

    func testMathFence() {
        assertRenders("```math\nx^2 + y^2\n```", contains: ["katex-display"], excludes: ["<pre"])
    }

    func testGitHubInlineMath() {
        assertRenders("Area $`\\pi r^2`$ here.", contains: ["class=\"katex\""], excludes: ["$`"])
    }

    func testLatexDelimiters() {
        assertRenders("Inline \\(a^2\\) and display \\[b^2\\].", contains: ["class=\"katex\"", "katex-display"])
        assertRenders("\\[\nx = \\frac{1}{2}\n\\]", contains: ["katex-display"])
        // CommonMark escapes stay text.
        assertRenders("\\[not a link\\] and \\(\\)", contains: ["[not a link]"], excludes: ["katex"])
    }

    // MARK: Inline extras

    func testEmojiShortcodes() {
        assertRenders("Ship it :tada: :rocket:", contains: ["🎉", "🚀"])
        assertRenders("Not real :not_an_emoji_name: and `:tada:`",
                      contains: [":not_an_emoji_name:", "<code>:tada:</code>"])
    }

    func testHighlight() {
        assertRenders("This is ==important== text.", contains: ["<mark>important</mark>"])
        assertRenders("a == b == c and `==code==`", contains: ["a == b == c", "<code>==code==</code>"],
                      excludes: ["<mark>"])
    }

    func testAbbreviations() {
        assertRenders("*[HTML]: HyperText Markup Language\n\nHTML and XHTML.",
                      contains: ["<abbr title=\"HyperText Markup Language\">HTML</abbr> and XHTML."],
                      excludes: ["*[HTML]"])
    }

    func testInlineFootnote() {
        assertRenders("Claim^[Source: a book.] made.",
                      contains: ["class=\"footnote-ref\"", "class=\"footnotes\"", "Source: a book."],
                      excludes: ["^["])
    }

    // MARK: Blocks

    func testDefinitionList() {
        assertRenders("Term\n: The definition.\n\nOther\n: Second.",
                      contains: ["<dl>", "<dt>", "Term", "<dd>", "The definition.", "Second."])
    }

    func testTableOfContents() {
        assertRenders("[TOC]\n\n# Alpha\n\n## Beta\n\n# Gamma",
                      contains: ["<nav class=\"qm-toc\">", "href=\"#alpha\"", "href=\"#beta\"", "href=\"#gamma\""])
        assertRenders("[[_TOC_]]\n\n# One", contains: ["href=\"#one\""])
        assertRenders("[TOC]\n\n# Ship it :rocket:", contains: [">Ship it 🚀</a>"])
    }

    func testCustomHeadingID() {
        assertRenders("## Install steps {#install}", contains: ["id=\"install\"", ">Install steps</h2>"],
                      excludes: ["{#install}"])
    }

    func testFrontMatterTable() {
        assertRenders("---\ntitle: Hello\ntags:\n  - a\n  - b\n---\n# Body",
                      contains: ["qm-front-matter", "<th>title</th>", "<td>Hello</td>", "<td>a, b</td>", "Body</h1>"])
        assertRenders("---\ntags: [one, \"two\"]\n---\nText", contains: ["<td>one, two</td>"])
    }

    // MARK: Links and images

    func testWikiLinks() {
        assertRenders("[[My Page]]", contains: ["href=\"My%20Page.md\"", ">My Page</a>"])
        assertRenders("[[Page|Alias]]", contains: ["href=\"Page.md\"", ">Alias</a>"])
        assertRenders("[[Page#Some Heading]]", contains: ["href=\"Page.md#some-heading\""])
        assertRenders("![[pic.png|200]]", contains: ["<img", "width=\"200\""])
    }

    func testColorModeImages() {
        assertRenders("![logo](https://example.com/logo.png#gh-dark-mode-only)",
                      contains: ["class=\"gh-dark-mode-only\""])
    }

    func testAutolinks() {
        assertRenders("See www.example.com.", contains: ["href=\"http://www.example.com\">www.example.com</a>."])
    }

    func testUnicodeHeadingSlug() {
        assertRenders("# Café", contains: ["id=\"café\""])
    }

    // MARK: Code and safety

    func testFullLanguageHighlighting() {
        assertRenders("```dockerfile\nFROM alpine\n```", contains: ["hljs-keyword"])
        assertRenders("```powershell\nGet-ChildItem\n```", contains: ["hljs-built_in"])
    }

    func testTagFilter() {
        assertRenders("<script>alert(1)</script>", contains: ["&lt;script>"], excludes: ["<script>"])
    }

    func testExtensionsLeaveCodeBlocksAlone() {
        let source = "```\n[[Page]] ==mark== :tada: ^[note]\nTerm\n: not a definition\n```"
        assertRenders(source, contains: ["[[Page]] ==mark== :tada: ^[note]", ": not a definition"],
                      excludes: ["<mark", "🎉", "<dl>", "footnote"])
    }
}
