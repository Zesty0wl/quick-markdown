import AppKit

/// Builds the main menu programmatically. Phase 3 introduces a minimal menu
/// bar with File/Edit/View basics, including `View > Toggle Preview / Source`.
/// Phase 6 will flesh out Edit, Format, Window, and Help.
enum MainMenuBuilder {

    @MainActor
    static func install() {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(formatMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(windowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    // MARK: - App menu

    @MainActor
    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Quick Markdown")
        let appName = ProcessInfo.processInfo.processName

        menu.addItem(withTitle: "About \(appName)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        let checkForUpdates = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: #selector(UpdateChecker.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = UpdateChecker.shared
        menu.addItem(checkForUpdates)
        menu.addItem(.separator())

        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide \(appName)",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: - File menu

    @MainActor
    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New",
                     action: #selector(NSDocumentController.newDocument(_:)),
                     keyEquivalent: "n")
        menu.addItem(withTitle: "Open…",
                     action: #selector(NSDocumentController.openDocument(_:)),
                     keyEquivalent: "o")
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = RecentDocumentsMenuDelegate.shared
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        menu.addItem(withTitle: "Save…",
                     action: #selector(NSDocument.save(_:)),
                     keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Save As…",
                                action: #selector(NSDocument.saveAs(_:)),
                                keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(saveAs)
        menu.addItem(withTitle: "Revert to Saved",
                     action: #selector(NSDocument.revertToSaved(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        let exportPDF = NSMenuItem(
            title: "Export as PDF…",
            action: #selector(DocumentWindowController.exportAsPDF(_:)),
            keyEquivalent: "e"
        )
        exportPDF.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(exportPDF)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Page Setup…",
                     action: #selector(NSDocument.runPageLayout(_:)),
                     keyEquivalent: "P")
        let print = NSMenuItem(title: "Print…",
                               action: #selector(DocumentWindowController.printDocument(_:)),
                               keyEquivalent: "p")
        menu.addItem(print)

        item.submenu = menu
        return item
    }

    // MARK: - Edit menu

    @MainActor
    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo",
                     action: Selector(("undo:")),
                     keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut",
                     action: #selector(NSText.cut(_:)),
                     keyEquivalent: "x")
        menu.addItem(withTitle: "Copy",
                     action: #selector(NSText.copy(_:)),
                     keyEquivalent: "c")
        let copyFormatted = NSMenuItem(
            title: "Copy Formatted",
            action: #selector(DocumentWindowController.copyFormatted(_:)),
            keyEquivalent: "c"
        )
        copyFormatted.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(copyFormatted)
        menu.addItem(withTitle: "Paste",
                     action: #selector(NSText.paste(_:)),
                     keyEquivalent: "v")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        menu.addItem(.separator())
        let findSubmenu = NSMenu(title: "Find")
        findSubmenu.addItem(withTitle: "Find…",
                            action: #selector(NSResponder.performTextFinderAction(_:)),
                            keyEquivalent: "f").tag = NSTextFinder.Action.showFindInterface.rawValue
        findSubmenu.addItem(withTitle: "Find Next",
                            action: #selector(NSResponder.performTextFinderAction(_:)),
                            keyEquivalent: "g").tag = NSTextFinder.Action.nextMatch.rawValue
        findSubmenu.addItem(withTitle: "Find Previous",
                            action: #selector(NSResponder.performTextFinderAction(_:)),
                            keyEquivalent: "G").tag = NSTextFinder.Action.previousMatch.rawValue
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = findSubmenu
        menu.addItem(findItem)

        menu.addItem(.separator())
        let speechSubmenu = NSMenu(title: "Speech")
        let startSpeaking = NSMenuItem(
            title: "Start Speaking",
            action: #selector(DocumentWindowController.startSpeaking(_:)),
            keyEquivalent: "."
        )
        startSpeaking.keyEquivalentModifierMask = [.command, .option]
        speechSubmenu.addItem(startSpeaking)
        let stopSpeaking = NSMenuItem(
            title: "Stop Speaking",
            action: #selector(DocumentWindowController.stopSpeaking(_:)),
            keyEquivalent: "."
        )
        stopSpeaking.keyEquivalentModifierMask = [.command, .control]
        speechSubmenu.addItem(stopSpeaking)
        let pauseSpeaking = NSMenuItem(
            title: "Pause Speaking",
            action: #selector(DocumentWindowController.togglePauseSpeaking(_:)),
            keyEquivalent: ""
        )
        speechSubmenu.addItem(pauseSpeaking)
        let speechItem = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
        speechItem.submenu = speechSubmenu
        menu.addItem(speechItem)

        item.submenu = menu
        return item
    }

