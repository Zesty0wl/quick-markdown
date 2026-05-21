import AppKit

/// Loads local image files (PNG/JPEG/GIF/TIFF/SVG/PDF) for inline display in
/// the rendered preview, returning an `NSTextAttachment` that flows with the
/// surrounding text and resizes to fit the text container width.
///
/// **Scope:** local files only. Remote URLs (`http://`, `https://`) return
/// `nil` so the caller can fall back to a `[Image]` text placeholder.
///
/// Loaded `NSImage` instances are cached in-process keyed by absolute file
/// URL so theme rebuilds and quick mode flips don't hit the disk repeatedly.
@MainActor
enum ImageLoader {

    /// Maximum pixel size we'll ever rasterise into an attachment. Markdown
    /// images authored at 4K+ source resolution would otherwise eat large
    /// chunks of RAM per occurrence.
    private static let maxPixelSize: CGFloat = 2048

    /// Fallback size (in points) used when an SVG reports a zero intrinsic
    /// size. The attachment-bounds logic will still scale this down to fit
    /// the text container width.
    private static let svgFallbackSize = NSSize(width: 600, height: 360)

    private static var cache: [URL: NSImage] = [:]

    /// Drop all cached images. Called by the document window controller
    /// when its `MediaWatcher` detects a sibling-asset change so the next
    /// render fetches fresh bytes from disk instead of serving the stale
    /// in-process copy.
    static func clearCache() {
        cache.removeAll()
    }

    /// Resolves `source` against the document's containing folder and, if
    /// the resulting URL points at a readable image file, returns a flowing
    /// `NSTextAttachment` ready to be wrapped in an `NSAttributedString`.
    ///
    /// `alt` is attached as the attachment's tool tip / accessibility label.
    static func attachment(source: String,
                           alt: String?,
                           baseURL: URL?) -> NSTextAttachment? {
        guard let url = resolveLocalURL(source: source, baseURL: baseURL) else {
            return nil
        }
        guard let image = loadImage(at: url) else { return nil }
        let attachment = FlowingImageAttachment()
        attachment.image = image
        attachment.intrinsicPointSize = image.size == .zero ? svgFallbackSize : image.size
        // Tool-tip / a11y label is set on the surrounding attributed-string
        // run by the renderer (NSTextAttachment itself has no accessor for
        // it on macOS).
        return attachment
    }

    // MARK: - URL resolution

    private static func resolveLocalURL(source: String, baseURL: URL?) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Reject obvious remote schemes up front.
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" || scheme == "data" {
            return nil
        }

        // Absolute file URL.
        if trimmed.hasPrefix("file://"),
           let url = URL(string: trimmed) {
            return url
        }

        // Absolute POSIX path.
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        // Anything else is relative — needs a baseURL to be meaningful.
        guard let baseURL else { return nil }
        // Normalise the path: decode any existing percent-encoding (so a
        // pre-encoded `media/night%20sky.png` becomes `media/night sky.png`)
        // then re-encode for URL parsing. Without the decode step the
        // leading `%` would itself be percent-encoded to `%25`, yielding
        // `%2520` and a file that doesn't exist on disk.
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let encoded = decoded.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? trimmed
        if let resolved = URL(string: encoded, relativeTo: baseURL)?.absoluteURL,
           resolved.isFileURL {
            return resolved
        }
        // Last resort: treat as a path fragment from the doc's folder.
        return baseURL.appendingPathComponent(decoded)
    }

    // MARK: - Loading

    private static func loadImage(at url: URL) -> NSImage? {
        if let cached = cache[url] { return cached }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return nil
        }

        // SVG: route through WebKit. macOS's built-in CoreSVG decoder
        // mis-positions multi-line `<text>`+`<tspan dy>` runs with
        // `text-anchor="middle"` (labels overlap), and WebKit gets it
        // right. See SVGRasterizer for the full rationale.
        if url.pathExtension.lowercased() == "svg" {
            if let rasterized = SVGRasterizer.rasterize(url: url) {
                cache[url] = rasterized
                return rasterized
            }
            // Fall through to the system decoder on failure so the user
            // sees *something* rather than a missing-image placeholder.
        }

        guard let image = NSImage(contentsOf: url) else { return nil }
        // Downscale absurdly large raster sources so they don't bloat the
        // text storage's drawing cost. SVG/PDF report point sizes already.
        if image.size.width > maxPixelSize || image.size.height > maxPixelSize {
            let scale = maxPixelSize / max(image.size.width, image.size.height)
            image.size = NSSize(width: floor(image.size.width * scale),
                                height: floor(image.size.height * scale))
        }
        cache[url] = image
        return image
    }
}

/// `NSTextAttachment` subclass that flows with the surrounding text: it
/// reports an attachment bounds that fits within the current text container
/// width, scaling down (never up) and preserving aspect ratio. Vertical
/// centring is left to the layout manager; we anchor at the baseline.
final class FlowingImageAttachment: NSTextAttachment {

    /// Natural point size of the underlying image. Used as the upper bound
    /// when the text container is wider than the image.
    var intrinsicPointSize: NSSize = .zero

    /// Right-edge padding inside the text container so images don't kiss
    /// the scrollbar gutter.
    private let trailingPadding: CGFloat = 8

    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        let available = max(0,
            (textContainer?.size.width ?? lineFrag.width) - trailingPadding
        )
        let natural = intrinsicPointSize == .zero ? (image?.size ?? .zero) : intrinsicPointSize
        guard natural.width > 0, natural.height > 0 else {
            return CGRect(x: 0, y: 0, width: available, height: 0)
        }
        let scale = natural.width > available ? available / natural.width : 1.0
        return CGRect(x: 0,
                      y: 0,
                      width: floor(natural.width * scale),
                      height: floor(natural.height * scale))
    }
}
