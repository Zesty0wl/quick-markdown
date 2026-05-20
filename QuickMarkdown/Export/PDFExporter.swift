import AppKit
import PDFKit
import WebKit

/// Generates a paginated A4 PDF from a Markdown source string by rendering
/// the HTML in an offscreen `WKWebView`, asking WebKit for a single tall PDF
/// representation, and then slicing it into A4 pages with uniform margins via
/// a fresh `CGPDFContext` (PRD §7.3).
///
/// Images embedded in the source Markdown are inlined as `data:` URLs by
/// `HTMLRenderer` so the PDF carries the image bytes regardless of where the
/// file is saved or the app's sandbox configuration.
///
/// Lifecycle: instances retain themselves until the PDF is delivered or an
/// error occurs, then drop the strong reference.
@MainActor
final class PDFExporter: NSObject, WKNavigationDelegate {

    // A4 portrait page dimensions in points (1 pt == 1/72 inch).
    private static let pageWidth: CGFloat = 595
    private static let pageHeight: CGFloat = 842
    /// 0.5 inch margin on all four sides.
    private static let pageMargin: CGFloat = 36
    private static var contentWidth: CGFloat { pageWidth - 2 * pageMargin }
    private static var contentHeight: CGFloat { pageHeight - 2 * pageMargin }

    /// Scale applied when blitting the source PDF into the printable area.
    /// `HTMLRenderer`'s CSS is tuned for on-screen display (16 px body, 32 px
    /// h1). Because WebKit maps 1 CSS px to 1 PDF pt, those values are
    /// print-large at 1:1. Rendering the source PDF at a larger virtual width
    /// and scaling down at draw time yields print-sized typography
    /// (16 px ÷ 0.7 ≈ 11.2 pt body, 32 px ÷ 0.7 ≈ 22.4 pt h1) without
    /// touching the shared HTML renderer used for the preview and paste.
    private static let renderScale: CGFloat = 0.7
    private static var renderContentWidth: CGFloat { contentWidth / renderScale }
    private static var renderContentHeight: CGFloat { contentHeight / renderScale }

    private let webView: WKWebView
    private let completion: @MainActor (Result<Data, Error>) -> Void
    private var strongSelf: PDFExporter?

    private init(completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        let config = WKWebViewConfiguration()
        // Lay out at the *render* content width (wider than the A4 printable
        // area). The paginator scales each slice down by `renderScale` when
        // drawing it into the page, which shrinks the on-screen-sized
        // typography to print sizes.
        let frame = NSRect(x: 0, y: 0,
                           width: Self.renderContentWidth,
                           height: Self.pageHeight)
        self.webView = WKWebView(frame: frame, configuration: config)
        self.completion = completion
        super.init()
        webView.navigationDelegate = self
    }

