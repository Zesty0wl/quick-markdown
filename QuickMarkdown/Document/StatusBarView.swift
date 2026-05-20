import AppKit

/// Small footer view shown at the bottom of every document window.
/// Displays last-modified time, the document format, the dominant line ending,
/// the character count, and the UTF-8 byte size of the buffer.
@MainActor
final class StatusBarView: NSView {

    private let updatedLabel = StatusBarView.makeLabel()
    private let formatLabel = StatusBarView.makeLabel()
    private let lineEndingLabel = StatusBarView.makeLabel()
    private let charCountLabel = StatusBarView.makeLabel()
    private let sizeLabel = StatusBarView.makeLabel()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB]
        f.countStyle = .file
        return f
    }()

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topSeparator)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        stack.addArrangedSubview(updatedLabel)
        stack.addArrangedSubview(makeDivider())
        stack.addArrangedSubview(formatLabel)
        stack.addArrangedSubview(makeDivider())
        stack.addArrangedSubview(lineEndingLabel)
        stack.addArrangedSubview(makeDivider())
        stack.addArrangedSubview(charCountLabel)
        stack.addArrangedSubview(makeDivider())
        stack.addArrangedSubview(sizeLabel)

        // Push everything to the trailing edge.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        stack.insertArrangedSubview(spacer, at: 0)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            topSeparator.topAnchor.constraint(equalTo: topAnchor),
            topSeparator.heightAnchor.constraint(equalToConstant: 1),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Public update

    struct Stats {
        var content: String
        var fileURL: URL?
        var isEdited: Bool
        var fileModificationDate: Date?
    }

    func update(_ stats: Stats) {
        let ns = stats.content as NSString
        let chars = ns.length
        charCountLabel.stringValue = formatChars(chars)

        let bytes = stats.content.lengthOfBytes(using: .utf8)
        sizeLabel.stringValue = Self.byteFormatter.string(fromByteCount: Int64(bytes))

        lineEndingLabel.stringValue = detectLineEnding(in: stats.content)

        formatLabel.stringValue = formatLabelString(for: stats.fileURL)

        updatedLabel.stringValue = updatedString(
            fileModificationDate: stats.fileModificationDate,
            fileURL: stats.fileURL,
            isEdited: stats.isEdited
        )
    }

    // MARK: - Formatting helpers

    private func formatChars(_ count: Int) -> String {
        let n = Self.countFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return count == 1 ? "\(n) char" : "\(n) chars"
    }

    private func detectLineEnding(in source: String) -> String {
        // Probe the first ~4KB only — enough to detect the dominant style.
        let prefix = source.prefix(4096)
        var foundCRLF = false
        var foundCR = false
        var foundLF = false
        var prev: Character = "\0"
        for ch in prefix {
            if ch == "\n" {
                if prev == "\r" { foundCRLF = true }
                else { foundLF = true }
            } else if prev == "\r" {
                foundCR = true
            }
            prev = ch
        }
        if prev == "\r" { foundCR = true }
        if foundCRLF { return "CRLF" }
        if foundCR && !foundLF { return "CR" }
        return "LF"
    }

    private func formatLabelString(for url: URL?) -> String {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else {
            return "Markdown"
        }
        return "Markdown · .\(ext)"
    }

    private func updatedString(fileModificationDate: Date?,
                               fileURL: URL?,
                               isEdited: Bool) -> String {
        if fileURL == nil {
            return isEdited ? "Unsaved draft" : "New document"
        }
        if let date = fileModificationDate {
            let rel = Self.relativeFormatter.localizedString(for: date,
                                                             relativeTo: Date())
            return isEdited ? "Edited · saved \(rel)" : "Saved \(rel)"
        }
        return isEdited ? "Edited" : "Saved"
    }

    // MARK: - Subview factories

    private static func makeLabel() -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = NSFont.systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    private func makeDivider() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 12),
        ])
        return v
    }
}
