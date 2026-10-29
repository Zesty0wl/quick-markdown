import Foundation

/// Source-level passes for popular Markdown extensions that cmark doesn't
/// parse, run before the HTML renderers parse the document:
///
/// * `[[Page]]`, `[[Page|Alias]]`, `[[Page#Heading]]` wiki links and
///   `![[image.png|200]]` embeds (Obsidian, Foam, wikis)
/// * `==highlight==` (Obsidian, Typora, iA Writer)
/// * `^[inline footnotes]` (Pandoc, Obsidian)
/// * definition lists, `Term` then `: definition` (PHP Markdown Extra,
///   Pandoc, MkDocs)
/// * abbreviations, `*[HTML]: HyperText Markup Language`
///
/// Each pass skips fenced and indented code blocks and inline code spans,
/// so code samples are never rewritten. YAML front matter is split off
/// first so the Preview can show it as a table, as GitHub does.
enum MarkdownExtensions {
    struct Prepared {
        /// Markdown ready for `HTMLRenderer` (footnotes rewritten).
        var markdown: String
        /// Top-level YAML front matter as key/value pairs, if any.
        var frontMatter: [(key: String, value: String)]
        /// Abbreviation definitions, applied to text by the renderer.
        var abbreviations: [String: String]
    }

    /// The full preprocessing chain shared by the Preview and HTML export.
    static func prepare(_ source: String) -> Prepared {
        let (frontMatter, body) = splitFrontMatter(source)
        var markdown = MarkdownAttributedRenderer.rewriteDocsImageDirectives(in: body)
        markdown = rewriteInlineFootnotes(markdown)
        let (withoutAbbreviations, abbreviations) = extractAbbreviations(markdown)
        markdown = rewriteWikiLinks(withoutAbbreviations)
        markdown = rewriteHighlights(markdown)
        markdown = rewriteDefinitionLists(markdown)
        markdown = MarkdownAttributedRenderer.rewriteFootnotes(in: markdown, style: .html)
        return Prepared(markdown: markdown, frontMatter: frontMatter,
                        abbreviations: abbreviations)
    }

    // MARK: - Front matter

