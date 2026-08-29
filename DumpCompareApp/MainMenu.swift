import Cocoa

/// The application's menu bar (§4, §5, §7, §10.3, §11, §12), built in code
/// rather than from a nib.
///
/// There is one menu bar per application no matter how many windows or tabs are
/// open, so it is built once at launch and belongs to no window. That is also
/// why nothing here carries a target — apart from ⌘, — and every command
/// instead travels the responder chain to the key window's
/// `MainViewController`. A menu addressed to one particular controller would go
/// on addressing it after the user switched to another tab.
enum MainMenu {
    /// Builds the whole bar. `settingsTarget` receives ⌘, — an explicit target
    /// rather than the responder chain, so the key works even while the hex
    /// view, which swallows unmodified keystrokes, is first responder.
    static func build(settingsTarget: AnyObject) -> NSMenu {
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
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = settingsTarget
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
        viewItem.submenu = makeViewMenu()

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

        return mainMenu
    }

    /// Builds the app menu bar's View submenu (§3.3 layout, §10.3 navigation,
    /// §19 the minimap). Standalone for the same reason File and Edit are: a
    /// test can read what the menu offers without installing a menu bar on the
    /// running process.
    static func makeViewMenu() -> NSMenu {
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
                withTitle: size.title,
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
        return viewMenu
    }

    /// Builds the app menu bar's File submenu (§4, §5). No item carries a
    /// target: each command travels the responder chain to the key window's
    /// `MainViewController`, which resolves the active pane.
    static func makeFileMenu() -> NSMenu {
        let fileMenu = NSMenu(title: "File")
        func add(_ title: String, _ action: Selector, _ key: String) {
            fileMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        // New File: no dialog — a brand-new untitled in-memory document opens
        // into a pane; it is written to disk on the first Save / Save As.
        add("New File", #selector(MainViewController.newDocument), "n")
        // New Window (⇧⌘N) is the app's, not a pane's: it is the one File
        // command that does not act on a document, so it is the one item here
        // the responder chain carries past every view controller to the app
        // delegate, which owns the windows.
        add("New Window", #selector(AppDelegate.newWindow(_:)), "N")
        add("Open…", #selector(MainViewController.presentOpenPanel), "o")
        fileMenu.addItem(.separator())
        add("Save", #selector(MainViewController.saveDocument), "s")
        add("Save As…", #selector(MainViewController.saveDocumentAs), "S")
        add("Revert to Saved", #selector(MainViewController.revertDocument), "")
        fileMenu.addItem(.separator())
        // The join commands (§22.1): bring a second file's bytes into the active
        // pane, at one end or the other. They act on the active pane, like the
        // rest of the File submenu. Insert (at the start) is grouped with the
        // edit commands above; Append (at the end) sits in its own block.
        add("Insert File at Start…", #selector(MainViewController.insertFileAtStart), "")
        add("Append File…", #selector(MainViewController.appendFile), "")
        fileMenu.addItem(.separator())
        // Duplicate (§23): the active pane's content, copied into the free pane
        // as an untitled document — how the dump as opened is kept beside a copy
        // being patched. Single-file mode only, and no key equivalent: ⌘D is
        // Toggle Bookmark (§20).
        add("Duplicate", #selector(MainViewController.duplicateDocument), "")
        fileMenu.addItem(.separator())
        // Close (⌘W) closes the active pane ("close document"); with no panes
        // open it falls back to closing the window (§3.5).
        add("Close", #selector(MainViewController.closeDocument), "w")
        return fileMenu
    }

    /// Builds the app menu bar's Edit submenu (§7, §11, §12). Standalone so a
    /// test can pin the key-equivalent routing: ⌘V must reach the standard
    /// `paste:` action (responder chain), never paste-write.
    static func makeEditMenu() -> NSMenu {
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
        // Select Block leads the selection block: it selects a named block from
        // the caret, alongside Fill and Select All.
        editMenu.addItem(withTitle: "Select Block…", action: #selector(MainViewController.selectBlock), keyEquivalent: "")
        editMenu.addItem(withTitle: "Fill Selection with…", action: #selector(MainViewController.fillSelectionWithBytes), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(MainViewController.selectAllBytes), keyEquivalent: "a")
        editMenu.addItem(.separator())
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
        editMenu.addItem(withTitle: "Go To Position…", action: #selector(MainViewController.goToPosition), keyEquivalent: "l")
        // The segment pair (§21.3). No key equivalents: both are deliberate acts
        // reached from a menu, and the fast path is Split Here at «address» in the dump's own
        // context menu. Add Cut… opens the offset-and-description popover;
        // Merge merges the piece the caret sits in into a neighbour — it acts on
        // the caret's position, not on a cut point. Its title is renamed by
        // validation to name the piece and its neighbour ("Merge S1 into S0").
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Add Cut…", action: #selector(MainViewController.addCut), keyEquivalent: "")
        editMenu.addItem(withTitle: "Merge", action: #selector(MainViewController.removeSegment(_:)), keyEquivalent: "")
        // Segments…: the partition's own form (§21.4) — the list the two
        // commands above edit, with a row editor and the Save All button.
        // ⌥⌘S opens it: ⌘S is Save and ⇧⌘S is Save As, so the form takes the
        // Option variant.
        let segmentsItem = editMenu.addItem(withTitle: "Segments…",
                                            action: #selector(MainViewController.showSegments),
                                            keyEquivalent: "s")
        segmentsItem.keyEquivalentModifierMask = [.command, .option]
        return editMenu
    }
}
