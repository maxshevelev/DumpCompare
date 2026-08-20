import Cocoa

/// The persisted editing behaviour: whether the edits that shift the file ask
/// first (§7.2).
///
/// Mirrors the `ComparisonSettings`/`LayoutSettings` pattern — read live from
/// `UserDefaults`, written through `set`. There is no notification: nothing on
/// screen derives from it, it is read at the moment an alert would be shown.
enum EditingSettings {
    static let warnsBeforeShiftingEditsKey = "WarnsBeforeShiftingEdits"

    /// Whether Paste Insert, Delete Bytes and the first insert-mode keystroke in
    /// a file ask before shifting every offset after them.
    ///
    /// On by default: shifting a dump's offsets is the one edit that can quietly
    /// ruin it, and §7.2 wants it confirmed. Off for someone who inserts often
    /// enough that the dialog is the thing in the way — every one of these edits
    /// is undoable, and the mode announces itself in the status bar (INS) and in
    /// the caret.
    static var warnsBeforeShiftingEdits: Bool {
        // `object(forKey:)` distinguishes "never set" from "set to false":
        // `bool(forKey:)` answers false for both, which would ship the warnings
        // switched off.
        UserDefaults.standard.object(forKey: warnsBeforeShiftingEditsKey) as? Bool ?? true
    }

    static func set(warnsBeforeShiftingEdits: Bool) {
        UserDefaults.standard.set(warnsBeforeShiftingEdits, forKey: warnsBeforeShiftingEditsKey)
    }

    /// Restores the built-in default (used by tests).
    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: warnsBeforeShiftingEditsKey)
    }
}

/// The Editing tab of the Settings window: whether the shifting-edit
/// confirmations appear. The same switch the alerts' "Do not ask again"
/// checkbox flips, which is why it reads its value on every appearance —
/// dismissing an alert with that box ticked must be reflected here.
final class EditingSettingsViewController: NSViewController {
    private let warnCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    override func loadView() {
        let root = NSView()

        let titleLabel = NSTextField(labelWithString: "Editing")
        titleLabel.font = .boldSystemFont(ofSize: 15)

        warnCheckbox.title = "Ask before edits that shift the file"
        warnCheckbox.target = self
        warnCheckbox.action = #selector(warnChanged(_:))

        let caption = NSTextField(wrappingLabelWithString:
            "Insert mode, Paste Insert and Delete Bytes move every byte after the edit, "
            + "so they ask first. Turn this off to edit without the dialog — the edits stay "
            + "undoable, and insert mode still shows INS in the status bar.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 3

        for subview in [titleLabel, warnCheckbox, caption] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            warnCheckbox.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            warnCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            caption.topAnchor.constraint(equalTo: warnCheckbox.bottomAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            caption.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),

            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
        ])
        view = root
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    /// Reads the stored value into the checkbox. Internal so a test can check
    /// the tab reflects a value an alert's checkbox wrote.
    func refresh() {
        warnCheckbox.state = EditingSettings.warnsBeforeShiftingEdits ? .on : .off
    }

    /// The checkbox's current state, for tests.
    var warnsBeforeShiftingEdits: Bool { warnCheckbox.state == .on }

    @objc private func warnChanged(_ sender: NSButton) {
        EditingSettings.set(warnsBeforeShiftingEdits: sender.state == .on)
    }
}