    /// Splits a leading YAML front matter block (only when it looks like
    /// YAML; see `MarkdownAttributedRenderer.stripFrontMatter`) into its
    /// top-level keys and values. Nested values are shown as their text,
    /// and block lists are joined with commas.
    static func splitFrontMatter(_ source: String) -> ([(key: String, value: String)], String) {
        let stripped = MarkdownAttributedRenderer.stripFrontMatter(source)
        guard stripped != source else { return ([], source) }
        let lines = source.components(separatedBy: "\n")
        var pairs: [(key: String, value: String)] = []
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { break }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let isIndented = line.first == " " || line.first == "\t"
            if !isIndented, let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                pairs.append((key, unquote(value)))
            } else if !pairs.isEmpty {
                // Continuation of the previous key: list items or nested
                // keys.
                var item = trimmed
                if item.hasPrefix("- ") { item = String(item.dropFirst(2)) }
                let previous = pairs[pairs.count - 1].value
                pairs[pairs.count - 1].value = previous.isEmpty ? unquote(item) : previous + ", " + unquote(item)
            }
        }
        return (pairs, stripped)
    }

    private static func unquote(_ value: String) -> String {
        // A flow list (`[a, "b"]`) reads like a block list: comma-joined.
        if value.hasPrefix("["), value.hasSuffix("]") {
            return value.dropFirst().dropLast()
                .split(separator: ",")
                .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: ", ")
        }
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: - Code awareness

    /// True for lines inside fenced code blocks (fences included) and for
    /// indented code blocks (four-space lines that follow a blank line or
    /// more indented code).
    static func codeLines(_ lines: [String]) -> [Bool] {
        var mask = Array(repeating: false, count: lines.count)
        var fence: (character: Character, length: Int)?
        var previousBlankOrCode = true
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                mask[i] = true
                let run = trimmed.prefix { $0 == open.character }.count
                if run >= open.length, trimmed.dropFirst(run).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                previousBlankOrCode = true
                continue
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix { $0 == first }.count
                if run >= 3 {
                    fence = (first, run)
                    mask[i] = true
                    continue
                }
            }
            let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
            if indented, !trimmed.isEmpty, previousBlankOrCode {
                mask[i] = true
                continue
            }
            previousBlankOrCode = trimmed.isEmpty
        }
        return mask
    }

    /// Applies `transform` to the parts of `line` outside inline code spans.
    static func mapProse(_ line: String, _ transform: (String) -> String) -> String {
        guard line.contains("`") else { return transform(line) }
        let chars = Array(line)
        var out = ""
        var prose = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "`" else {
                prose.append(chars[i])
                i += 1
                continue
            }
            let run = chars[i...].prefix { $0 == "`" }.count
            // Find a closing run of exactly the same length.
            var j = i + run
            var close: Int?
            while j < chars.count {
                if chars[j] == "`" {
                    let closing = chars[j...].prefix { $0 == "`" }.count
                    if closing == run { close = j; break }
                    j += closing
                } else {
                    j += 1
                }
            }
            if let close {
                out += transform(prose)
                prose = ""
                out += String(chars[i..<(close + run)])
                i = close + run
            } else {
                prose += String(chars[i..<(i + run)])
                i += run
            }
        }
        return out + transform(prose)
    }

    /// Runs `transform` over every prose line (outside code).
    private static func mapProseLines(_ markdown: String,
                                      _ transform: (String) -> String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let code = codeLines(lines)
        for i in lines.indices where !code[i] {
            lines[i] = mapProse(lines[i], transform)
        }
        return lines.joined(separator: "\n")
    }

    private static func replacing(_ text: String, pattern: String,
                                  _ replacement: ([String]) -> String?) -> String {
        text.replacingMatches(of: pattern, replacement)
    }

    // MARK: - Inline footnotes

    /// `text^[note]` becomes a regular footnote reference plus a definition
    /// appended to the document, so footnote numbering and layout match.
    static func rewriteInlineFootnotes(_ markdown: String) -> String {
        guard markdown.contains("^[") else { return markdown }
        var definitions: [String] = []
        let rewritten = mapProseLines(markdown) { prose in
            guard prose.contains("^[") else { return prose }
            let chars = Array(prose)
            var out = ""
            var i = 0
            while i < chars.count {
                if chars[i] == "^", i + 1 < chars.count, chars[i + 1] == "[",
                   i == 0 || chars[i - 1] != "\\" {
                    // Balanced brackets.
                    var depth = 0
                    var j = i + 1
                    var end: Int?
                    while j < chars.count {
                        if chars[j] == "\\" { j += 2; continue }
                        if chars[j] == "[" { depth += 1 }
                        if chars[j] == "]" {
                            depth -= 1
                            if depth == 0 { end = j; break }
                        }
                        j += 1
                    }
                    if let end, end > i + 2 {
                        definitions.append(String(chars[(i + 2)..<end]))
                        out += "[^qm-inline-\(definitions.count)]"
                        i = end + 1
                        continue
                    }
                }
                out.append(chars[i])
                i += 1
            }
            return out
        }
        guard !definitions.isEmpty else { return markdown }
        var result = rewritten
        while result.hasSuffix("\n") { result.removeLast() }
        result += "\n"
        for (index, text) in definitions.enumerated() {
            result += "\n[^qm-inline-\(index + 1)]: \(text)\n"
        }
        return result
    }

    // MARK: - Abbreviations

    /// Removes `*[ABBR]: Full text` lines and returns their definitions.
    static func extractAbbreviations(_ markdown: String) -> (String, [String: String]) {
        guard markdown.contains("*[") else { return (markdown, [:]) }
        let lines = markdown.components(separatedBy: "\n")
        let code = codeLines(lines)
        var kept: [String] = []
        var abbreviations: [String: String] = [:]
        let pattern = try? NSRegularExpression(pattern: #"^\*\[([^\]]+)\]:[ \t]*(.*?)\s*$"#)
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            if !code[i], let pattern,
               let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                abbreviations[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2))
                continue
            }
            kept.append(line)
        }
        return (kept.joined(separator: "\n"), abbreviations)
    }

    // MARK: - Wiki links

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif",
    ]

    /// `[[Page]]` → `[Page](<Page.md>)`; `[[Page|Alias]]`, `[[Page#Heading]]`
    /// and `[[#Heading]]` likewise; `![[photo.png|200]]` → an `<img>` (width,
    /// or `200x100` for both). `[[x]]` is left alone when `[x]` is a link
    /// reference, and `[[TOC]]` / `[[_TOC_]]` are table-of-contents markers.
    static func rewriteWikiLinks(_ markdown: String) -> String {
        guard markdown.contains("[[") else { return markdown }
        // Labels of link reference definitions (`[label]: url`).
        var referenceLabels: Set<String> = []
        if let definition = try? NSRegularExpression(pattern: #"^ {0,3}\[+([^\[\]]+)\]+:"#,
                                                      options: .anchorsMatchLines) {
            let ns = markdown as NSString
            for match in definition.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
                referenceLabels.insert(ns.substring(with: match.range(at: 1)).lowercased())
            }
        }
        return mapProseLines(markdown) { prose in
            guard prose.contains("[[") else { return prose }
            // Not when wrapped in more brackets (`[[[x]]]`).
            return replacing(prose, pattern: #"(?<!\[)(!?)\[\[([^\[\]\n]+?)\]\](?!\])"#) { groups in
                let isEmbed = groups[1] == "!"
                let inner = groups[2]
                let lowered = inner.lowercased()
                if lowered == "toc" || lowered == "_toc_" || referenceLabels.contains(lowered) {
                    return nil
                }
                let parts = inner.split(separator: "|", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                let target = parts[0]
                let alias = parts.count > 1 ? parts[1] : nil
                var file = target
                var fragment = ""
                if let hash = target.firstIndex(of: "#") {
                    file = String(target[..<hash])
                    fragment = HTMLRenderer.slugify(String(target[target.index(after: hash)...]))
                }
                let ext = (file as NSString).pathExtension.lowercased()
                if isEmbed, imageExtensions.contains(ext) {
                    var size = ""
                    if let alias {
                        let dims = alias.lowercased().split(separator: "x").map(String.init)
                        if let width = dims.first.flatMap({ Int($0) }) { size += " width=\"\(width)\"" }
                        if dims.count > 1, let height = Int(dims[1]) { size += " height=\"\(height)\"" }
                    }
                    let src = HTMLRenderer.escapeAttr(file)
                    return "<img src=\"\(src)\" alt=\"\(src)\"\(size)>"
                }
                if !file.isEmpty, ext.isEmpty { file += ".md" }
                let destination = file + (fragment.isEmpty ? "" : "#" + fragment)
                let label = alias ?? target.replacingOccurrences(of: "#", with: " › ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ›"))
                let escapedLabel = label.replacingOccurrences(of: "[", with: "\\[")
                    .replacingOccurrences(of: "]", with: "\\]")
                return "[\(escapedLabel)](<\(destination)>)"
            }
        }
    }

    // MARK: - Highlight

    /// `==text==` → `<mark>text</mark>` (formatting inside still works).
    static func rewriteHighlights(_ markdown: String) -> String {
        guard markdown.contains("==") else { return markdown }
        return mapProseLines(markdown) { prose in
            guard prose.contains("==") else { return prose }
            return replacing(prose, pattern: #"(?<![=\\])==(?=[^\s=])(.+?)(?<=[^\s=\\])==(?!=)"#) { groups in
                "<mark style=\"background:#fff3a3;color:inherit;\">\(groups[1])</mark>"
            }
        }
    }

    // MARK: - Definition lists

    /// ```
    /// Term
    /// : Definition, with indented continuation lines
    /// ```
    /// becomes a `<dl>`. Terms and definitions stay Markdown: each sits
    /// between blank lines inside the HTML block, so formatting, links and
    /// multiple paragraphs render.
    static func rewriteDefinitionLists(_ markdown: String) -> String {
        guard markdown.contains("\n:") else { return markdown }
        let lines = markdown.components(separatedBy: "\n")
        let code = codeLines(lines)
        func isDefinition(_ i: Int) -> Bool {
            i < lines.count && !code[i] && lines[i].range(of: #"^:[ \t]+\S"#, options: .regularExpression) != nil
        }
        func isTerm(_ i: Int) -> Bool {
            guard i >= 0, !code[i] else { return false }
            let line = lines[i]
            guard let first = line.first, first != " ", first != "\t" else { return false }
            return line.range(of: #"^(#|>|[-*+] |\d+[.)] |\||:|<|!\[|\[\^)"#, options: .regularExpression) == nil
        }
        var out: [String] = []
        var i = 0
        while i < lines.count {
            // A group starts at a run of term lines followed by `: `.
            var termEnd = i
            while termEnd < lines.count, isTerm(termEnd), !isDefinition(termEnd) { termEnd += 1 }
            guard termEnd > i, isDefinition(termEnd), i == 0 || lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty
                || out.last?.isEmpty == true else {
                out.append(lines[i])
                i += 1
                continue
            }
            var html = ["<dl>"]
            var cursor = i
            // Terms and definitions alternate until the group ends.
            while cursor < lines.count {
                var terms: [String] = []
                while cursor < lines.count, isTerm(cursor), !isDefinition(cursor) {
                    terms.append(lines[cursor])
                    cursor += 1
                }
                guard isDefinition(cursor) else {
                    cursor -= terms.count
                    break
                }
                for term in terms {
                    html += ["<dt>", "", term, "", "</dt>"]
                }
                while isDefinition(cursor) {
                    var body = [String(lines[cursor].drop { $0 == ":" }.drop { $0 == " " || $0 == "\t" })]
                    cursor += 1
                    // Indented continuation lines, and blank lines followed
                    // by more indented lines.
                    while cursor < lines.count {
                        let line = lines[cursor]
                        if line.hasPrefix("    ") || line.hasPrefix("\t") {
                            body.append(line.hasPrefix("\t") ? String(line.dropFirst()) : String(line.dropFirst(4)))
                            cursor += 1
                        } else if line.trimmingCharacters(in: .whitespaces).isEmpty,
                                  cursor + 1 < lines.count,
                                  lines[cursor + 1].hasPrefix("    ") || lines[cursor + 1].hasPrefix("\t") {
                            body.append("")
                            cursor += 1
                        } else {
                            break
                        }
                    }
                    html += ["<dd>", ""] + body + ["", "</dd>"]
                }
                // A blank line followed by another term group continues the list.
                if cursor + 1 < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty,
                   isTerm(cursor + 1) {
                    var lookahead = cursor + 1
                    while lookahead < lines.count, isTerm(lookahead), !isDefinition(lookahead) { lookahead += 1 }
                    if isDefinition(lookahead) {
                        cursor += 1
                        continue
                    }
                }
                break
            }
            html.append("</dl>")
            if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
            out += html
            out.append("")
            i = cursor
        }
        return out.joined(separator: "\n")
    }
}

extension String {
    /// Replaces each match of `pattern` with `replacement(groups)`, where
    /// `groups[0]` is the whole match; returning nil keeps the match as is.
    func replacingMatches(of pattern: String, _ replacement: ([String]) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let ns = self as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            guard let new = replacement(groups) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += new
            cursor = NSMaxRange(match.range)
        }
        return out + ns.substring(from: cursor)
    }
}
