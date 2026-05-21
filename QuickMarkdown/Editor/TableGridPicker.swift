import AppKit

/// Word/Pages-style hover grid for choosing the dimensions of a new
/// Markdown table. Hosted in an `NSPopover` and anchored to the caret
/// rect inside the editor. The user moves the mouse across the grid to
/// preview a target size, clicks to commit, or presses Escape to cancel.
///
/// Self-contained: the only entry point is the static `present(...)`
/// helper. The popover and view controller are retained by the helper
/// for the duration of the interaction.
@MainActor
enum TableGridPicker {

    /// Maximum dimensions of the picker grid. The user can always type
    /// past these by editing the inserted snippet; the grid is just the
    /// quick path.
    static let maxRows = 8
    static let maxCols = 8

    /// Show the picker anchored to `anchorRect` in `anchorView`'s
    /// coordinate space. `onCommit` is called with (rows, cols) once
    /// the user clicks; both are 1-based and at least 1.
    static func present(in anchorView: NSView,
                        relativeTo anchorRect: NSRect,
                        preferredEdge edge: NSRectEdge = .maxY,
                        onCommit: @escaping (Int, Int) -> Void) {
        let vc = PickerViewController(onCommit: onCommit)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        popover.contentSize = vc.intrinsicSize
        vc.popover = popover
        popover.show(relativeTo: anchorRect, of: anchorView, preferredEdge: edge)
    }
}

@MainActor
private final class PickerViewController: NSViewController {

    weak var popover: NSPopover?

    private let onCommit: (Int, Int) -> Void
    private let grid: GridView

    init(onCommit: @escaping (Int, Int) -> Void) {
        self.onCommit = onCommit
        self.grid = GridView()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    var intrinsicSize: NSSize { grid.intrinsicContentSize }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.onCommit = { [weak self] rows, cols in
            guard let self else { return }
            self.popover?.performClose(nil)
            self.onCommit(rows, cols)
        }
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            grid.topAnchor.constraint(equalTo: root.topAnchor),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.view = root
    }
}

/// The actual hover grid. Drawn in a flipped coordinate system so the
/// math reads top-down. Highlights cells from (1,1) to the current hover
/// position. The footer label reports the current selection ("3 × 4
/// table" or "Pick a size").
@MainActor
private final class GridView: NSView {

    var onCommit: ((Int, Int) -> Void)?

    // Layout
    private let maxRows = TableGridPicker.maxRows
    private let maxCols = TableGridPicker.maxCols
    private let cellSize: CGFloat = 22
    private let cellGap: CGFloat = 3
    private let labelHeight: CGFloat = 22
    private let padding: CGFloat = 12

    // Hover state (1-based; 0 = nothing hovered yet)
    private var hoverRows = 0
    private var hoverCols = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        let w = padding * 2
              + CGFloat(maxCols) * cellSize
              + CGFloat(maxCols - 1) * cellGap
        let h = padding * 2
              + CGFloat(maxRows) * cellSize
              + CGFloat(maxRows - 1) * cellGap
              + labelHeight
        return NSSize(width: w, height: h)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let cellColor   = NSColor(white: 0.85, alpha: 1.0)
        let cellStroke  = NSColor(white: 0.70, alpha: 1.0)
        let pickedFill  = NSColor.controlAccentColor
        let pickedStroke = NSColor.controlAccentColor.blended(withFraction: 0.3,
                                                              of: .black) ?? .controlAccentColor
        let textColor   = NSColor.labelColor

        // Draw each cell.
        for r in 1...maxRows {
            for c in 1...maxCols {
                let cellRect = rectForCell(row: r, col: c)
                let path = NSBezierPath(roundedRect: cellRect, xRadius: 3, yRadius: 3)
                let isPicked = r <= hoverRows && c <= hoverCols
                (isPicked ? pickedFill : cellColor).setFill()
                path.fill()
                (isPicked ? pickedStroke : cellStroke).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        // Footer label.
        let label: String = (hoverRows > 0 && hoverCols > 0)
            ? "\(hoverRows) × \(hoverCols) table"
            : "Pick a size"
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: textColor,
            .paragraphStyle: para,
        ]
        let labelRect = NSRect(
            x: padding,
            y: bounds.height - padding - labelHeight + 4,
            width: bounds.width - padding * 2,
            height: labelHeight
        )
        (label as NSString).draw(in: labelRect, withAttributes: attrs)
    }

    private func rectForCell(row: Int, col: Int) -> NSRect {
        let x = padding + CGFloat(col - 1) * (cellSize + cellGap)
        let y = padding + CGFloat(row - 1) * (cellSize + cellGap)
        return NSRect(x: x, y: y, width: cellSize, height: cellSize)
    }

    private func cellAtPoint(_ p: NSPoint) -> (row: Int, col: Int)? {
        // Outside the grid region (padding margins / footer)?
        let gridLeft = padding
        let gridTop = padding
        let gridRight = padding + CGFloat(maxCols) * cellSize + CGFloat(maxCols - 1) * cellGap
        let gridBottom = padding + CGFloat(maxRows) * cellSize + CGFloat(maxRows - 1) * cellGap
        guard p.x >= gridLeft, p.x <= gridRight,
              p.y >= gridTop, p.y <= gridBottom else { return nil }
        let col = min(maxCols, max(1, Int((p.x - gridLeft) / (cellSize + cellGap)) + 1))
        let row = min(maxRows, max(1, Int((p.y - gridTop) / (cellSize + cellGap)) + 1))
        return (row, col)
    }

    // MARK: - Mouse + keyboard

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        update(hoverFor: p)
    }

    override func mouseEntered(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        update(hoverFor: p)
    }

    override func mouseExited(with event: NSEvent) {
        if hoverRows != 0 || hoverCols != 0 {
            hoverRows = 0
            hoverCols = 0
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (r, c) = cellAtPoint(p) {
            onCommit?(r, c)
        }
    }

    private func update(hoverFor point: NSPoint) {
        if let (r, c) = cellAtPoint(point) {
            if r != hoverRows || c != hoverCols {
                hoverRows = r
                hoverCols = c
                needsDisplay = true
            }
        } else if hoverRows != 0 || hoverCols != 0 {
            hoverRows = 0
            hoverCols = 0
            needsDisplay = true
        }
    }
}
