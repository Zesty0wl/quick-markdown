import Foundation

/// Parsing, pretty-printing, and cell-coordinate math for GFM Markdown
/// tables. Used by the editor to power the table grid picker, Tab /
/// Shift-Tab / Return navigation inside table cells, and the "Realign
/// Tables" command. The implementation is a small string-level parser
/// (no swift-markdown dependency) so it stays cheap to call on every
/// keystroke.
///
/// Tables are recognised only when each row both starts and ends with a
/// pipe — i.e. `| a | b |`, not the borderless `a | b` variant. That
/// keeps detection unambiguous in mid-stream prose and matches the
/// snippet shape this editor inserts.
enum TableEditing {

    // MARK: - Types

    /// Column alignment, decoded from the colons on the separator row.
    enum Alignment: Equatable {
        case `default`, left, center, right
    }

    /// Parsed view of a single table block.
    struct Block {
        /// Range of physical line indices (0-based) covered by the block,
        /// inclusive at both ends. Includes the header line, the separator
        /// line, and any body lines that immediately follow.
        let lineNumbers: ClosedRange<Int>

        /// Column count (matches `alignments.count`).
        let columnCount: Int

        /// Per-column alignment as parsed from the separator row.
        let alignments: [Alignment]

        /// All rows of cell text, already trimmed of surrounding whitespace.
        /// Index 0 is the header row; indices 1... are body rows. The
        /// separator row is intentionally absent.
        let rows: [[String]]

        /// Range in the original source string covering the block, from
        /// the first character of the header line through (and including)
        /// the trailing newline of the last body line — or to the end of
        /// the source if the block runs to the end of the document.
        let nsRange: NSRange
    }

    // MARK: - Line-level predicates

