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

    /// The toolbar's "Files are identical" badge — a green checkmark plus a
    /// label, shown in place of the Prev/Next Difference block when the
    /// comparison index has no differences. A custom view: the toolbar is
    /// icon-only, so a standard item would not render the text. Held so the
    /// delegate can hand it out.
    private(set) var filesIdenticalItem: NSToolbarItem?

    /// The toolbar's document commands (§24.1) and its two stateful controls
    /// (§24.2), plus the pane-layout toggle. Built on first request and cached
    /// the way the difference block is: the delegate must hand out one fixed
    /// instance per identifier, and a test reads the live control back through
    /// these handles.
    private(set) var goToItem: NSToolbarItem?
    private(set) var findItem: NSToolbarItem?
    private(set) var segmentsItem: NSToolbarItem?
    private(set) var insertModeItem: NSToolbarItem?
    private(set) var wordSizeItem: NSToolbarItem?
    private(set) var paneLayoutItem: NSToolbarItem?

    init() {
        let controller = MainViewController()
        // The launch width fits one pane's hex grid at the saved word size
        // (§3.1); the height is the standard default. The frame
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

    /// The launch width: the fit for one pane's hex grid at the saved word size
    /// (§3.1), capped at the screen's visible width so the window never opens
    /// wider than its screen.
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
    /// On top of that, the launch width always re-fits one pane's hex grid at
    /// the saved word size, so a new word size is reflected on the next launch
    /// even when the autosaved frame kept an older width (§3.1). The pane
    /// arrangement does not enter into it — the window opens empty. The height
    /// and the vertical position are left untouched.
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
        // A per-window identifier, not a shared "MainToolbar": AppKit
        // implicitly synchronises toolbars that share an identifier, so
        // inserting or removing an item in one window propagates to every other
        // window's toolbar. Those siblings hold a different item list, and the
        // index that travels with the mutation is out of bounds for it —
        //   Invalid parameter not satisfying: index>=0 && index<[_currentItems count]
        // raised from -[NSToolbar _itemAtIndex:] (§10.3, the arrows/badge swap).
        // Nothing is lost by making it unique: the layout is fixed in code and
        // `autosavesConfiguration` is off, so there is no configuration to share.
        let toolbar = NSToolbar(identifier: "MainToolbar-\(UUID().uuidString)")
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

    /// The "Files are identical" badge item: a green checkmark and a label in a
    /// view that sizes to its content. The toolbar is icon-only, so the text
    /// must live in a custom view — a standard item's label would not render.
    private func makeFilesIdenticalItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .filesIdentical)
        item.label = "Files are identical"
        item.paletteLabel = "Files are identical"
        item.view = makeFilesIdenticalBadgeView()
        return item
    }

    /// The badge's view: a green `checkmark.circle.fill` beside a
    /// "Files are identical" label, laid out horizontally and sized to fit so
    /// the toolbar lays the item out at its natural width.
    private func makeFilesIdenticalBadgeView() -> NSView {
        let container = NSView()

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                             accessibilityDescription: "Files are identical")
        icon.contentTintColor = .systemGreen
        icon.imageScaling = .scaleProportionallyUpOrDown

        let label = NSTextField(labelWithString: "Files are identical")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor

        container.addSubview(icon)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            // The container is as tall as the label and as wide as icon + gap +
            // label — fully determined, so the toolbar sizes the item to it.
            container.heightAnchor.constraint(equalTo: label.heightAnchor),
        ])
        container.setAccessibilityLabel("Files are identical")
        return container
    }

    /// A plain icon button in the toolbar: an image, a tooltip, and the routing
    /// the menu items use — straight at `mainViewController`, which resolves the
    /// active pane and answers validation (§24.1).
    private func makeCommandItem(_ identifier: NSToolbarItem.Identifier,
                                 symbol: String,
                                 label: String,
                                 toolTip: String,
                                 action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip
        item.target = mainViewController
        item.action = action
        return item
    }

    /// The insert-mode toggle: a push-on/push-off button, so the mode the keys
    /// are in is readable from the window chrome and not only as OVR/INS in the
    /// pane's status bar (§24.2). The state is pushed in `validateToolbarItem` —
    /// the mode is per pane, and validation is where the menu item's checkmark
    /// is set too.
    private func makeInsertModeItem() -> NSToolbarItem {
        let item = ControlToolbarItem(itemIdentifier: .insertMode)
        let button = NSButton(
            image: NSImage(systemSymbolName: "character.cursor.ibeam",
                           accessibilityDescription: "Insert Mode") ?? NSImage(),
            target: mainViewController,
            action: #selector(MainViewController.toggleInsertMode(_:))
        )
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .toolbar
        button.imagePosition = .imageOnly
        button.sizeToFit()
        button.setAccessibilityLabel("Insert Mode")
        item.view = button
        item.label = "Insert Mode"
        item.paletteLabel = "Insert Mode"
        item.toolTip = "Insert mode: typing shifts the rest of the file"
        // The click is the button's own; the item's target and action are what
        // validation is routed through (see `ControlToolbarItem`).
        item.target = mainViewController
        item.action = #selector(MainViewController.toggleInsertMode(_:))
        return item
    }

    /// The word-size control: a menu button naming the size in force — "2
    /// Bytes", not a bare digit, so the number is readable as a word size
    /// without a label the icon-only toolbar would not draw (§24.2). A menu
    /// rather than four visible segments because four segments were the widest
    /// thing in the toolbar for a setting that is chosen and then left alone.
    private func makeWordSizeItem() -> NSToolbarItem {
        let item = ControlToolbarItem(itemIdentifier: .wordSize)
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .toolbar
        for size in WordSize.allCases {
            button.addItem(withTitle: size.title)
            // The tag carries the size, so the action reads it from the button
            // the same way it reads it from a menu item (§6).
            button.lastItem?.tag = size.rawValue
        }
        button.selectItem(withTag: WordSize.current.rawValue)
        button.target = mainViewController
        button.action = #selector(MainViewController.setWordSize(_:))
        button.sizeToFit()
        button.setAccessibilityLabel("Word Size")
        item.view = button
        item.label = "Word Size"
        item.paletteLabel = "Word Size"
        item.toolTip = "Bytes per word in the hex grid"
        item.target = mainViewController
        item.action = #selector(MainViewController.setWordSize(_:))
        return item
    }

    /// The pane-layout toggle (§24.3). The icon and the tooltip name the
    /// arrangement the click will produce, and both are refreshed on every
    /// validation pass — the values here are only the ones it starts with.
    private func makePaneLayoutItem() -> NSToolbarItem {
        makeCommandItem(
            .paneLayout,
            symbol: LayoutSettings.isVertical ? "square.split.1x2" : "square.split.2x1",
            label: "Pane Layout",
            toolTip: LayoutSettings.isVertical ? "Stack the panes" : "Place the panes side by side",
            action: #selector(MainViewController.togglePaneLayout)
        )
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

// MARK: - Toolbar

extension NSToolbarItem.Identifier {
    /// The Prev/Next Difference group in the window toolbar.
    static let diffNavigation = NSToolbarItem.Identifier("DiffNavigation")
    /// Previous Difference — the left subitem of the diff group.
    static let previousDifference = NSToolbarItem.Identifier("PreviousDifference")
    /// Next Difference — the right subitem of the diff group.
    static let nextDifference = NSToolbarItem.Identifier("NextDifference")
    /// The "Files are identical" badge, shown in place of the diff group when
    /// the comparison index has no differences.
    static let filesIdentical = NSToolbarItem.Identifier("FilesIdentical")
    /// The minimap show/hide toggle button at the toolbar's far right (§19).
    static let toggleMinimap = NSToolbarItem.Identifier("ToggleMinimap")
    /// Go To: the offset-and-bookmarks form (§10.1, §20.5).
    static let goTo = NSToolbarItem.Identifier("GoTo")
    /// Find: the byte-pattern search bar (§8).
    static let find = NSToolbarItem.Identifier("Find")
    /// Segments: the partition's form (§21.4).
    static let segments = NSToolbarItem.Identifier("Segments")
    /// The insert/overwrite typing-mode toggle (§7.6).
    static let insertMode = NSToolbarItem.Identifier("InsertMode")
    /// The 1 / 2 / 4 / 8 word-size radio (§6).
    static let wordSize = NSToolbarItem.Identifier("WordSize")
    /// The side-by-side ⇄ stacked pane-arrangement toggle (§3.3).
    static let paneLayout = NSToolbarItem.Identifier("PaneLayout")
}

/// A toolbar item whose content is a control of our own. AppKit's own
/// `validate()` does nothing for a view-backed item — validation is left to the
/// subclass — so this one asks the target the way a plain item would, and passes
/// the answer on to the control (§24.2).
final class ControlToolbarItem: NSToolbarItem {
    override func validate() {
        guard let validator = target as? NSToolbarItemValidation else { return }
        let enabled = validator.validateToolbarItem(self)
        isEnabled = enabled
        (view as? NSControl)?.isEnabled = enabled
    }
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The flexible space must be listed as allowed too, or AppKit drops it
        // from the default items and the diff block ends up on the LEFT edge.
        [.flexibleSpace, .space,
         .goTo, .find, .segments, .insertMode, .wordSize,
         .diffNavigation, .filesIdentical, .paneLayout, .toggleMinimap]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Two groups, and the flexible space between them pins the right-hand
        // one to the toolbar's edge (§24). Left: what acts on the dump in the
        // active pane, then — past a space — the two controls that carry a
        // state. Right: the difference plaque, the pane arrangement, the
        // minimap. Every gap is a system space item, not a custom empty view:
        // AppKit draws a single background platter around adjacent items, and a
        // view-backed spacer joins its neighbour's platter — a wide capsule
        // with the icon shoved against its edge.
        [.goTo, .find, .segments, .space, .insertMode, .wordSize,
         .flexibleSpace, .diffNavigation, .space, .paneLayout, .space, .toggleMinimap]
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
        case .filesIdentical:
            // Built on first request and cached, like the diff group: the swap
            // logic re-inserts the same instance each time it is wanted.
            if filesIdenticalItem == nil {
                filesIdenticalItem = makeFilesIdenticalItem()
            }
            return filesIdenticalItem
        case .goTo:
            if goToItem == nil {
                goToItem = makeCommandItem(.goTo, symbol: "dot.scope", label: "Go To",
                                           toolTip: "Go to an offset or a bookmark",
                                           action: #selector(MainViewController.goToPosition))
            }
            return goToItem
        case .find:
            if findItem == nil {
                findItem = makeCommandItem(.find, symbol: "magnifyingglass", label: "Find",
                                           toolTip: "Find a byte pattern",
                                           action: #selector(MainViewController.findPattern))
            }
            return findItem
        case .segments:
            if segmentsItem == nil {
                segmentsItem = makeCommandItem(.segments,
                                               symbol: "arrow.up.and.line.horizontal.and.arrow.down",
                                               label: "Segments",
                                               toolTip: "The file's cuts and pieces",
                                               action: #selector(MainViewController.showSegments))
            }
            return segmentsItem
        case .insertMode:
            if insertModeItem == nil {
                insertModeItem = makeInsertModeItem()
            }
            return insertModeItem
        case .wordSize:
            if wordSizeItem == nil {
                wordSizeItem = makeWordSizeItem()
            }
            return wordSizeItem
        case .paneLayout:
            if paneLayoutItem == nil {
                paneLayoutItem = makePaneLayoutItem()
            }
            return paneLayoutItem
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
