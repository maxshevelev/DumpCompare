import Cocoa

final class MainWindowController: NSWindowController {
    let mainViewController: MainViewController

    /// The window toolbar's Prev/Next Difference group (two default items in
    /// one joined block, pinned to the toolbar's right edge). Held so the
    /// delegate can hand it out.
    private(set) var diffNavigationGroup: NSToolbarItemGroup?

    /// The toolbar's minimap toggle button (the "sidebar.right" item at the
    /// far right, past a standard space). Held so the delegate can hand it out.
    private(set) var minimapToggleItem: NSToolbarItem?

    init() {
        let controller = MainViewController()
        // The launch width fits the hex-grid geometry implied by the saved
        // layout settings (§3.1); the height is the standard default. The frame
        // is autosaved, so a subsequent launch restores the user's latest size
        // and position — but `showWindow` re-fits the width to the settings.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: MainViewController.launchContentWidth(), height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DumpCompare"
        // The app name in the title bar is redundant — the toolbar occupies the
        // whole title bar — so hide the title text. The title stays set for the
        // Window menu, Mission Control, etc. (§10.3).
        window.titleVisibility = .hidden
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.contentViewController = controller
        window.delegate = controller
        mainViewController = controller
        super.init(window: window)
        buildMainMenu()
        buildToolbar()
        // The toolbar exists only now, so the mode's effect on it has to be
        // applied once here: the difference block is in the default items and
        // the window opens with no file (§10.3).
        controller.syncDiffNavigationToolbarItem()
    }

    /// Owned lazily so the settings window isn't instantiated until first use.
    private lazy var settingsWindowController = SettingsWindowController()

