import AppKit
import WebKit

/// Renders an SVG file to an `NSImage` by loading it inside an offscreen
/// `WKWebView` and snapshotting the rendered surface.
///
/// **Why not just `NSImage(contentsOf:)`?** macOS's built-in SVG decoder
/// (CoreSVG, also used by `QLThumbnailGenerator.generateBestRepresentation`)
/// mis-lays-out `<text>` elements that use `<tspan dy="…">` line breaks with
/// `text-anchor="middle"`: every tspan is offset horizontally past the
/// previous one instead of being placed below it, so multi-line labels
/// in tightly-packed cards overlap badly. WebKit's renderer (the one Safari
/// and the real Quick Look plug-in use) handles those SVGs correctly.
///
/// The pipeline is deliberately synchronous-with-a-spinning-runloop so the
/// rest of the rendering code stays straightforward: we kick off the
/// navigation, then `RunLoop.main.run(until:)` until the snapshot callback
/// fires or our budget elapses. First-render-of-a-doc cost is the WebKit
/// startup hit (~150 ms on Apple Silicon); subsequent renders hit
/// `ImageLoader`'s cache and pay nothing.
@MainActor
enum SVGRasterizer {

    /// Maximum time we'll block the main runloop waiting for any single
    /// SVG to render. If we exceed this, the caller falls back to
    /// `NSImage(contentsOf:)` and the user sees the (broken) CoreSVG
    /// result rather than a missing-image placeholder.
    private static let renderBudget: TimeInterval = 3.0

    /// Default pixel dimensions used when an SVG declares neither
    /// `viewBox` nor explicit width/height.
    private static let fallbackSize = NSSize(width: 1200, height: 800)

    /// Renders the SVG at `url` to a backing-store-resolution `NSImage`
    /// (rendered at 2× the SVG's intrinsic point size so it stays crisp
    /// on Retina), or `nil` if the file can't be read, parsed, or
    /// snapshotted within the render budget.
    static func rasterize(url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url),
              let svgString = String(data: data, encoding: .utf8) else {
            return nil
        }

        let intrinsic = parseIntrinsicSize(from: svgString) ?? fallbackSize

        // We size the document to the SVG's intrinsic point size and let
        // WebKit lay it out. The snapshot itself is taken at 2× via
        // `WKSnapshotConfiguration.snapshotWidth` so the result holds up
        // when scaled down later for narrower text containers.
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: transparent;
                       width: \(Int(intrinsic.width))px;
                       height: \(Int(intrinsic.height))px;
                       overflow: hidden; }
          svg { display: block;
                width: \(Int(intrinsic.width))px;
                height: \(Int(intrinsic.height))px; }
        </style>
        </head><body>\(svgString)</body></html>
        """

        let frame = NSRect(origin: .zero, size: intrinsic)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        // Transparent background so the SVG composites cleanly on whatever
        // theme background the preview is using.
        webView.setValue(false, forKey: "drawsBackground")

        var snapshot: NSImage?
        var finished = false

        let delegate = SnapshotDelegate { image in
            // `snapshotWidth = 2 * intrinsic.width` makes WebKit render a
            // 2× bitmap, but it also bakes that 2× into NSImage.size (so a
            // 1200×290 SVG comes back as a 2400×580 *point*-sized NSImage).
            // TextKit uses NSImage.size to lay out the line height for an
            // attachment, so leaving it at 2× produces ~320pt of empty
            // trailing space below the visible image. Pin the point size
            // back to the SVG's intrinsic size — the underlying bitmap rep
            // keeps its 2× pixel resolution and Retina sharpness.
            if let image, image.size != intrinsic {
                image.size = intrinsic
            }
            snapshot = image
            finished = true
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())

        let deadline = Date().addingTimeInterval(renderBudget)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        // Keep `delegate` alive until the wait loop exits.
        withExtendedLifetime(delegate) {}
        // Stop the webview so any pending callbacks don't fire after we
        // return (the snapshot, if any, has already been captured).
        webView.stopLoading()
        webView.navigationDelegate = nil

        return snapshot
    }

    // MARK: - SVG metadata parsing

    /// Pulls the intrinsic point size out of the SVG. We prefer the
    /// `viewBox` (which gives us width/height in user units) and fall
    /// back to the root `<svg>` element's `width`/`height` attributes.
    private static func parseIntrinsicSize(from svg: String) -> NSSize? {
        // Find the opening `<svg ...>` element specifically and only look
        // at its attributes. We can't just take everything before the
        // first `>` — many real-world SVGs start with an `<?xml ?>` XML
        // declaration, whose closing `?>` would otherwise truncate us
        // before we ever reach the `<svg>` tag itself.
        let openTag: Substring
        if let svgStart = svg.range(of: "<svg", options: .caseInsensitive),
           let svgEnd = svg.range(of: ">", range: svgStart.upperBound..<svg.endIndex) {
            openTag = svg[svgStart.lowerBound..<svgEnd.upperBound]
        } else if let end = svg.range(of: ">") {
            openTag = svg[svg.startIndex..<end.upperBound]
        } else {
            openTag = Substring(svg)
        }
        let tagString = String(openTag)

        let viewBoxPattern = #"viewBox\s*=\s*['"]\s*[\d.+\-eE]+\s+[\d.+\-eE]+\s+([\d.+\-eE]+)\s+([\d.+\-eE]+)\s*['"]"#
        if let regex = try? NSRegularExpression(pattern: viewBoxPattern),
           let match = regex.firstMatch(in: tagString,
                                        range: NSRange(tagString.startIndex..., in: tagString)),
           match.numberOfRanges == 3,
           let wRange = Range(match.range(at: 1), in: tagString),
           let hRange = Range(match.range(at: 2), in: tagString),
           let w = Double(tagString[wRange]),
           let h = Double(tagString[hRange]),
           w > 0, h > 0 {
            return NSSize(width: w, height: h)
        }

        let dimPattern = #"\b%@\s*=\s*['"]([\d.+\-eE]+)(?:px)?['"]"#
        func attr(_ name: String) -> Double? {
            let pattern = String(format: dimPattern, name)
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: tagString,
                                               range: NSRange(tagString.startIndex..., in: tagString)),
                  match.numberOfRanges == 2,
                  let range = Range(match.range(at: 1), in: tagString) else {
                return nil
            }
            return Double(tagString[range])
        }
        if let w = attr("width"), let h = attr("height"), w > 0, h > 0 {
            return NSSize(width: w, height: h)
        }
        return nil
    }
}

/// Internal navigation delegate that takes a snapshot on first finish and
/// reports either the image or `nil` on failure. We give the layout a tiny
/// async cushion before snapshotting so CSS layout and font fallback have
/// settled — without it, the first snapshot occasionally captures a blank
/// frame on cold WebKit init.
private final class SnapshotDelegate: NSObject, WKNavigationDelegate {

    private let completion: @MainActor (NSImage?) -> Void
    private var fired = false

    init(_ completion: @escaping @MainActor (NSImage?) -> Void) {
        self.completion = completion
        super.init()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !fired else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak webView] in
            guard let self, let webView, !self.fired else { return }
            let cfg = WKSnapshotConfiguration()
            cfg.rect = webView.bounds
            cfg.snapshotWidth = NSNumber(value: Double(webView.bounds.width * 2))
            webView.takeSnapshot(with: cfg) { image, _ in
                guard !self.fired else { return }
                self.fired = true
                self.completion(image)
            }
        }
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        guard !fired else { return }
        fired = true
        completion(nil)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard !fired else { return }
        fired = true
        completion(nil)
    }
}
