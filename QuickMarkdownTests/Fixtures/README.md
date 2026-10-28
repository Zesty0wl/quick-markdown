# Spec fixtures

JSON versions of the Markdown test suites that `SpecConformanceTests`
renders. `scripts/spec-report.py` compares the results with the expected
HTML.

| File | Source | Licence |
| --- | --- | --- |
| `gfm-spec.json` | GitHub Flavored Markdown spec 0.29 (`test/spec.txt` in [swiftlang/swift-cmark](https://github.com/swiftlang/swift-cmark), the parser behind swift-markdown) | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| `cmark-extensions.json` | cmark-gfm extension tests (`test/extensions.txt` in swift-cmark) | BSD-2-Clause (cmark-gfm) |
| `commonmark-0.31.2-spec.json` | [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/spec.json) | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |

The `.txt` specs were converted with the same rules as CommonMark's
`spec_tests.py` (fenced `example` blocks, `.` separator, `→` for tabs).
