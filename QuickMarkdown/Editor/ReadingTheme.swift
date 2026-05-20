import AppKit

/// A reading theme controls the background colour and text colour of the
/// document panes (editor + preview). The toolbar, status bar, and window
/// chrome continue to follow the system appearance.
///
/// `.system` is the default — it falls through to the AppKit semantic colours
/// (`labelColor`, `textBackgroundColor`, etc.) so the panes match the system
/// light/dark setting automatically. The other cases pin concrete colours so
/// the user can pick a low-contrast or high-contrast reading surface.
///
/// Marked `Sendable` so the styler (which runs from `NSTextStorage` callbacks
/// that aren't main-actor isolated) can read theme values cheaply. All values
/// are pure functions of the case — there is no mutable state inside the enum.
enum ReadingTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark
    case sepia
    case solarized
    case nightSky

    var displayName: String {
        switch self {
        case .system:    return "System"
        case .light:     return "Light"
        case .dark:      return "Dark"
        case .sepia:     return "Sepia"
        case .solarized: return "Solarized"
        case .nightSky:  return "Night Sky"
        }
    }

    /// `true` when this theme draws on a dark background. For `.system` this
    /// is always `false` — the semantic colours adapt themselves, so we never
    /// need to branch on dark/light when the theme is system.
    var prefersDark: Bool {
        switch self {
        case .system, .light, .sepia:
            return false
        case .dark, .solarized, .nightSky:
            return true
        }
    }

    var background: NSColor {
        switch self {
        case .system:    return .textBackgroundColor
        case .light:     return NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)
        case .dark:      return NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        case .sepia:     return NSColor(srgbRed: 0.98, green: 0.95, blue: 0.86, alpha: 1)
        case .solarized: return NSColor(srgbRed: 0.00, green: 0.17, blue: 0.21, alpha: 1)
        case .nightSky:  return NSColor(srgbRed: 0.07, green: 0.11, blue: 0.22, alpha: 1)
        }
    }

    var foreground: NSColor {
        switch self {
        case .system:    return .labelColor
        case .light:     return NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        case .dark:      return NSColor(srgbRed: 0.92, green: 0.92, blue: 0.93, alpha: 1)
        case .sepia:     return NSColor(srgbRed: 0.30, green: 0.20, blue: 0.10, alpha: 1)
        case .solarized: return NSColor(srgbRed: 0.51, green: 0.58, blue: 0.59, alpha: 1)
        case .nightSky:  return NSColor(srgbRed: 0.94, green: 0.96, blue: 1.00, alpha: 1)
        }
    }

    var secondaryForeground: NSColor {
        switch self {
        case .system: return .secondaryLabelColor
        default:      return foreground.withAlphaComponent(0.65)
        }
    }

    var dimmedMarker: NSColor {
        switch self {
        case .system: return .tertiaryLabelColor
        default:      return foreground.withAlphaComponent(0.35)
        }
    }

    var codeForeground: NSColor {
        switch self {
        case .system: return .labelColor
        default:      return foreground
        }
    }

    var codeBackground: NSColor {
        switch self {
        case .system:
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) == .darkAqua
                    ? NSColor.white.withAlphaComponent(0.06)
                    : NSColor.black.withAlphaComponent(0.04)
            }
        default:
            return prefersDark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.05)
        }
    }

    var blockquoteText: NSColor { secondaryForeground }

    /// Border color for table cells — matches GitHub's #d0d7de.
    var tableBorder: NSColor {
        switch self {
        case .system:
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) == .darkAqua
                    ? NSColor.white.withAlphaComponent(0.25)
                    : NSColor(srgbRed: 0.816, green: 0.843, blue: 0.871, alpha: 1)
            }
        case .light:
            return NSColor(srgbRed: 0.816, green: 0.843, blue: 0.871, alpha: 1)
        case .sepia:
            return NSColor(srgbRed: 0.75, green: 0.68, blue: 0.55, alpha: 1)
        default:
            return NSColor.white.withAlphaComponent(0.25)
        }
    }

    /// Header cell background — matches GitHub's #f6f8fa.
    var tableHeaderBackground: NSColor {
        switch self {
        case .system:
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) == .darkAqua
                    ? NSColor.white.withAlphaComponent(0.08)
                    : NSColor(srgbRed: 0.965, green: 0.973, blue: 0.980, alpha: 1)
            }
        case .light:
            return NSColor(srgbRed: 0.965, green: 0.973, blue: 0.980, alpha: 1)
        case .sepia:
            return NSColor(srgbRed: 0.94, green: 0.90, blue: 0.80, alpha: 1)
        default:
            return NSColor.white.withAlphaComponent(0.08)
        }
    }

    /// Alternating row stripe for table body rows.
    var tableStripe: NSColor {
        switch self {
        case .system:
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) == .darkAqua
                    ? NSColor.white.withAlphaComponent(0.04)
                    : NSColor(srgbRed: 0.965, green: 0.973, blue: 0.980, alpha: 1)
            }
        case .light:
            return NSColor(srgbRed: 0.965, green: 0.973, blue: 0.980, alpha: 1)
        case .sepia:
            return NSColor(srgbRed: 0.96, green: 0.93, blue: 0.84, alpha: 1)
        default:
            return NSColor.white.withAlphaComponent(0.04)
        }
    }

    var linkColor: NSColor {
        switch self {
        case .system:    return .linkColor
        case .sepia:     return NSColor(srgbRed: 0.55, green: 0.30, blue: 0.10, alpha: 1)
        case .solarized: return NSColor(srgbRed: 0.15, green: 0.55, blue: 0.82, alpha: 1)
        case .nightSky:  return NSColor(srgbRed: 0.55, green: 0.78, blue: 1.00, alpha: 1)
        case .light:     return NSColor(srgbRed: 0.00, green: 0.40, blue: 0.85, alpha: 1)
        case .dark:      return NSColor(srgbRed: 0.45, green: 0.72, blue: 1.00, alpha: 1)
        }
    }

    /// Caret colour for the editor under this theme.
    var insertionPoint: NSColor {
        switch self {
        case .system: return .textColor
        default:      return foreground
        }
    }
}

