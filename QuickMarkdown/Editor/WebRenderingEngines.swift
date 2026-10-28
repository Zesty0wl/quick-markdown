import AppKit
import JavaScriptCore

enum WebRenderingEngines {
    private static let queue = DispatchQueue(label: "QuickMarkdown.WebRenderingEngines")
    private nonisolated(unsafe) static let context: JSContext? = {
        guard let context = JSContext() else { return nil }
        context.exceptionHandler = { _, exception in
            if let exception { NSLog("[QuickMarkdown] JavaScript renderer: %@", exception) }
        }
        context.evaluateScript(WebAssets.highlightScript)
        context.evaluateScript(WebAssets.katexScript)
        return context
    }()

    static func highlight(_ code: String, language: String) -> String? {
        queue.sync {
            guard let context,
                  let highlighter = context.objectForKeyedSubscript("hljs"),
                  let getLanguage = highlighter.objectForKeyedSubscript("getLanguage"),
                  let definition = getLanguage.call(withArguments: [language]),
                  !definition.isUndefined,
                  !definition.isNull,
                  let function = highlighter.objectForKeyedSubscript("highlight"),
                  let result = function.call(withArguments: [
                    code,
                    ["language": language, "ignoreIllegals": true],
                  ]) else { return nil }
            return result.objectForKeyedSubscript("value")?.toString()
        }
    }

    static func renderEquation(_ expression: String, displayMode: Bool) -> String? {
        queue.sync {
            guard let context,
                  let katex = context.objectForKeyedSubscript("katex"),
                  let function = katex.objectForKeyedSubscript("renderToString"),
                  let result = function.call(withArguments: [
                    expression,
                    [
                        "displayMode": displayMode,
                        "throwOnError": false,
                        "strict": "ignore",
                        "output": "htmlAndMathml",
                    ],
                  ]) else { return nil }
            return result.toString()
        }
    }

