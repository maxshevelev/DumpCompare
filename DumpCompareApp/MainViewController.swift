import Cocoa
import DumpCompareCore

final class MainViewController: NSViewController {
    private(set) var mode: WindowMode = .empty
    let windowModel = WindowViewModel()
    private weak var activeFilePane: FilePaneView?

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        apply(mode: .empty)
    }

    /// Swaps the content area for the given window mode (§3 of REQUIREMENTS.md).
    func apply(mode: WindowMode) {
        self.mode = mode
        switch mode {
        case .empty:
            activeFilePane = nil
            setContentView(EmptyStateView())
        case .singleFile:
            let pane = FilePaneView(viewModel: windowModel.pane1)
            activeFilePane = pane
            setContentView(pane)
            pane.focusHexView()
        case .comparison:
            // Implemented in Milestone 5 (see IMPLEMENTATION_PLAN.md).
            let placeholder = NSTextField(labelWithString: "Comparison mode — arriving in Milestone 5")
            placeholder.textColor = .secondaryLabelColor
            placeholder.alignment = .center
            setContentView(placeholder)
        }
    }

    private func setContentView(_ newView: NSView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        newView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newView)
        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: view.topAnchor),
            newView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            newView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Helpers

    private var activePane: PaneViewModel { windowModel.activePane }

    private func focusActiveHexView() {
        activeFilePane?.focusHexView()
    }

    // MARK: - File > Open (§4.1)

    @objc func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.openFiles(panel.urls)
        }
    }

    private func openFiles(_ urls: [URL]) {
        guard let first = urls.first else { return }
        do {
            try windowModel.pane1.open(url: first)
        } catch {
            presentError("Could not open file.", error)
            return
        }
        if urls.count > 1 {
            presentAlert(title: "Additional files ignored",
                         message: "Only the first selected file was opened. Opening two files at once arrives in a later milestone.")
        }
        windowModel.setActivePane(0)
        apply(mode: .singleFile)
    }

    // MARK: - Save / Save As / Revert (§5)

    @objc func saveDocument() {
        let pane = activePane
        guard pane.isOpen else { return }
        do {
            try pane.save()
        } catch DocumentError.fileIsReadOnly {
            saveDocumentAs()  // §5.4: read-only file auto-redirects to Save As
        } catch {
            presentError("Save failed.", error)
        }
    }

    @objc func saveDocumentAs() {
        let pane = activePane
        guard pane.isOpen else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = pane.status.fileName
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: view.window ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try pane.saveAs(to: url)
            } catch {
                self.presentError("Save As failed.", error)
            }
        }
    }

    @objc func revertDocument() {
        let pane = activePane
        guard pane.isOpen else { return }
        if pane.status.isDirty {
            let response = confirmAlert(
                title: "Revert to saved version?",
                message: "All unsaved changes will be discarded.",
                confirmTitle: "Revert",
                destructive: true
            )
            guard response == .alertFirstButtonReturn else { return }
        }
        do {
            try pane.revert()
        } catch {
            presentError("Revert failed.", error)
        }
    }

    @objc func closeCurrentFile() {
        let pane = activePane
        guard pane.isOpen else { return }
        if pane.status.isDirty {
            let response = confirmSaveDiscardCancel()
            switch response {
            case .alertFirstButtonReturn:  // Save
                do {
                    try pane.save()
                } catch {
                    presentError("Save failed.", error)
                    return
                }
            case .alertSecondButtonReturn:  // Don't Save
                break
            default:  // Cancel
                return
            }
        }
        pane.close()
        apply(mode: .empty)
    }

    // MARK: - Edit commands (§7, §12)

    @objc func undoEdit() {
        try? activePane.undo()
    }

    @objc func redoEdit() {
        try? activePane.redo()
    }

    @objc func selectAllBytes() {
        activePane.selectAll()
        focusActiveHexView()
    }

    @objc func copySelection() {
        let pane = activePane
        guard let doc = pane.document, !doc.selection.isEmpty else { return }
        let range = doc.selection.start..<doc.selection.end
        guard let bytes = try? doc.read(at: range.lowerBound, length: Int(range.count)) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(Data(bytes), forType: .rawBytes)  // raw bytes: primary (§12.1)
        pasteboard.setString(ClipboardCodec.hexText(from: bytes), forType: .string)
    }

    @objc func pasteWrite() {
        let pane = activePane
        guard pane.isOpen else { return }
        do {
            let bytes = try pasteboardBytes()
            try pane.pasteWrite(bytes)
        } catch {
            presentError("Paste", error)
        }
    }

    @objc func pasteInsert() {
        let pane = activePane
        guard pane.isOpen else { return }
        let bytes: [UInt8]
        do {
            bytes = try pasteboardBytes()
        } catch {
            presentError("Paste Insert", error)
            return
        }
        guard !bytes.isEmpty else { return }
        let offset = pane.caretOffset
        let response = confirmAlert(
            title: "Paste Insert?",
            message: "Insert \(bytes.count) byte(s) at offset \(String(format: "0x%X", offset)). Existing bytes from this offset on will shift.",
            confirmTitle: "Insert",
            destructive: true
        )
        guard response == .alertFirstButtonReturn else { return }
        do {
            try pane.pasteInsert(bytes)
        } catch {
            presentError("Paste Insert failed.", error)
        }
    }

    @objc func fillSelectionWithZero() {
        activePane.fillSelectionWithZero()
    }

    @objc func deleteBytes() {
        let pane = activePane
        guard pane.isOpen else { return }
        let selection = pane.hexSelection()
        let start = selection.start
        let count = selection.isEmpty ? 1 : selection.count
        let response = confirmAlert(
            title: "Delete \(count) byte(s)?",
            message: "Bytes from offset \(String(format: "0x%X", start)) will be removed. Subsequent offsets will shift — the file structure may be affected.",
            confirmTitle: "Delete",
            destructive: true
        )
        guard response == .alertFirstButtonReturn else { return }
        do {
            try pane.deleteBytes(in: start..<(start + count))
        } catch {
            presentError("Delete failed.", error)
        }
    }

    // MARK: - Dialogs (§10)

    @objc func goToPosition() {
        let pane = activePane
        guard pane.isOpen else { return }
        let fileSize = pane.fileSize
        let sheet = GoToSheetController(fileSize: fileSize) { [weak self] offset in
            guard let self else { return }
            if offset > fileSize {
                self.presentAlert(
                    title: "Offset beyond end of file",
                    message: "Offset \(String(format: "0x%X", offset)) is beyond the end of the file (\(String(format: "0x%X", fileSize)) bytes). Moved to the end."
                )
                pane.moveCaret(to: fileSize)
            } else {
                pane.moveCaret(to: offset)
            }
            self.focusActiveHexView()
        }
        presentAsSheet(sheet)
    }

    @objc func selectBlock() {
        let pane = activePane
        guard pane.isOpen else { return }
        let sheet = SelectBlockSheetController(fileSize: pane.fileSize) { selection in
            pane.setSelection(selection)
        }
        presentAsSheet(sheet)
    }

    @objc func findPattern() {
        let pane = activePane
        guard pane.isOpen else { return }
        let sheet = FindSheetController { [weak self] pattern, direction in
            guard let self else { return false }
            let selection = pane.hexSelection()
            let from: UInt64
            if direction == .forward {
                from = selection.isEmpty ? selection.start : selection.end
            } else {
                from = selection.isEmpty ? selection.start : selection.start
            }
            guard let range = try? pane.find(pattern: pattern, from: from, direction: direction) else {
                return false
            }
            pane.select(range: range)
            self.focusActiveHexView()
            return true
        }
        presentAsSheet(sheet)
    }

    // MARK: - Alerts

    @discardableResult
    private func confirmAlert(title: String, message: String, confirmTitle: String, destructive: Bool = false) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        if destructive {
            alert.buttons.first?.hasDestructiveAction = true
        }
        return alert.runModal()
    }

    @discardableResult
    private func confirmSaveDiscardCancel() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "Do you want to save the changes you made?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal()
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}

