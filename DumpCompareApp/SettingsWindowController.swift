import Cocoa

/// The Appearance tab of the Settings window (§3.2): the monospaced font and
/// the row-height factor. Every change persists immediately through
/// `AppearanceSettings.set` and re-lays out every open hex view, so the effect
/// is visible live behind the settings window.
final class AppearanceSettingsViewController: NSViewController {
    private let fontPopup = NSPopUpButton()
    private let scaleSlider = NSSlider()
    private let scaleValueLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: "Appearance")
        titleLabel.font = .boldSystemFont(ofSize: 15)

        // Font row: a popup of "System" + the monospaced families.
        let fontLabel = NSTextField(labelWithString: "Font:")
        fontPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        fontPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

        // Row-height row: a slider snapping to 0.05 steps + the current value.
        let scaleLabel = NSTextField(labelWithString: "Row Height:")
        scaleSlider.minValue = Double(AppearanceSettings.rowHeightScaleRange.lowerBound)
        scaleSlider.maxValue = Double(AppearanceSettings.rowHeightScaleRange.upperBound)
        scaleSlider.numberOfTickMarks = 8
        scaleSlider.allowsTickMarkValuesOnly = true
        scaleSlider.isContinuous = true
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleChanged(_:))
        scaleSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let scaleRow = NSStackView()
        scaleRow.orientation = .horizontal
        scaleRow.spacing = 8
        scaleRow.addArrangedSubview(scaleSlider)
        scaleRow.addArrangedSubview(scaleValueLabel)

        let grid = NSGridView(views: [
            [fontLabel, fontPopup],
            [scaleLabel, scaleRow],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let caption = NSTextField(wrappingLabelWithString:
            "The hex dump's font and row pitch. A smaller Row Height packs more rows onto the screen.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 2

        for subview in [titleLabel, grid, caption] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            grid.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            caption.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            caption.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])

        // The window sizes itself to this frame when the controller becomes the
        // window's contentViewController.
        root.frame.size = NSSize(width: 480, height: 190)
        view = root

        syncControls()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Re-sync in case settings changed from the menu (e.g. tests).
        syncControls()
    }

    /// Loads the current settings into the controls.
    private func syncControls() {
        fontPopup.removeAllItems()
        // NSPopUpButton's own addItem(withTitle:) returns Void; build items on
        // its menu so each carries the family as its representedObject.
        let menu = fontPopup.menu!
        let systemItem = menu.addItem(withTitle: "System", action: nil, keyEquivalent: "")
        systemItem.representedObject = AppearanceSettings.systemFontSentinel
        let current = AppearanceSettings.fontFamily
        for family in AppearanceSettings.monospacedFontFamilies() {
            let item = menu.addItem(withTitle: family, action: nil, keyEquivalent: "")
            item.representedObject = family
        }
        let index = current.isEmpty ? 0 : fontPopup.indexOfItem(withRepresentedObject: current)
        fontPopup.selectItem(at: index >= 0 ? index : 0)

        scaleSlider.doubleValue = Double(AppearanceSettings.rowHeightScale)
        scaleValueLabel.stringValue = Self.formatScale(AppearanceSettings.rowHeightScale)
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let family = sender.selectedItem?.representedObject as? String ?? AppearanceSettings.systemFontSentinel
        AppearanceSettings.set(fontFamily: family, rowHeightScale: AppearanceSettings.rowHeightScale)
    }

    @objc private func scaleChanged(_ sender: NSSlider) {
        // Snap to the 0.05 tick grid (the slider already snaps with
        // allowsTickMarkValuesOnly; this keeps the stored value exact).
        let snapped = (sender.doubleValue / 0.05).rounded() * 0.05
        let scale = min(AppearanceSettings.rowHeightScaleRange.upperBound,
                        max(AppearanceSettings.rowHeightScaleRange.lowerBound, snapped))
        scaleValueLabel.stringValue = Self.formatScale(scale)
        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily, rowHeightScale: scale)
    }

    private static func formatScale(_ scale: CGFloat) -> String {
        String(format: "%.2g×", scale)
    }
}

/// The app's Settings window — a standard toolbar-tabbed preference dialog,
/// currently with a single Appearance tab (§3.2). Owned by
/// `MainWindowController`; the App menu's "Settings…" item shows it.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let appearanceController = AppearanceSettingsViewController()

    private static let appearanceItemID = NSToolbarItem.Identifier("Appearance")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DumpCompare Settings"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)

        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        window.contentViewController = appearanceController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        // Center on first show; keep a position the user already moved to.
        if window?.isVisible != true {
            window?.center()
        }
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.appearanceItemID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.appearanceItemID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.appearanceItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Appearance"
        item.paletteLabel = "Appearance"
        item.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: "Appearance")
        item.target = self
        item.action = #selector(appearanceTabTapped)
        return item
    }

    @objc private func appearanceTabTapped() {
        // Single tab; re-selecting it just keeps the Appearance view frontmost.
        window?.contentViewController = appearanceController
    }
}