    static func attributedHighlight(_ code: String,
                                    language: String,
                                    prefersDark: Bool) -> NSAttributedString? {
        guard let highlighted = highlight(code, language: language) else { return nil }
        let tokens = HighlightedCodeParser(prefersDark: prefersDark)
        let fragment = "<code>\(highlighted.replacingOccurrences(of: "\r", with: "&#13;"))</code>"
        let parser = XMLParser(data: Data(fragment.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = tokens
        guard parser.parse(), tokens.output.string == code else { return nil }
        return tokens.output
    }

    private final class HighlightedCodeParser: NSObject, XMLParserDelegate {
        let output = NSMutableAttributedString()
        private let prefersDark: Bool
        private var colors: [NSColor]

        init(prefersDark: Bool) {
            self.prefersDark = prefersDark
            colors = [Self.color(prefersDark ? 0xc9d1d9 : 0x24292e)]
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let scopes = (attributes["class"] ?? "").split(separator: " ").map(String.init)
            let inherited = colors.last ?? .textColor
            colors.append(scopes.compactMap(tokenColor).first ?? inherited)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            if colors.count > 1 { colors.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters text: String) {
            output.append(NSAttributedString(string: text, attributes: [
                .foregroundColor: colors.last ?? .textColor,
            ]))
        }

        private func tokenColor(_ scope: String) -> NSColor? {
            let light: UInt32
            let dark: UInt32
            switch scope {
            case "hljs-keyword", "hljs-doctag", "hljs-template-tag", "hljs-template-variable":
                light = 0xd73a49; dark = 0xff7b72
            case "hljs-title":
                light = 0x6f42c1; dark = 0xd2a8ff
            case "hljs-string", "hljs-regexp", "hljs-meta", "hljs-meta-string":
                light = 0x032f62; dark = 0xa5d6ff
            case "hljs-number", "hljs-literal", "hljs-attr", "hljs-attribute", "hljs-variable":
                light = 0x005cc5; dark = 0x79c0ff
            case "hljs-comment", "hljs-quote", "hljs-code":
                light = 0x6a737d; dark = 0x8b949e
            case "hljs-built_in", "hljs-symbol", "hljs-bullet", "hljs-type":
                light = 0xe36209; dark = 0xffa657
            case "hljs-name", "hljs-selector-tag", "hljs-selector-class", "hljs-addition":
                light = 0x22863a; dark = 0x7ee787
            case "hljs-deletion":
                light = 0xb31d28; dark = 0xffa198
            default:
                return nil
            }
            return Self.color(prefersDark ? dark : light)
        }

        private static func color(_ rgb: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                    green: CGFloat((rgb >> 8) & 0xff) / 255,
                    blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
        }
    }
}

enum MarkdownMathRewriter {
    typealias Renderer = (_ expression: String, _ displayMode: Bool) -> String?

    static func rewrite(_ source: String,
                        renderer: Renderer = WebRenderingEngines.renderEquation) -> String {
        let lines = source.components(separatedBy: "\n")
        var output: [String] = []
        var fenceCharacter: Character?
        var fenceLength = 0
        var blockOriginal: [String]?
        var blockExpression: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if blockOriginal != nil {
                if trimmed.hasSuffix("$$") {
                    let closing = String(trimmed.dropLast(2))
                    if !closing.isEmpty { blockExpression.append(closing) }
                    let expression = blockExpression.joined(separator: "\n")
                    if let rendered = renderer(expression, true) {
                        output.append(rendered)
                    } else {
                        output.append(contentsOf: blockOriginal ?? [])
                        output.append(line)
                    }
                    blockOriginal = nil
                    blockExpression = []
                } else {
                    blockOriginal?.append(line)
                    blockExpression.append(line)
                }
                continue
            }

            if let marker = fenceMarker(in: trimmed) {
                if let active = fenceCharacter {
                    if marker.character == active, marker.length >= fenceLength {
                        fenceCharacter = nil
                        fenceLength = 0
                    }
                } else {
                    fenceCharacter = marker.character
                    fenceLength = marker.length
                }
                output.append(line)
                continue
            }

            guard fenceCharacter == nil else {
                output.append(line)
                continue
            }

            if trimmed.hasPrefix("$$") {
                let afterOpening = String(trimmed.dropFirst(2))
                if afterOpening.hasSuffix("$$"), afterOpening.count >= 2 {
                    let expression = String(afterOpening.dropLast(2))
                    output.append(renderer(expression, true) ?? line)
                } else {
                    blockOriginal = [line]
                    if !afterOpening.isEmpty { blockExpression = [afterOpening] }
                }
                continue
            }

            output.append(rewriteInlineMath(in: line, renderer: renderer))
        }

        if let blockOriginal {
            output.append(contentsOf: blockOriginal)
        }
        return output.joined(separator: "\n")
    }

    private static func rewriteInlineMath(in line: String,
                                          renderer: Renderer) -> String {
        var output = ""
        var cursor = line.startIndex
        var codeDelimiterLength = 0

        while cursor < line.endIndex {
            if line[cursor] == "`" {
                let run = repeatedCharacterCount(in: line, from: cursor, character: "`")
                codeDelimiterLength = codeDelimiterLength == 0 ? run
                    : (run == codeDelimiterLength ? 0 : codeDelimiterLength)
                let end = line.index(cursor, offsetBy: run)
                output += line[cursor..<end]
                cursor = end
                continue
            }

            if line[cursor] == "$", codeDelimiterLength == 0,
               !isEscaped(line, at: cursor),
               let closing = closingDollar(in: line, after: cursor) {
                let expressionStart = line.index(after: cursor)
                let expression = String(line[expressionStart..<closing])
                let afterClosing = line.index(after: closing)
                // Pandoc's rule: a closing `$` followed by a digit is a
                // price, not math, so `$5/$10` stays as text.
                let closesBeforeDigit = afterClosing < line.endIndex
                    && line[afterClosing].isNumber
                if !expression.isEmpty,
                   !expression.first!.isWhitespace,
                   !expression.last!.isWhitespace,
                   !closesBeforeDigit,
                   let rendered = renderer(expression, false) {
                    output += rendered
                    cursor = line.index(after: closing)
                    continue
                }
            }

            output.append(line[cursor])
            cursor = line.index(after: cursor)
        }
        return output
    }

    private static func closingDollar(in line: String,
                                      after opening: String.Index) -> String.Index? {
        var cursor = line.index(after: opening)
        while cursor < line.endIndex {
            // An equation never runs into a code span, so `$10 … `$HOME``
            // doesn't pair the price with the dollar inside the code.
            if line[cursor] == "`" { return nil }
            if line[cursor] == "$", !isEscaped(line, at: cursor) { return cursor }
            cursor = line.index(after: cursor)
        }
        return nil
    }

    private static func isEscaped(_ source: String, at index: String.Index) -> Bool {
        var cursor = index
        var slashes = 0
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            slashes += 1
            cursor = previous
        }
        return slashes % 2 == 1
    }

    private static func repeatedCharacterCount(in source: String,
                                               from start: String.Index,
                                               character: Character) -> Int {
        var cursor = start
        var count = 0
        while cursor < source.endIndex, source[cursor] == character {
            count += 1
            cursor = source.index(after: cursor)
        }
        return count
    }

    private static func fenceMarker(in line: String) -> (character: Character, length: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let length = line.prefix { $0 == first }.count
        return length >= 3 ? (first, length) : nil
    }
}