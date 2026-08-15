import Cocoa

final class MainWindowController: NSWindowController {
    let mainViewController: MainViewController

    init() {
        let controller = MainViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DumpCompare"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.contentViewController = controller
        window.delegate = controller
        mainViewController = controller
        super.init(window: window)
        buildMainMenu()
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

    /// The autosaved frame is restored when the window is first displayed, which
    /// can yield a degenerate size (1×28) or an off-screen position (e.g. saved
    /// during a headless launch, or a monitor disconnected since last run). Fall
    /// back to the default centered frame so the empty-state window is always
    /// visible at launch (§3.1). The corrected frame is then saved on close,
    /// replacing the bad default.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else { return }
        if window.frame.width < 200 || window.frame.height < 200
            || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.setFrame(NSRect(x: 0, y: 0, width: 1080, height: 720), display: true)
            window.center()
        }
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
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(MainViewController.undoEdit), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(MainViewController.redoEdit), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: nil, keyEquivalent: "")
        editMenu.addItem(withTitle: "Copy", action: #selector(MainViewController.copySelection), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste Write", action: #selector(MainViewController.pasteWrite), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Paste Insert…", action: #selector(MainViewController.pasteInsert), keyEquivalent: "")
        editMenu.addItem(withTitle: "Delete Bytes…", action: #selector(MainViewController.deleteBytes), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Fill Selection with…", action: #selector(MainViewController.fillSelectionWithBytes), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(MainViewController.selectAllBytes), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select Block…", action: #selector(MainViewController.selectBlock), keyEquivalent: "")
        editMenu.addItem(withTitle: "Find", action: #selector(MainViewController.findPattern), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Go To Position…", action: #selector(MainViewController.goToPosition), keyEquivalent: "g")
        editItem.submenu = editMenu

        // View menu (§10.3 navigation, §3.3 layout)
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Pane Layout", action: #selector(MainViewController.togglePaneLayout), keyEquivalent: "l")
        if let layoutItem = viewMenu.items.last {
            layoutItem.keyEquivalentModifierMask = [.command, .option]
        }
        viewMenu.addItem(withTitle: "Swap Panels", action: #selector(MainViewController.swapPanes), keyEquivalent: "")
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

}
