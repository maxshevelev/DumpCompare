import Cocoa

/// The persisted default pane-layout direction (§3.3): the arrangement a new
/// comparison opens with. Shared by `ComparisonView` (reads it when building a
/// split view, writes it on toggle) and the Layout settings tab (§6).
enum LayoutSettings {
    static let layoutDirectionKey = "ComparisonPaneLayoutIsVertical"
    /// Posted after the default direction changes so an open comparison can
    /// re-lay out live, mirroring WordSize/AppearanceSettings (§6).
    static let layoutDirectionDidChangeNotification = Notification.Name("ComparisonLayoutDirectionDidChange")

    /// True = side-by-side (left/right), false = stacked (top/bottom).
    static var isVertical: Bool {
        UserDefaults.standard.object(forKey: layoutDirectionKey) as? Bool ?? true
    }

    static func set(isVertical: Bool) {
        UserDefaults.standard.set(isVertical, forKey: layoutDirectionKey)
        NotificationCenter.default.post(name: layoutDirectionDidChangeNotification, object: nil)
    }
}

/// The Layout tab of the Settings window (§6): the default layout direction and
/// the default word size the app starts with. Every change persists immediately
/// and applies live, matching the Appearance tab (§3.2).
final class LayoutSettingsViewController: NSViewController {
    private let layoutDirectionPopup = NSPopUpButton()
    private let wordSizePopup = NSPopUpButton()

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: "Layout")
        titleLabel.font = .boldSystemFont(ofSize: 15)

        // Layout direction row: the split orientation a new comparison opens in.
        let layoutLabel = NSTextField(labelWithString: "Layout Direction:")
        layoutDirectionPopup.target = self
        layoutDirectionPopup.action = #selector(layoutDirectionChanged(_:))
        layoutDirectionPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true

        // Word size row: how many bytes each hex word groups (§6).
        let wordSizeLabel = NSTextField(labelWithString: "Word Size:")
        wordSizePopup.target = self
        wordSizePopup.action = #selector(wordSizeChanged(_:))
        wordSizePopup.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let grid = NSGridView(views: [
            [layoutLabel, layoutDirectionPopup],
            [wordSizeLabel, wordSizePopup],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let caption = NSTextField(wrappingLabelWithString:
            "These are the defaults a new comparison opens with. Word Size also applies to the hex views already open.")
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
        // Re-sync in case the direction/word size changed from the View menu or
        // a layout toggle while the settings window was closed.
        syncControls()
    }

    /// Loads the current settings into the controls.
    private func syncControls() {
        layoutDirectionPopup.removeAllItems()
        layoutDirectionPopup.addItem(withTitle: "Left / Right")
        layoutDirectionPopup.addItem(withTitle: "Top / Bottom")
        layoutDirectionPopup.selectItem(at: LayoutSettings.isVertical ? 0 : 1)

        wordSizePopup.removeAllItems()
        for size in WordSize.allCases {
            let item = wordSizePopup.menu!.addItem(withTitle: size == .one ? "1 Byte" : "\(size.rawValue) Bytes",
                                                   action: nil, keyEquivalent: "")
            item.representedObject = size
        }
        wordSizePopup.selectItem(at: WordSize.allCases.firstIndex(of: WordSize.current) ?? 0)
    }

    @objc private func layoutDirectionChanged(_ sender: NSPopUpButton) {
        // Index 0 = Left/Right (vertical split), index 1 = Top/Bottom.
        LayoutSettings.set(isVertical: sender.indexOfSelectedItem == 0)
    }

    @objc private func wordSizeChanged(_ sender: NSPopUpButton) {
        guard let size = sender.selectedItem?.representedObject as? WordSize else { return }
        WordSize.set(size)
    }
}
