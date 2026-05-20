import AppKit

/// Rescales font sizes in an attributed string before it goes onto the
/// pasteboard, so pasted content lands at reasonable sizes in apps like
/// Microsoft Word, Pages, and Notes.
///
/// Quick Markdown is tuned for comfortable on-screen reading (16 pt body,
/// 32 pt H1, ...). Word's "Normal" style is 11 pt and its Heading 1 is
/// roughly 16 pt. Without this transform a pasted heading shows up at
/// 32 pt — accurate, but jarring.
///
/// We apply a linear `11 / 16` scale (≈ 0.6875) and round to the nearest
/// integer point, with a floor at 8 pt. The result mapping for our current
/// sizes is:
///
///   |  on-screen  |  pasted  |
///   |-------------|----------|
///   |  14 pt code | 10 pt    |
///   |  16 pt body | 11 pt    |
///   |  18 pt H4   | 12 pt    |
///   |  20 pt H3   | 14 pt    |
///   |  24 pt H2   | 17 pt    |
///   |  32 pt H1   | 22 pt    |
///
/// Only the `.font` attribute is touched — colours, paragraph styles, links,
/// underlines, etc. are preserved exactly as on screen.
enum ClipboardNormalizer {

    /// Multiplier from on-screen size to clipboard size. 11/16 maps our
    /// 16-pt body to Word's 11-pt Normal default.
    private static let scale: CGFloat = 11.0 / 16.0

    /// Smallest size we'll ever emit. Below this characters become unreadable
    /// in Word's review pane.
    private static let minSize: CGFloat = 8

    /// Returns a copy of `source` with every `NSFont` resized for clipboard
    /// export. All other attributes are preserved.
    static func normalize(_ source: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: source)
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let target = scaled(font.pointSize)
            if abs(target - font.pointSize) < 0.01 { return }
            let resized = font.withSize(target)
            out.addAttribute(.font, value: resized, range: range)
        }
        return out
    }

    private static func scaled(_ size: CGFloat) -> CGFloat {
        max(minSize, (size * scale).rounded())
    }
}