// MARK: - Reading font family

/// Font family the user has chosen for document content. The toolbar /
/// status bar / menu chrome always use the AppKit system font; only the
/// editor and preview text honour this setting.
enum ReadingFontFamily: String, CaseIterable, Sendable {
    case system
    case serif
    case rounded
    case dyslexic

    var displayName: String {
        switch self {
        case .system:   return "System"
        case .serif:    return "Serif"
        case .rounded:  return "Rounded"
        case .dyslexic: return "Dyslexia-Friendly"
        }
    }

    /// Returns `false` when no concrete font is installed for this family
    /// (currently only relevant for `.dyslexic`). The toolbar menu greys
    /// the item out when this is `false`.
    var isAvailable: Bool {
        switch self {
        case .system, .serif, .rounded:
            return true
        case .dyslexic:
            return Self.dyslexicFontName() != nil
        }
    }

    /// Concrete font name for `.dyslexic`, or `nil` if none of the dedicated
    /// dyslexia-friendly fonts are installed. We deliberately do NOT fall
    /// back to general-purpose fonts like Comic Sans — if the user picks
    /// "Dyslexia-Friendly" they should get an actual dyslexia-friendly font
    /// (or have the option greyed out).
    static func dyslexicFontName() -> String? {
        let candidates = ["OpenDyslexic", "OpenDyslexic-Regular",
                          "OpenDyslexic3", "Dyslexie", "Lexie Readable"]
        for name in candidates {
            if NSFont(name: name, size: 12) != nil {
                return name
            }
        }
        return nil
    }

    func body(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        switch self {
        case .system:
            return .systemFont(ofSize: size, weight: weight)
        case .serif:
            let base = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body)
            if let designed = base.withDesign(.serif) {
                let traited = designed.addingAttributes([
                    .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
                ])
                if let f = NSFont(descriptor: traited, size: size) { return f }
            }
            return NSFont(name: "Georgia", size: size)
                ?? .systemFont(ofSize: size, weight: weight)
        case .rounded:
            let base = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body)
            if let designed = base.withDesign(.rounded) {
                let traited = designed.addingAttributes([
                    .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
                ])
                if let f = NSFont(descriptor: traited, size: size) { return f }
            }
            return .systemFont(ofSize: size, weight: weight)
        case .dyslexic:
            if let name = Self.dyslexicFontName(),
               let f = NSFont(name: name, size: size) {
                return f
            }
            return .systemFont(ofSize: size, weight: weight)
        }
    }

    func mono(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        // Monospace is always system mono — readable code matters more than
        // theme consistency for `inline code` and fenced blocks.
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Persistent reading preferences

/// Process-wide reading preferences (theme + font). Persisted to
/// `UserDefaults`. Mutations post `didChangeNotification` on the main queue
/// so the editor and preview can repaint.
///
/// Reads are atomic enum-value copies — any thread (including the
/// non-main-actor styler) can call `shared.theme` / `shared.fontFamily`
/// without locking. Mutations are expected to happen on the main thread:
/// they come from toolbar UI callbacks.
final class ReadingPreferences: @unchecked Sendable {

    static let shared = ReadingPreferences()

    /// Posted on the main queue whenever the theme or font family changes.
    static let didChangeNotification =
        Notification.Name("QuickMarkdownReadingPreferencesDidChange")

    private static let themeKey = "QM.ReadingTheme"
    private static let fontKey  = "QM.ReadingFont"

    private var _theme: ReadingTheme
    private var _fontFamily: ReadingFontFamily

    var theme: ReadingTheme { _theme }
    var fontFamily: ReadingFontFamily { _fontFamily }

    private init() {
        let defaults = UserDefaults.standard
        let themeRaw = defaults.string(forKey: Self.themeKey) ?? ReadingTheme.system.rawValue
        let fontRaw  = defaults.string(forKey: Self.fontKey)  ?? ReadingFontFamily.system.rawValue
        self._theme      = ReadingTheme(rawValue: themeRaw) ?? .system
        self._fontFamily = ReadingFontFamily(rawValue: fontRaw) ?? .system
        if !self._fontFamily.isAvailable {
            self._fontFamily = .system
        }
    }

    func setTheme(_ theme: ReadingTheme) {
        guard theme != self._theme else { return }
        self._theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
        post()
    }

    func setFontFamily(_ family: ReadingFontFamily) {
        guard family != self._fontFamily else { return }
        guard family.isAvailable else { return }
        self._fontFamily = family
        UserDefaults.standard.set(family.rawValue, forKey: Self.fontKey)
        post()
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