    /// `line` looks like a table row: trimmed length ≥ 2, starts AND ends
    /// with `|`.
    static func isTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 2 && t.hasPrefix("|") && t.hasSuffix("|")
    }

    /// If `line` is a GFM separator row (e.g. `| --- | :---: | ---: |`),
    /// returns the per-column alignments; otherwise nil. Permissive on
    /// dash count (≥ 1) to match what most editors emit.
    static func parseSeparator(_ line: String) -> [Alignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.hasPrefix("|"), t.hasSuffix("|") else { return nil }
        let inner = String(t.dropFirst().dropLast())
        let cells = inner
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !cells.isEmpty else { return nil }
        var out: [Alignment] = []
        for c in cells {
            guard !c.isEmpty else { return nil }
            let leftColon = c.hasPrefix(":")
            let rightColon = c.hasSuffix(":")
            var middle = c
            if leftColon { middle.removeFirst() }
            if rightColon { middle.removeLast() }
            guard !middle.isEmpty, middle.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leftColon, rightColon) {
            case (true,  true):  out.append(.center)
            case (true,  false): out.append(.left)
            case (false, true):  out.append(.right)
            case (false, false): out.append(.default)
            }
        }
        return out
    }

    /// Split a row line into trimmed cell strings. Returns `[]` for a
    /// non-row line.
    static func parseRowCells(_ line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.hasPrefix("|"), t.hasSuffix("|") else { return [] }
        let inner = String(t.dropFirst().dropLast())
        return inner
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Block discovery

    /// Find the table block (header + separator + body) that contains the
    /// given character offset in `source`, or nil if the offset isn't
    /// inside one.
    static func block(at location: Int, in source: String) -> Block? {
        let lines = source.components(separatedBy: "\n")
        let starts = lineStartOffsets(in: lines)
        guard let lineIdx = lineIndex(for: location, lineStarts: starts, in: source) else {
            return nil
        }
        return blockSpanning(line: lineIdx, lines: lines, lineStarts: starts, in: source)
    }

    /// Return every table block in `source`, in source order. The blocks
    /// are non-overlapping; their `nsRange` values are stable as long as
    /// callers process them in reverse order when mutating the source.
    static func allBlocks(in source: String) -> [Block] {
        let lines = source.components(separatedBy: "\n")
        let starts = lineStartOffsets(in: lines)
        var out: [Block] = []
        var i = 0
        while i + 1 < lines.count {
            if isTableRow(lines[i]),
               parseSeparator(lines[i + 1]) != nil,
               let block = blockSpanning(line: i, lines: lines, lineStarts: starts, in: source) {
                out.append(block)
                i = block.lineNumbers.upperBound + 1
                continue
            }
            i += 1
        }
        return out
    }

    private static func lineStartOffsets(in lines: [String]) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(lines.count)
        var pos = 0
        for line in lines {
            out.append(pos)
            pos += (line as NSString).length + 1 // +1 for the newline
        }
        return out
    }

    private static func lineIndex(for location: Int, lineStarts: [Int], in source: String) -> Int? {
        guard !lineStarts.isEmpty else { return nil }
        let total = (source as NSString).length
        for i in lineStarts.indices {
            let start = lineStarts[i]
            let end = (i + 1 < lineStarts.count) ? lineStarts[i + 1] : total + 1
            if location >= start && location < end {
                return i
            }
        }
        return lineStarts.indices.last
    }

    /// Walk up and down from `line` to find the contiguous block of table
    /// rows it belongs to; returns nil if line N or N±1 doesn't form a
    /// valid header + separator pairing.
    private static func blockSpanning(line: Int,
                                      lines: [String],
                                      lineStarts: [Int],
                                      in source: String) -> Block? {
        // Walk up over consecutive table-row lines.
        var top = line
        while top > 0 && isTableRow(lines[top - 1]) { top -= 1 }
        // Walk down likewise.
        var bottom = line
        while bottom + 1 < lines.count && isTableRow(lines[bottom + 1]) { bottom += 1 }
        // Need at least header + separator.
        guard bottom >= top + 1,
              isTableRow(lines[top]),
              let aligns = parseSeparator(lines[top + 1]) else { return nil }
        let colCount = aligns.count
        var rows: [[String]] = [padCells(parseRowCells(lines[top]), to: colCount)]
        if bottom >= top + 2 {
            for i in (top + 2)...bottom {
                rows.append(padCells(parseRowCells(lines[i]), to: colCount))
            }
        }
        let total = (source as NSString).length
        let startOffset = lineStarts[top]
        let endOffset = (bottom + 1 < lines.count) ? lineStarts[bottom + 1] : total
        return Block(
            lineNumbers: top...bottom,
            columnCount: colCount,
            alignments: aligns,
            rows: rows,
            nsRange: NSRange(location: startOffset, length: endOffset - startOffset)
        )
    }

    private static func padCells(_ cells: [String], to count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    // MARK: - Formatting

    /// Pretty-print a table from `rows` (index 0 = header) and
    /// `alignments`. Pipes are aligned by column; columns are padded with
    /// single spaces on each side. The output is terminated with a single
    /// trailing newline.
    static func format(rows: [[String]], alignments: [Alignment]) -> String {
        let colCount = alignments.count
        guard !rows.isEmpty, colCount > 0 else { return "" }

        var widths = Array(repeating: 0, count: colCount)
        for row in rows {
            for (c, cell) in row.enumerated() where c < colCount {
                widths[c] = max(widths[c], cell.count)
            }
        }
        // Separator must fit too: `---` minimum, `:---` / `---:` / `:---:`
        // for non-default alignments.
        for (c, a) in alignments.enumerated() {
            let minSep: Int
            switch a {
            case .default: minSep = 3
            case .left, .right: minSep = 4
            case .center: minSep = 5
            }
            widths[c] = max(widths[c], minSep)
        }

        var out = formatRow(rows[0], widths: widths, alignments: alignments) + "\n"
        out += formatSeparator(widths: widths, alignments: alignments) + "\n"
        if rows.count > 1 {
            for i in 1..<rows.count {
                out += formatRow(rows[i], widths: widths, alignments: alignments) + "\n"
            }
        }
        return out
    }

    private static func formatRow(_ row: [String],
                                  widths: [Int],
                                  alignments: [Alignment]) -> String {
        var s = "|"
        for c in widths.indices {
            let cell = (c < row.count) ? row[c] : ""
            s += " " + pad(cell, to: widths[c], alignment: alignments[c]) + " |"
        }
        return s
    }

    private static func formatSeparator(widths: [Int],
                                        alignments: [Alignment]) -> String {
        var s = "|"
        for c in widths.indices {
            let width = widths[c]
            let a = alignments[c]
            let dashCount: Int
            switch a {
            case .default:        dashCount = width
            case .left, .right:   dashCount = max(3, width - 1)
            case .center:         dashCount = max(3, width - 2)
            }
            var seg = String(repeating: "-", count: dashCount)
            switch a {
            case .default: break
            case .left:    seg = ":" + seg
            case .right:   seg = seg + ":"
            case .center:  seg = ":" + seg + ":"
            }
            s += " " + seg + " |"
        }
        return s
    }

    private static func pad(_ s: String, to width: Int, alignment: Alignment) -> String {
        let len = s.count
        if len >= width { return s }
        let extra = width - len
        switch alignment {
        case .default, .left:
            return s + String(repeating: " ", count: extra)
        case .right:
            return String(repeating: " ", count: extra) + s
        case .center:
            let left = extra / 2
            let right = extra - left
            return String(repeating: " ", count: left) + s + String(repeating: " ", count: right)
        }
    }

    // MARK: - Snippet builders

    /// Build a fresh table snippet for insertion. `rows` body rows + a
    /// single header row, `cols` columns. Default alignment for every
    /// column. Header cells read `Col 1`, `Col 2`, etc.
    static func newTableSnippet(bodyRows: Int, columns cols: Int) -> String {
        let safeRows = max(0, bodyRows)
        let safeCols = max(1, cols)
        let aligns = Array(repeating: Alignment.default, count: safeCols)
        let header = (1...safeCols).map { "Col \($0)" }
        let body = Array(repeating: Array(repeating: "", count: safeCols), count: safeRows)
        return format(rows: [header] + body, alignments: aligns)
    }

    // MARK: - Cell <-> caret mapping

    /// Return the (row, column) of the cell containing `location` inside
    /// `block`, or nil if the caret sits on the separator line (rows are
    /// numbered with the header as 0, body rows as 1...; the separator is
    /// transparent).
    static func cell(at location: Int, in block: Block, source: String) -> (row: Int, col: Int)? {
        let lines = source.components(separatedBy: "\n")
        let starts = lineStartOffsets(in: lines)
        guard let lineIdx = lineIndex(for: location, lineStarts: starts, in: source),
              block.lineNumbers.contains(lineIdx) else { return nil }
        let offsetInBlock = lineIdx - block.lineNumbers.lowerBound
        // 0 = header, 1 = separator, 2... = body[0]...
        let rowIndex: Int
        if offsetInBlock == 0 {
            rowIndex = 0
        } else if offsetInBlock == 1 {
            return nil
        } else {
            rowIndex = offsetInBlock - 1
        }
        guard rowIndex < block.rows.count else { return nil }

        let line = lines[lineIdx]
        let pipes = pipePositions(in: line)
        // No cells to identify if the line somehow has < 2 pipes.
        guard pipes.count >= 2 else { return nil }
        let inLine = location - starts[lineIdx]
        var col = 0
        for k in 0..<(pipes.count - 1) {
            if inLine > pipes[k] && inLine <= pipes[k + 1] {
                col = k
                break
            }
            // Caret past the trailing pipe: treat as last cell.
            if k == pipes.count - 2 && inLine > pipes[k + 1] {
                col = k
            }
        }
        col = min(col, block.columnCount - 1)
        return (rowIndex, col)
    }

    /// Caret offset (in `source`) at the start of the trimmed cell text of
    /// (row, col) inside `block`. Returns nil if the coordinates fall
    /// outside the block's line range.
    static func caretAtCellStart(row: Int,
                                 col: Int,
                                 in block: Block,
                                 source: String) -> Int? {
        return caret(forRow: row,
                     col: col,
                     skipLeadingSpace: true,
                     in: block,
                     source: source)
    }

    /// Caret offset at the end of the trimmed text of cell (row, col).
    /// Useful for placing the caret at the end of an existing cell.
    static func caretAtCellEnd(row: Int,
                               col: Int,
                               in block: Block,
                               source: String) -> Int? {
        return caret(forRow: row,
                     col: col,
                     skipLeadingSpace: false,
                     trailing: true,
                     in: block,
                     source: source)
    }

    private static func caret(forRow row: Int,
                              col: Int,
                              skipLeadingSpace: Bool,
                              trailing: Bool = false,
                              in block: Block,
                              source: String) -> Int? {
        let lines = source.components(separatedBy: "\n")
        let starts = lineStartOffsets(in: lines)
        // Row 0 = header (offset 0), row N≥1 = body (offset N + 1, skipping separator)
        let offsetInBlock = (row == 0) ? 0 : (row + 1)
        let lineIdx = block.lineNumbers.lowerBound + offsetInBlock
        guard lines.indices.contains(lineIdx),
              starts.indices.contains(lineIdx) else { return nil }
        let line = lines[lineIdx]
        let pipes = pipePositions(in: line)
        guard col + 1 < pipes.count else { return nil }
        let ns = line as NSString
        let cellStart = pipes[col] + 1
        let cellEnd = pipes[col + 1]
        guard cellStart < cellEnd else {
            return starts[lineIdx] + cellStart
        }
        var p = cellStart
        if skipLeadingSpace {
            while p < cellEnd, isHorizontalWhitespace(ns.character(at: p)) {
                p += 1
            }
        }
        if trailing {
            var e = cellEnd
            while e > cellStart, isHorizontalWhitespace(ns.character(at: e - 1)) {
                e -= 1
            }
            return starts[lineIdx] + max(p, e)
        }
        return starts[lineIdx] + p
    }

    private static func pipePositions(in line: String) -> [Int] {
        let ns = line as NSString
        var out: [Int] = []
        for i in 0..<ns.length where ns.character(at: i) == 0x7c {
            out.append(i)
        }
        return out
    }

    private static func isHorizontalWhitespace(_ c: unichar) -> Bool {
        return c == 0x20 /* space */ || c == 0x09 /* tab */
    }

    // MARK: - Row insertion

    /// Build a re-formatted version of `block`'s source representation,
    /// with a new empty body row appended at the end. Returns the new
    /// source text for the block (always ends with a newline) and the
    /// caret offset, relative to `block.nsRange.location`, that the
    /// editor should jump to (start of first cell in the new row).
    static func appendingEmptyRow(_ block: Block) -> (text: String, caretOffsetInBlock: Int) {
        var rows = block.rows
        rows.append(Array(repeating: "", count: block.columnCount))
        let text = format(rows: rows, alignments: block.alignments)
        // Caret target: walk the new text to the start of the last row's
        // first cell.
        let lines = text.components(separatedBy: "\n")
        // last non-empty line is the new row (text ends with "\n" so
        // there's a trailing empty element).
        let nonEmpty = lines.enumerated().filter { !$0.element.isEmpty }
        guard let lastEntry = nonEmpty.last else {
            return (text, 0)
        }
        let lineIdx = lastEntry.offset
        var pos = 0
        for i in 0..<lineIdx {
            pos += (lines[i] as NSString).length + 1
        }
        let line = lines[lineIdx] as NSString
        // First pipe + 1, then skip a single padding space.
        var p = 0
        while p < line.length && line.character(at: p) != 0x7c { p += 1 }
        p += 1 // past the pipe
        while p < line.length, line.character(at: p) == 0x20 { p += 1 }
        return (text, pos + p)
    }
}