    @objc private func showSettings(_ sender: Any?) {
        settingsWindowController.showWindow(sender)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The launch width: the hex-grid fit for the saved layout settings (§3.1),
    /// capped at the screen's visible width so the window never opens wider
    /// than its screen.
    private var launchWidth: CGFloat {
        min(MainViewController.launchContentWidth(),
            (window?.screen ?? NSScreen.main)?.visibleFrame.width ?? MainViewController.launchContentWidth())
    }

    /// The autosaved frame is restored when the window is first displayed, which
    /// can yield a degenerate size (1×28) or an off-screen position (e.g. saved
    /// during a headless launch, or a monitor disconnected since last run). Fall
    /// back to the default centered frame so the empty-state window is always
    /// visible at launch (§3.1). The corrected frame is then saved on close,
    /// replacing the bad default.
    ///
    /// On top of that, the launch width always re-fits the hex-grid geometry of
    /// the saved layout settings (word size + direction), so a new word size or
    /// layout choice is reflected on the next launch even when the autosaved
    /// frame kept an older width (§3.1). The height and the vertical position
    /// are left untouched.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else { return }
        if window.frame.width < 200 || window.frame.height < 200
            || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.setFrame(NSRect(x: 0, y: 0, width: launchWidth, height: 720), display: true)
            window.center()
        } else {
            var frame = window.frame
            frame.size.width = launchWidth
            // Keep the window on the visible screen when the fitted width is
            // wider than the restored one (the left edge would stay put and the
            // right edge could run off-screen).
            if let visible = window.screen?.visibleFrame {
                frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            }
            window.setFrame(frame, display: true)
        }
    }

    // MARK: - Toolbar

    /// Builds the window toolbar (§10.3 navigation). The Prev/Next Difference
    /// block sits pinned to the right edge — a flexible space fills everything
    /// to its left (§10.3).
    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // Fixed item layout — never autosave a reordered/customized copy of the
        // default identifiers below, so the flexible-space-first order that
        // pins the diff block to the right edge can't be displaced by a saved
        // configuration.
        toolbar.autosavesConfiguration = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    /// The Prev/Next Difference toolbar group: two default toolbar items (the
    /// system backward/forward icons for previous/next) joined in one expanded
    /// block, targeting `mainViewController` directly — the same routing the
    /// menu items use (§10.3).
    private func makeDiffNavigationGroup() -> NSToolbarItemGroup {
        func navItem(_ identifier: NSToolbarItem.Identifier, _ symbol: String,
                     _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.target = mainViewController
            item.action = action
            return item
        }
        let group = NSToolbarItemGroup(itemIdentifier: .diffNavigation)
        group.subitems = [
            navItem(.previousDifference, "backward", "Prev Diff",
                    #selector(MainViewController.previousDifference)),
            navItem(.nextDifference, "forward", "Next Diff",
                    #selector(MainViewController.nextDifference)),
        ]
        group.controlRepresentation = .expanded
        return group
    }

    // MARK: - Menu

    /// Builds the main menu programmatically (no nib). Menu commands target
    /// `mainViewController` directly so key equivalents work regardless of the
    /// current first responder (the hex view swallows unmodified keystrokes).
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About DumpCompare",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        // Standard macOS placement: Settings… between About and the Hide/Quit
        // group. Explicit target keeps ⌘, working even when the hex view (which
        // swallows unmodified keystrokes) is first responder.
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DumpCompare", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DumpCompare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu (§4, §5).
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        fileItem.submenu = makeFileMenu()

        // Edit menu (§7, §11, §12)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        editItem.submenu = makeEditMenu()

        // View menu (§10.3 navigation, §3.3 layout)
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Pane Layout", action: #selector(MainViewController.togglePaneLayout), keyEquivalent: "l")
        if let layoutItem = viewMenu.items.last {
            layoutItem.keyEquivalentModifierMask = [.command, .option]
        }
        viewMenu.addItem(withTitle: "Swap Panels", action: #selector(MainViewController.swapPanes), keyEquivalent: "")
        // The minimap toggle also lives in the toolbar; the menu gives it a key
        // equivalent and a discoverable home. The title flips with the panel's
        // state, the way Show/Hide items do elsewhere on the platform.
        viewMenu.addItem(withTitle: "Show Minimap",
                         action: #selector(MainViewController.toggleMinimap),
                         keyEquivalent: "M")
        // Whole-file overview vs the detail window around the caret (§19.4). A
        // checked item, not a flipping title: both modes show a minimap, so the
        // check reads as "which one" rather than "on or off".
        let overviewItem = viewMenu.addItem(withTitle: "Minimap Overview",
                                           action: #selector(MainViewController.toggleMinimapOverview),
                                           keyEquivalent: "m")
        overviewItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())

        func addNavigationItem(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) {
            let item = viewMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
        }
        addNavigationItem("Next Difference", #selector(MainViewController.nextDifference), "\u{F703}", [.command, .option])
        addNavigationItem("Previous Difference", #selector(MainViewController.previousDifference), "\u{F702}", [.command, .option])
        addNavigationItem("Next Same Block", #selector(MainViewController.nextSameBlock), "\u{F703}", [.command, .option, .shift])
        addNavigationItem("Previous Same Block", #selector(MainViewController.previousSameBlock), "\u{F702}", [.command, .option, .shift])

        // Word Size (§6): group the hex bytes into words of 1/2/4/8 bytes.
        viewMenu.addItem(.separator())
        let wordSizeItem = NSMenuItem(title: "Word Size", action: nil, keyEquivalent: "")
        let wordSizeMenu = NSMenu(title: "Word Size")
        for size in WordSize.allCases {
            let item = wordSizeMenu.addItem(
                withTitle: "\(size.rawValue) \(size.rawValue == 1 ? "Byte" : "Bytes")",
                action: #selector(MainViewController.setWordSize(_:)),
                keyEquivalent: ""
            )
            item.tag = size.rawValue
        }
        wordSizeItem.submenu = wordSizeMenu
        viewMenu.addItem(wordSizeItem)

        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        if let fullScreenItem = viewMenu.items.last {
            fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        }
        viewItem.submenu = viewMenu

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu

        // Help menu
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        helpItem.submenu = NSMenu(title: "Help")

        NSApp.mainMenu = mainMenu
    }

    /// Builds the app menu bar's File submenu (§4, §5). Every item targets
    /// `mainViewController` explicitly, which resolves the active pane.
    func makeFileMenu() -> NSMenu {
        let fileMenu = NSMenu(title: "File")
        func add(_ title: String, _ action: Selector, _ key: String) {
            let item = fileMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = mainViewController
        }
        // New File: no dialog — a brand-new untitled in-memory document opens
        // into a pane; it is written to disk on the first Save / Save As.
        add("New File", #selector(MainViewController.newDocument), "n")
        add("Open…", #selector(MainViewController.presentOpenPanel), "o")
        fileMenu.addItem(.separator())
        add("Save", #selector(MainViewController.saveDocument), "s")
        add("Save As…", #selector(MainViewController.saveDocumentAs), "S")
        add("Revert to Saved", #selector(MainViewController.revertDocument), "")
        fileMenu.addItem(.separator())
        // Close (⌘W) closes the active pane ("close document"); with no panes
        // open it falls back to closing the window (§3.5).
        add("Close", #selector(MainViewController.closeDocument), "w")
        return fileMenu
    }

    /// Builds the app menu bar's Edit submenu (§7, §11, §12). Standalone so a
    /// test can pin the key-equivalent routing: ⌘V must reach the standard
    /// `paste:` action (responder chain), never paste-write.
    func makeEditMenu() -> NSMenu {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(MainViewController.undoEdit), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(MainViewController.redoEdit), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: nil, keyEquivalent: "")
        editMenu.addItem(withTitle: "Copy", action: #selector(MainViewController.copySelection), keyEquivalent: "c")
        // ⌘V is the standard Paste (§11): the menu item dispatches `paste:`
        // down the responder chain, so a focused text field's editor pastes
        // text, while a focused hex view routes to MainViewController.paste(_:)
        // and overwrites bytes (paste-write). Plain Paste already IS the
        // paste-write in the dump, so no separate "Paste Write" entry exists.
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Paste Insert…", action: #selector(MainViewController.pasteInsert), keyEquivalent: "")
        editMenu.addItem(withTitle: "Delete Bytes…", action: #selector(MainViewController.deleteBytes), keyEquivalent: "")
        // A checked toggle, not a one-shot command: it flips the typing mode for
        // both panes (see `toggleInsertMode`). Bound to ⌥⌘I — a mode switch the
        // user reaches often, so it earns a shortcut (Option keeps it clear of
        // the plain-⌘ single-letter command space).
        let insertModeItem = editMenu.addItem(withTitle: "Insert Mode",
                                              action: #selector(MainViewController.toggleInsertMode),
                                              keyEquivalent: "i")
        insertModeItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Fill Selection with…", action: #selector(MainViewController.fillSelectionWithBytes), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(MainViewController.selectAllBytes), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select Block…", action: #selector(MainViewController.selectBlock), keyEquivalent: "")
        editMenu.addItem(withTitle: "Find", action: #selector(MainViewController.findPattern), keyEquivalent: "f")
        // ⌘D marks (or unmarks) the caret's row — the gesture that has to cost
        // nothing on a bench (§20). It sits beside Go To: mark where you are,
        // then go to a position. The title says Toggle rather than Add because
        // the one command does both, whatever the caret's row currently is.
        editMenu.addItem(withTitle: "Toggle Bookmark", action: #selector(MainViewController.toggleBookmark), keyEquivalent: "d")
        // ⇧⌘D edits the caret's row's mark — its address and its name. Making one
        // is ⌘D's job, which opens the same popover, so this command only ever
        // edits, and is greyed out on a row that carries no mark (§20.3).
        editMenu.addItem(withTitle: "Edit Bookmark…", action: #selector(MainViewController.editBookmark), keyEquivalent: "D")
        editMenu.addItem(withTitle: "Go To Position…", action: #selector(MainViewController.goToPosition), keyEquivalent: "g")
        // ⌥⌘B opens the same form as ⌘G with the bookmark list focused (§10.1):
        // one window answers "go where?", and the two shortcuts differ only in
        // which half of it the keyboard starts in. ⌘B is the system's Bold, so
        // the list takes the Option variant.
        let bookmarksItem = editMenu.addItem(withTitle: "Bookmarks…",
                                             action: #selector(MainViewController.showBookmarks),
                                             keyEquivalent: "b")
        bookmarksItem.keyEquivalentModifierMask = [.command, .option]
        return editMenu
    }

}

// MARK: - Toolbar

extension NSToolbarItem.Identifier {
    /// The Prev/Next Difference group in the window toolbar.
    static let diffNavigation = NSToolbarItem.Identifier("DiffNavigation")
    /// Previous Difference — the left subitem of the diff group.
    static let previousDifference = NSToolbarItem.Identifier("PreviousDifference")
    /// Next Difference — the right subitem of the diff group.
    static let nextDifference = NSToolbarItem.Identifier("NextDifference")
    /// The minimap show/hide toggle button at the toolbar's far right (§19).
    static let toggleMinimap = NSToolbarItem.Identifier("ToggleMinimap")
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The flexible space must be listed as allowed too, or AppKit drops it
        // from the default items and the diff block ends up on the LEFT edge.
        [.flexibleSpace, .diffNavigation, .toggleMinimap, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The flexible space before the block pins it to the toolbar's right
        // edge; the minimap button sits past a standard space, so the diff
        // navigation and the panel toggle never crowd each other (§19). The
        // space must be a system one, not a custom empty view: AppKit draws a
        // single background platter around adjacent items, and a view-backed
        // spacer joins the toggle's platter — a wide capsule with the icon
        // shoved against its right edge.
        [.flexibleSpace, .diffNavigation, .space, .toggleMinimap]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .diffNavigation:
            // Build it on first request, then keep returning the same instance
            // so the toolbar's default items resolve to one fixed group.
            if diffNavigationGroup == nil {
                diffNavigationGroup = makeDiffNavigationGroup()
            }
            return diffNavigationGroup
        case .toggleMinimap:
            if minimapToggleItem == nil {
                let item = NSToolbarItem(itemIdentifier: .toggleMinimap)
                item.image = NSImage(systemSymbolName: "sidebar.right",
                                     accessibilityDescription: "Toggle Minimap")
                item.label = "Minimap"
                item.paletteLabel = "Minimap"
                item.toolTip = "Show or hide the minimap"
                item.target = mainViewController
                item.action = #selector(MainViewController.toggleMinimap)
                minimapToggleItem = item
            }
            return minimapToggleItem
        default:
            return nil
        }
    }
}