// MARK: - Menu validation

extension MainViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveDocument),
             #selector(saveDocumentAs),
             #selector(revertDocument),
             #selector(closeCurrentFile),
             #selector(undoEdit),
             #selector(redoEdit),
             #selector(pasteWrite),
             #selector(pasteInsert),
             #selector(fillSelectionWithZero),
             #selector(deleteBytes),
             #selector(selectBlock),
             #selector(goToPosition),
             #selector(findPattern),
             #selector(selectAllBytes):
            return activePane.isOpen
        case #selector(copySelection):
            let pane = activePane
            return pane.isOpen && !pane.hexSelection().isEmpty
        default:
            return true
        }
    }
}

// MARK: - Clipboard

enum PasteError: LocalizedError {
    case noClipboardData

    var errorDescription: String? {
        switch self {
        case .noClipboardData:
            return "The clipboard does not contain raw bytes or a valid hex byte sequence."
        }
    }
}

/// Custom pasteboard type carrying raw bytes (§12.1). `public.data` is not a
/// defined PasteboardType member, and system types like `public.utf8-plain-text`
/// are interpreted by other apps as text, not bytes.
extension NSPasteboard.PasteboardType {
    static let rawBytes = NSPasteboard.PasteboardType("dev.maxik.DumpCompare.rawBytes")
}

private func pasteboardBytes() throws -> [UInt8] {
    let pasteboard = NSPasteboard.general
    if let data = pasteboard.data(forType: .rawBytes) {
        return [UInt8](data)
    }
    if let text = pasteboard.string(forType: .string) {
        return try ClipboardCodec.bytes(fromHexText: text)
    }
    throw PasteError.noClipboardData
}