    // MARK: - Format menu (Phase 6)

    @MainActor
    private static func formatMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Format")

        menu.addItem(menuItem("Bold",
                              action: #selector(EditorViewController.formatBold(_:)),
                              key: "b"))
        menu.addItem(menuItem("Italic",
                              action: #selector(EditorViewController.formatItalic(_:)),
                              key: "i"))
        menu.addItem(menuItem("Code",
                              action: #selector(EditorViewController.formatCode(_:)),
                              key: "e"))
        menu.addItem(menuItem("Link",
                              action: #selector(EditorViewController.formatLink(_:)),
                              key: "k"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Heading 1",
                              action: #selector(EditorViewController.formatHeading1(_:)),
                              key: "1",
                              modifiers: [.command, .option]))
        menu.addItem(menuItem("Heading 2",
                              action: #selector(EditorViewController.formatHeading2(_:)),
                              key: "2",
                              modifiers: [.command, .option]))
        menu.addItem(menuItem("Heading 3",
                              action: #selector(EditorViewController.formatHeading3(_:)),
                              key: "3",
                              modifiers: [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(menuItem("Insert Code Block",
                              action: #selector(EditorViewController.insertCodeBlock(_:)),
                              key: "k",
                              modifiers: [.command, .shift]))
        menu.addItem(menuItem("Insert Table…",
                              action: #selector(EditorViewController.insertTable(_:)),
                              key: "t",
                              modifiers: [.command, .option]))
        menu.addItem(menuItem("Realign Tables",
                              action: #selector(EditorViewController.realignTables(_:)),
                              key: "t",
                              modifiers: [.command, .option, .control]))
        menu.addItem(menuItem("Toggle Task",
                              action: #selector(EditorViewController.toggleTask(_:)),
                              key: "t",
                              modifiers: [.command, .shift]))

        item.submenu = menu
        return item
    }

    @MainActor
    private static func menuItem(_ title: String,
                                 action: Selector,
                                 key: String,
                                 modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    // MARK: - View menu

    @MainActor
    private static func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        let toggle = NSMenuItem(
            title: "Toggle Preview / Source",
            action: #selector(DocumentWindowController.toggleWindowMode(_:)),
            keyEquivalent: "p"
        )
        toggle.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Toolbar",
                     action: #selector(NSWindow.toggleToolbarShown(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Enter Full Screen",
                     action: #selector(NSWindow.toggleFullScreen(_:)),
                     keyEquivalent: "f")
        item.submenu = menu
        return item
    }

    // MARK: - Window menu

    @MainActor
    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}

// MARK: - Open Recent delegate

/// Populates the "Open Recent" submenu from `NSDocumentController`'s
/// tracked URLs. AppKit's built-in auto-population relies on internal
/// menu-name tagging that only works reliably for NIB-built menus, so
/// we drive it explicitly via `NSMenuDelegate`.
final class RecentDocumentsMenuDelegate: NSObject, NSMenuDelegate, @unchecked Sendable {

    @MainActor static let shared = RecentDocumentsMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Items", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for url in urls {
                let item = NSMenuItem(title: url.lastPathComponent,
                                      action: #selector(openRecentDocument(_:)),
                                      keyEquivalent: "")
                item.representedObject = url
                item.target = self
                item.toolTip = url.path
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Menu",
                     action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                     keyEquivalent: "")
    }

    @objc private func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(
            withContentsOf: url, display: true
        ) { _, _, error in
            if let error {
                NSApp.presentError(error)
            }
        }
    }
}
