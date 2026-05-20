import AppKit

/// Non-modal banner shown when a document's file changed on disk while the
/// user had unsaved local edits. Two actions: Reload or Keep my changes.
///
/// Slides down from the top of the editor container. The window controller
/// owns and shows/hides instances of this view.
final class ReloadBannerView: NSView {

    var onReload: (() -> Void)?
    var onKeep: (() -> Void)?

    private let label = NSTextField(labelWithString:
        "This file was changed outside Quick Markdown.")
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let keepButton = NSButton(title: "Keep my changes",
                                      target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.15).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.bezelStyle = .rounded
        reloadButton.controlSize = .regular
        reloadButton.keyEquivalent = "\r"
        reloadButton.target = self
        reloadButton.action = #selector(reloadClicked)
        addSubview(reloadButton)

        keepButton.translatesAutoresizingMaskIntoConstraints = false
        keepButton.bezelStyle = .rounded
        keepButton.controlSize = .regular
        keepButton.target = self
        keepButton.action = #selector(keepClicked)
        addSubview(keepButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: keepButton.leadingAnchor, constant: -12),

            keepButton.trailingAnchor.constraint(
                equalTo: reloadButton.leadingAnchor, constant: -8),
            keepButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            reloadButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -16),
            reloadButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        // NOTE: the banner's height is controlled by its OWNER
        // (`DocumentWindowController.bannerHeightConstraint`) so it can
        // animate between 0 and 36. We deliberately do not pin a height
        // here to avoid a constraint conflict.
    }

    required init?(coder: NSCoder) { nil }

    @objc private func reloadClicked() { onReload?() }
    @objc private func keepClicked() { onKeep?() }
}
