import AppKit

/// Single source of truth for typography, colours, and spacing in Quick Markdown.
///
/// All values are derived from semantic `NSColor` and system fonts so that light
/// and dark mode "just work".
enum MarkdownStyles {

    // MARK: - Geometry

    /// Maximum width of the centred content column.
    static let contentMaxWidth: CGFloat = 740
    /// Editor padding inside the scroll view.
    static let editorInset = NSSize(width: 24, height: 24)

    // MARK: - Font sizes (Phase 2 baseline; Preferences in Phase 6 will scale these)

    static let bodyFontSize: CGFloat = 16
    static let h1FontSize: CGFloat = 32
    static let h2FontSize: CGFloat = 24
    static let h3FontSize: CGFloat = 20
    static let h4FontSize: CGFloat = 18
    static let h5FontSize: CGFloat = 16
    static let h6FontSize: CGFloat = 15
    static let codeFontSize: CGFloat = 14
    static let plainSourceFontSize: CGFloat = 14

    // MARK: - Line heights

    static let bodyLineHeight: CGFloat = 1.6
    static let headingLineHeight: CGFloat = 1.3

    // MARK: - Colours
    //
    // These resolve through `ReadingPreferences.shared.theme` so the editor
    // and preview repaint when the user picks a different reading theme. The
    // `.system` theme falls through to AppKit semantic colours, which already
    // adapt to light / dark mode automatically.

    static var foreground: NSColor { ReadingPreferences.shared.theme.foreground }
    static var secondaryForeground: NSColor { ReadingPreferences.shared.theme.secondaryForeground }
    /// Used for raw Markdown markers when they are NOT adjacent to the cursor.
    static var dimmedMarker: NSColor { ReadingPreferences.shared.theme.dimmedMarker }
    static var codeForeground: NSColor { ReadingPreferences.shared.theme.codeForeground }
    static var codeBackground: NSColor { ReadingPreferences.shared.theme.codeBackground }
    static let blockquoteAccent: NSColor = .controlAccentColor
    static var blockquoteText: NSColor { ReadingPreferences.shared.theme.blockquoteText }
    static var linkColor: NSColor { ReadingPreferences.shared.theme.linkColor }
    static var tableBorder: NSColor { ReadingPreferences.shared.theme.tableBorder }
    static var tableHeaderBackground: NSColor { ReadingPreferences.shared.theme.tableHeaderBackground }
    static var tableStripe: NSColor { ReadingPreferences.shared.theme.tableStripe }

    // MARK: - Fonts

    static func bodyFont(size: CGFloat = bodyFontSize) -> NSFont {
        ReadingPreferences.shared.fontFamily.body(size: size, weight: .regular)
    }

    static func headingFont(level: Int) -> NSFont {
        let size: CGFloat
        let weight: NSFont.Weight
        switch level {
        case 1: size = h1FontSize; weight = .bold
        case 2: size = h2FontSize; weight = .semibold
        case 3: size = h3FontSize; weight = .semibold
        case 4: size = h4FontSize; weight = .semibold
        case 5: size = h5FontSize; weight = .semibold
        default: size = h6FontSize; weight = .semibold
        }
        return ReadingPreferences.shared.fontFamily.body(size: size, weight: weight)
    }

    static func monospacedFont(size: CGFloat = codeFontSize, weight: NSFont.Weight = .regular) -> NSFont {
        ReadingPreferences.shared.fontFamily.mono(size: size, weight: weight)
    }

    // MARK: - Paragraph styles

    static func bodyParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = bodyLineHeight
        style.paragraphSpacing = 8
        return style
    }

    static func headingParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = headingLineHeight
        style.paragraphSpacingBefore = 16
        style.paragraphSpacing = 8
        return style
    }

    static func codeBlockParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.4
        style.paragraphSpacingBefore = 8
        style.paragraphSpacing = 8
        return style
    }

    static func blockquoteParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = bodyLineHeight
        style.firstLineHeadIndent = 16
        style.headIndent = 16
        style.paragraphSpacing = 8
        return style
    }

    static func listParagraphStyle(level: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = bodyLineHeight
        let indent = CGFloat(level) * 24
        style.firstLineHeadIndent = indent
        style.headIndent = indent + 16
        style.paragraphSpacing = 4
        return style
    }

    // MARK: - Default attributes (for unstyled text)

    static var defaultAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont(),
            .foregroundColor: foreground,
            .paragraphStyle: bodyParagraphStyle(),
        ]
    }

    /// Default attributes for Plain Source mode. Monospace, lighter line
    /// height, no paragraph spacing — closer to a code editor.
    static var plainSourceAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = 0
        return [
            .font: monospacedFont(size: plainSourceFontSize),
            .foregroundColor: foreground,
            .paragraphStyle: style,
        ]
    }
}

// MARK: - NSColor → CSS hex

extension NSColor {
    /// Returns `#rrggbb` or `#rrggbbaa` CSS hex string.
    var cssHex: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        let a = c.alphaComponent
        if a >= 0.999 {
            return String(format: "#%02x%02x%02x", r, g, b)
        }
        let ai = Int(round(a * 255))
        return String(format: "#%02x%02x%02x%02x", r, g, b, ai)
    }
}
