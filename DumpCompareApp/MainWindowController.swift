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
        mainViewController = controller
        super.init(window: window)
        buildMainMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
        fileMenu.addItem(withTitle: "Close File", action: #selector(MainViewController.closeCurrentFile), keyEquivalent: "")
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

        // View menu (placeholder until M5 layout options)
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
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
