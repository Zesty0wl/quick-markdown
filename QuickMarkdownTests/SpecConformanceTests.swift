import XCTest
@testable import QuickMarkdown

/// Renders every example from the CommonMark / GFM spec suites in
/// `Fixtures/` through the Preview's pipeline and writes the results to
/// `spec-results.json` in the test host's temporary directory, for
/// `scripts/spec-report.py` to compare against the expected HTML.
@MainActor
final class SpecConformanceTests: XCTestCase {
    private struct Example: Decodable {
        let example: Int
        let section: String
        let markdown: String
        let html: String
    }

    private struct Result: Encodable {
        let suite: String
        let example: Int
        let section: String
        let markdown: String
        let expected: String
        let actual: String
    }

    func testRenderSpecExamples() throws {
        let suites = ["gfm-spec", "cmark-extensions", "commonmark-0.31.2-spec"]
        var results: [Result] = []
        for suite in suites {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: suite,
                                                                withExtension: "json"))
            let examples = try JSONDecoder().decode([Example].self,
                                                    from: Data(contentsOf: url))
            XCTAssertFalse(examples.isEmpty, suite)
            for example in examples {
                let actual = PreviewViewController.renderBody(source: example.markdown,
                                                              baseURL: nil)
                results.append(Result(suite: suite, example: example.example,
                                      section: example.section,
                                      markdown: example.markdown,
                                      expected: example.html, actual: actual))
            }
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("spec-results.json")
        try JSONEncoder().encode(results).write(to: out)
        print("SPEC_RESULTS \(out.path) (\(results.count) examples)")
    }
}
