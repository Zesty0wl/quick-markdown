import Foundation

/// Line-based scan of a Markdown source for fenced code blocks, so the
/// plain-source view can syntax-highlight their contents. Front matter is
/// skipped; unclosed fences run to the end of the document.
struct MarkdownStructureIndex {
    struct CodeBlock: Equatable {
        var language: String
        var contentRange: NSRange
    }

    let codeBlocks: [CodeBlock]

    init(source: String) {
        let text = source as NSString
        var parsedCodeBlocks: [CodeBlock] = []
        var offset = 0
        var fenceCharacter: Character?
        var fenceLength = 0
        var openCodeBlock: (language: String, contentStart: Int)?
        var inFrontMatter = source.hasPrefix("---\n") || source.hasPrefix("---\r\n")
        var isFirstLine = true

        while offset < text.length {
            let lineRange = text.lineRange(for: NSRange(location: offset, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inFrontMatter {
                if !isFirstLine, trimmed == "---" { inFrontMatter = false }
                offset = NSMaxRange(lineRange)
                isFirstLine = false
                continue
            }

            if let marker = Self.fenceMarker(in: trimmed) {
                if let active = fenceCharacter {
                    if marker.character == active, marker.length >= fenceLength {
                        if let openCodeBlock {
                            parsedCodeBlocks.append(CodeBlock(
                                language: openCodeBlock.language,
                                contentRange: NSRange(
                                    location: openCodeBlock.contentStart,
                                    length: max(0, lineRange.location
                                                - openCodeBlock.contentStart)
                                )
                            ))
                        }
                        fenceCharacter = nil
                        fenceLength = 0
                        openCodeBlock = nil
                    }
                } else {
                    fenceCharacter = marker.character
                    fenceLength = marker.length
                    let language = String(trimmed.dropFirst(marker.length))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(whereSeparator: \Character.isWhitespace)
                        .first.map(String.init) ?? ""
                    openCodeBlock = (language, NSMaxRange(lineRange))
                }
            }

            offset = NSMaxRange(lineRange)
            isFirstLine = false
        }

        if let openCodeBlock {
            parsedCodeBlocks.append(CodeBlock(
                language: openCodeBlock.language,
                contentRange: NSRange(location: openCodeBlock.contentStart,
                                      length: text.length - openCodeBlock.contentStart)
            ))
        }
        codeBlocks = parsedCodeBlocks
    }

    private static func fenceMarker(in line: String) -> (character: Character, length: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let length = line.prefix { $0 == first }.count
        return length >= 3 ? (first, length) : nil
    }
}
