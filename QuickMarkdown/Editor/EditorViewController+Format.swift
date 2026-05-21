import AppKit

/// Format-menu actions (PRD §6.7) implemented as `@objc` methods so they
/// participate in the responder chain. All operations go through
/// `NSTextView.shouldChangeText(in:replacementString:)` so undo coalescing is
/// correct.
extension EditorViewController {

    // MARK: - Inline wrappers

    @objc func formatBold(_ sender: Any?)         { wrapSelection(prefix: "**", suffix: "**") }
    @objc func formatItalic(_ sender: Any?)       { wrapSelection(prefix: "*",  suffix: "*") }
    @objc func formatCode(_ sender: Any?)         { wrapSelection(prefix: "`",  suffix: "`") }

    @objc func formatLink(_ sender: Any?) {
        let selRange = textView.selectedRange()
        let store = textView.textStorage ?? NSTextStorage()
        let selected = (store.string as NSString).substring(with: clamp(selRange, in: store.string))
        let visibleText = selected.isEmpty ? "text" : selected
        let template = "[\(visibleText)]()"
        guard textView.shouldChangeText(in: selRange,
                                        replacementString: template) else { return }
        textView.replaceCharacters(in: selRange, with: template)
        // Cursor inside the parentheses: position == selRange.location + count("[\(visibleText)](")
        let nsTemplate = template as NSString
        let openParen = nsTemplate.range(of: "(", options: .backwards).location
        if openParen != NSNotFound {
            let caret = selRange.location + openParen + 1
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
        textView.didChangeText()
    }

    // MARK: - Headings

    @objc func formatHeading1(_ sender: Any?) { setHeading(level: 1) }
    @objc func formatHeading2(_ sender: Any?) { setHeading(level: 2) }
    @objc func formatHeading3(_ sender: Any?) { setHeading(level: 3) }

    private func setHeading(level: Int) {
        let store = textView.textStorage ?? NSTextStorage()
        let ns = store.string as NSString
        let line = ns.lineRange(for: textView.selectedRange())
        let original = ns.substring(with: line)
        // Strip leading hashes + space, then re-apply.
        var stripped = original
        while stripped.hasPrefix("#") { stripped.removeFirst() }
        if stripped.hasPrefix(" ") { stripped.removeFirst() }
        let hashes = String(repeating: "#", count: level)
        let replacement = "\(hashes) \(stripped)"
        guard textView.shouldChangeText(in: line,
                                        replacementString: replacement) else { return }
        textView.replaceCharacters(in: line, with: replacement)
        textView.didChangeText()
    }

    // MARK: - Insertions

    @objc func insertCodeBlock(_ sender: Any?) {
        let snippet = "```\n\n```\n"
        let selRange = textView.selectedRange()
        guard textView.shouldChangeText(in: selRange,
                                        replacementString: snippet) else { return }
        textView.replaceCharacters(in: selRange, with: snippet)
        // Place cursor on the middle (empty) line.
        let caret = selRange.location + ("```\n" as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.didChangeText()
    }

    @objc func insertTable(_ sender: Any?) {
        // Show a Word/Pages-style grid picker anchored to the caret.
        // Falls back to a 3 × 3 stub if no window is available (which
        // shouldn't happen in normal use but keeps the action robust).
        guard view.window != nil else {
            insertTable(rows: 3, columns: 3)
            return
        }
        // Make sure the caret is on screen so the picker doesn't anchor
        // to an off-screen rect (e.g. user is reading further down the
        // document and triggers the action from the toolbar / menu).
        textView.scrollRangeToVisible(textView.selectedRange())
        let caretRect = caretRectInTextView()
        TableGridPicker.present(
            in: textView,
            relativeTo: caretRect,
            preferredEdge: .maxY
        ) { [weak self] rows, cols in
            self?.insertTable(rows: rows, columns: cols)
        }
    }

    /// Insert a `rows × cols` GFM table snippet at the caret. The header
    /// row is selected (first cell text) so the user can immediately type
    /// to replace it.
    private func insertTable(rows: Int, columns: Int) {
        // GFM tables must be preceded and followed by a blank line so
        // CommonMark + GFM recognise them as table blocks, not as part of
        // a preceding paragraph. Insert leading / trailing newlines as
        // needed based on what surrounds the caret.
        let store = textView.textStorage ?? NSTextStorage()
        let ns = store.string as NSString
        let selRange = textView.selectedRange()

        var snippet = TableEditing.newTableSnippet(bodyRows: rows, columns: columns)
        var caretOffset = 0 // start of `Col 1` text in `snippet`

        // Find offset of `Col 1` text in the snippet so we can leave the
        // caret there with a selection covering the placeholder.
        if let r = snippet.range(of: "Col 1") {
            caretOffset = snippet.distance(from: snippet.startIndex, to: r.lowerBound)
        }

        // Need a blank line before? Look at the character immediately
        // before the insertion point.
        let needsLeadingBlank: Bool = {
            guard selRange.location > 0 else { return false }
            let prevChar = ns.character(at: selRange.location - 1)
            if prevChar != 0x0a /* \n */ {
                // mid-line: prefix with `\n\n` so we break out and
                // separate from the current paragraph.
                return true
            }
            // Previous char IS a newline. Need a SECOND newline before
            // it for a true blank line, otherwise prepend one.
            if selRange.location < 2 { return false }
            let prevPrev = ns.character(at: selRange.location - 2)
            return prevPrev != 0x0a
        }()
        if needsLeadingBlank {
            snippet = "\n" + snippet
            caretOffset += 1
        }

        // Need a blank line after?
        let needsTrailingBlank: Bool = {
            let pos = selRange.location + selRange.length
            guard pos < ns.length else { return false }
            return ns.character(at: pos) != 0x0a
        }()
        if needsTrailingBlank {
            snippet += "\n"
        }

        guard textView.shouldChangeText(in: selRange,
                                        replacementString: snippet) else { return }
        textView.replaceCharacters(in: selRange, with: snippet)
        textView.didChangeText()

        // Select the "Col 1" placeholder so the user can overtype.
        let caretLoc = selRange.location + caretOffset
        let placeholderLen = ("Col 1" as NSString).length
        textView.setSelectedRange(NSRange(location: caretLoc, length: placeholderLen))
    }

    /// Pretty-print every Markdown table in the document so the source
    /// pipes line up by column. Operates in reverse source order so each
    /// replacement leaves the offsets of the earlier blocks intact.
    @objc func realignTables(_ sender: Any?) {
        let store = textView.textStorage ?? NSTextStorage()
        let source = store.string
        let blocks = TableEditing.allBlocks(in: source)
        guard !blocks.isEmpty else { NSSound.beep(); return }
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }
        let ns = source as NSString
        for block in blocks.reversed() {
            let original = ns.substring(with: block.nsRange)
            let formatted = TableEditing.format(rows: block.rows,
                                                alignments: block.alignments)
            guard original != formatted else { continue }
            guard textView.shouldChangeText(in: block.nsRange,
                                            replacementString: formatted) else { continue }
            textView.replaceCharacters(in: block.nsRange, with: formatted)
            textView.didChangeText()
        }
    }

    @objc func toggleTask(_ sender: Any?) {
        let store = textView.textStorage ?? NSTextStorage()
        let ns = store.string as NSString
        let line = ns.lineRange(for: textView.selectedRange())
        let original = ns.substring(with: line)
        var replacement = original
        // Strip a leading list marker if present so we can swap states.
        if let r = replacement.range(of: #"^[\s]*-\s\[[xX ]\]\s"#,
                                     options: .regularExpression) {
            let prefix = String(replacement[r])
            let isChecked = prefix.contains("x") || prefix.contains("X")
            let newPrefix = isChecked ? "- [ ] " : "- [x] "
            replacement.replaceSubrange(r, with: newPrefix)
        } else if let r = replacement.range(of: #"^[\s]*-\s"#,
                                            options: .regularExpression) {
            replacement.replaceSubrange(r, with: "- [ ] ")
        } else {
            replacement = "- [ ] " + replacement
        }
        guard textView.shouldChangeText(in: line,
                                        replacementString: replacement) else { return }
        textView.replaceCharacters(in: line, with: replacement)
        textView.didChangeText()
    }

    // MARK: - Helpers

    private func wrapSelection(prefix: String, suffix: String) {
        let store = textView.textStorage ?? NSTextStorage()
        let selRange = clamp(textView.selectedRange(), in: store.string)
        let selected = (store.string as NSString).substring(with: selRange)

        // Unwrap if the selection is already wrapped in the markers.
        if !selected.isEmpty,
           selected.hasPrefix(prefix), selected.hasSuffix(suffix),
           selected.count >= (prefix.count + suffix.count) {
            let stripped = String(selected.dropFirst(prefix.count).dropLast(suffix.count))
            guard textView.shouldChangeText(in: selRange,
                                            replacementString: stripped) else { return }
            textView.replaceCharacters(in: selRange, with: stripped)
            let newRange = NSRange(location: selRange.location,
                                   length: (stripped as NSString).length)
            textView.setSelectedRange(newRange)
            textView.didChangeText()
            return
        }

        let replacement = "\(prefix)\(selected)\(suffix)"
        guard textView.shouldChangeText(in: selRange,
                                        replacementString: replacement) else { return }
        textView.replaceCharacters(in: selRange, with: replacement)
        let prefixLen = (prefix as NSString).length
        let bodyLen = (selected as NSString).length
        if bodyLen == 0 {
            // Caret between markers.
            textView.setSelectedRange(NSRange(location: selRange.location + prefixLen,
                                              length: 0))
        } else {
            // Re-select the wrapped body.
            textView.setSelectedRange(NSRange(location: selRange.location + prefixLen,
                                              length: bodyLen))
        }
        textView.didChangeText()
    }

    private func clamp(_ range: NSRange, in string: String) -> NSRange {
        let len = (string as NSString).length
        let loc = max(0, min(range.location, len))
        let length = max(0, min(range.length, len - loc))
        return NSRange(location: loc, length: length)
    }
}