    /// Asynchronously generate PDF data for the supplied Markdown.
    ///
    /// - Parameters:
    ///   - markdownSource: The raw Markdown source.
    ///   - baseURL: Folder used to resolve relative image references so they
    ///     can be inlined as `data:` URLs.
    static func generate(markdownSource: String,
                         baseURL: URL? = nil,
                         completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        let exporter = PDFExporter(completion: completion)
        exporter.strongSelf = exporter
        let html = HTMLRenderer.renderDocument(markdownSource, baseURL: baseURL)
        // The renderer's body uses `max-width:740px;margin:0 auto;` which is
        // fine inside the 523pt content viewport — the auto margins collapse
        // to zero so content fills the printable area edge-to-edge.
        exporter.webView.loadHTMLString(html, baseURL: baseURL)
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            await self.measureAndExport()
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.deliver(.failure(error))
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.deliver(.failure(error))
        }
    }

    private func measureAndExport() async {
        do {
            let result = try await webView.evaluateJavaScript(
                "document.body.scrollHeight"
            )
            let height: CGFloat = Self.coerceHeight(result)
            let noSplit = try await collectNoSplitBoxes()
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: 0,
                                 width: Self.renderContentWidth,
                                 height: max(height, 200))
            let tallPDF = try await webView.pdf(configuration: config)
            let paginated = Self.paginate(tallPDF: tallPDF,
                                          noSplitBoxes: noSplit) ?? tallPDF
            deliver(.success(paginated))
        } catch {
            deliver(.failure(error))
        }
    }

    /// Rectangles in document-top coordinates (Y=0 at top of body, increasing
    /// downward) for elements we should keep on a single page when possible.
    /// `isHeading` boxes get a small trailing lookahead so we don't orphan a
    /// heading at the bottom of a page.
    private struct NoSplitBox {
        let top: CGFloat
        let bottom: CGFloat
        let isHeading: Bool
    }

    /// Ask the rendered DOM for the Y-extent of every block element we'd
    /// rather not split across pages. Coordinates are CSS px, which map 1:1
    /// to PDF points because the offscreen webView is laid out at the same
    /// width as `WKPDFConfiguration.rect` with no scaling.
    private func collectNoSplitBoxes() async throws -> [NoSplitBox] {
        let js = """
        (function() {
            var sel = 'img, pre, table, blockquote, h1, h2, h3, h4, h5, h6';
            var els = document.querySelectorAll(sel);
            var out = [];
            for (var i = 0; i < els.length; i++) {
                var r = els[i].getBoundingClientRect();
                out.push({
                    top: r.top + window.scrollY,
                    bottom: r.bottom + window.scrollY,
                    heading: /^H[1-6]$/.test(els[i].tagName)
                });
            }
            return JSON.stringify(out);
        })();
        """
        let result = try await webView.evaluateJavaScript(js)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data)
                as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { dict in
            guard let top = (dict["top"] as? NSNumber)?.doubleValue,
                  let bottom = (dict["bottom"] as? NSNumber)?.doubleValue,
                  bottom > top else {
                return nil
            }
            let isHeading = (dict["heading"] as? NSNumber)?.boolValue ?? false
            return NoSplitBox(top: CGFloat(top),
                              bottom: CGFloat(bottom),
                              isHeading: isHeading)
        }
    }

    /// Slice a single tall PDF page into A4 pages with uniform margins. Page
    /// breaks are nudged upward when they would cut through a no-split box
    /// (image, code block, table, blockquote, or a heading paired with the
    /// first few lines below it). Returns nil on failure so callers can fall
    /// back to the source PDF.
    private static func paginate(tallPDF: Data,
                                 noSplitBoxes: [NoSplitBox]) -> Data? {
        guard let src = PDFDocument(data: tallPDF),
              let srcPage = src.page(at: 0),
              let srcRef = srcPage.pageRef else {
            return nil
        }
        let srcBounds = srcPage.bounds(for: .mediaBox)
        let srcHeight = srcBounds.height

        // Headings get a small lookahead so they don't sit alone at the
        // bottom of a page; if there's less than `headingLookahead` of room
        // below a heading on the current page, the heading is pushed down.
        let headingLookahead: CGFloat = 64
        let avoidBoxes: [NoSplitBox] = noSplitBoxes.map { box in
            guard box.isHeading else { return box }
            return NoSplitBox(top: box.top,
                              bottom: min(srcHeight,
                                          box.bottom + headingLookahead),
                              isHeading: true)
        }

        // Compute page break Y positions in document-top coordinates. The
        // source PDF is laid out at `renderContentWidth`, so a full page maps
        // to `renderContentHeight` of source PDF (it scales down to
        // `contentHeight` of printable area at draw time).
        var breaks: [CGFloat] = [0]
        let snapEpsilon: CGFloat = 0.5
        while let last = breaks.last, last < srcHeight - snapEpsilon {
            var candidate = min(last + renderContentHeight, srcHeight)
            // Snap upward to avoid cutting through any no-split box that
            // fits within a page and starts after the current top.
            for box in avoidBoxes {
                let boxHeight = box.bottom - box.top
                guard boxHeight <= renderContentHeight else { continue }
                guard box.top > last,
                      box.top < candidate,
                      box.bottom > candidate else { continue }
                candidate = min(candidate, box.top)
            }
            // Safety: never produce a zero-height slice. If snapping would
            // collapse this page, accept a cut and take a full slice.
            if candidate <= last + 1 {
                candidate = min(last + renderContentHeight, srcHeight)
            }
            breaks.append(candidate)
        }

        let outData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: outData as CFMutableData),
              let ctx = CGContext(consumer: consumer,
                                  mediaBox: &mediaBox,
                                  nil) else {
            return nil
        }

        for i in 0..<(breaks.count - 1) {
            let top = breaks[i]
            let bottom = breaks[i + 1]
            let sliceHeight = bottom - top                 // source-PDF pt
            let outSliceHeight = sliceHeight * renderScale // output (A4) pt
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // Clip to the slice rect at the top of the printable area so that
            // a snapped (short) page doesn't bleed source content below the
            // slice into what should be whitespace. Heights are in output
            // coords because clipping happens before the scale below.
            ctx.clip(to: CGRect(x: pageMargin,
                                y: pageHeight - pageMargin - outSliceHeight,
                                width: contentWidth,
                                height: outSliceHeight))
            // PDF coordinates are bottom-left. Build the CTM in three steps
            // (applied to drawn content in reverse order of code):
            //   1. translate so the slice's bottom-left lands at
            //      (pageMargin, pageHeight - pageMargin - outSliceHeight),
            //   2. scale by renderScale so source pt → output pt,
            //   3. translate the source page so its source-PDF y =
            //      (srcHeight - bottom) sits at the local origin.
            ctx.translateBy(x: pageMargin,
                            y: pageHeight - pageMargin - outSliceHeight)
            ctx.scaleBy(x: renderScale, y: renderScale)
            ctx.translateBy(x: 0, y: -(srcHeight - bottom))
            ctx.drawPDFPage(srcRef)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return outData as Data
    }

    private static func coerceHeight(_ value: Any?) -> CGFloat {
        if let n = value as? NSNumber {
            return CGFloat(n.doubleValue)
        }
        if let d = value as? Double {
            return CGFloat(d)
        }
        if let i = value as? Int {
            return CGFloat(i)
        }
        return 842
    }

    private func deliver(_ result: Result<Data, Error>) {
        completion(result)
        strongSelf = nil
    }
}
