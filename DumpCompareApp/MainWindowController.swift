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
        appMenu.addItem(withTitle: "Hide DumpCompare", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DumpCompare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu (§4, §5)
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(MainViewController.presentOpenPanel), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(MainViewController.saveDocument), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Save As…", action: #selector(MainViewController.saveDocumentAs), keyEquivalent: "S")
        fileMenu.addItem(withTitle: "Revert to Saved", action: #selector(MainViewController.revertDocument), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Pane", action: #selector(MainViewController.closeCurrentFile), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

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
        editMenu.addItem(withTitle: "Fill Selection with Zero", action: #selector(MainViewController.fillSelectionWithZero), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(MainViewController.selectAllBytes), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select Block…", action: #selector(MainViewController.selectBlock), keyEquivalent: "")
        editMenu.addItem(withTitle: "Find…", action: #selector(MainViewController.findPattern), keyEquivalent: "f")
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
}
