import Cocoa
import DumpCompareCore

final class MainViewController: NSViewController {
    private(set) var mode: WindowMode = .empty
    let windowModel = WindowViewModel()
    private weak var activeFilePane: FilePaneView?
    private weak var comparisonView: ComparisonView?

    /// Builds the background block index for comparison mode. The provider
    /// returns the current storages on every start/rebuild, so a revert that
    /// swaps a document's storage is always re-read.
    private lazy var comparisonCoordinator: ComparisonCoordinator = {
        ComparisonCoordinator { [weak self] in
            guard let self, self.mode == .comparison else { return nil }
            guard let left = self.windowModel.pane1.byteStorage,
                  let right = self.windowModel.pane2.byteStorage else { return nil }
            return (left, right)
        }
    }()

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
        unwireComparison()

        switch mode {
        case .empty:
            activeFilePane = nil
            comparisonView = nil
            comparisonCoordinator.stop()
            setContentView(EmptyStateView())

        case .singleFile:
            let pane = FilePaneView(viewModel: windowModel.pane1)
            activeFilePane = pane
            comparisonView = nil
            comparisonCoordinator.stop()
            setContentView(pane)
            pane.focusHexView()

        case .comparison:
            wireComparison()
            let pane1View = FilePaneView(viewModel: windowModel.pane1)
            let pane2View = FilePaneView(viewModel: windowModel.pane2)
            let view = ComparisonView(
                coordinator: comparisonCoordinator,
                paneView1: pane1View,
                paneView2: pane2View
            )
            view.onPaneActivated = { [weak self] index in
                guard let self, let comparisonView = self.comparisonView else { return }
                self.windowModel.setActivePane(index)
                self.activeFilePane = index == 0 ? comparisonView.paneView1 : comparisonView.paneView2
                comparisonView.setActive(index)
            }
            pane1View.onClose = { [weak self] in self?.closePane(at: 0) }
            pane2View.onClose = { [weak self] in self?.closePane(at: 1) }

            activeFilePane = windowModel.activePaneIndex == 0 ? pane1View : pane2View
            comparisonView = view
            setContentView(view)
            view.setActive(windowModel.activePaneIndex)
            comparisonCoordinator.start()
            activeFilePane?.focusHexView()
        }
    }

    /// Wires companion panes and coordinator callbacks for comparison mode.
    private func wireComparison() {
        windowModel.pane1.companion = windowModel.pane2
        windowModel.pane2.companion = windowModel.pane1
        windowModel.pane1.onEdit = { [weak self] edit in
            self?.comparisonCoordinator.record(edit: edit)
        }
        windowModel.pane2.onEdit = { [weak self] edit in
            self?.comparisonCoordinator.record(edit: edit)
        }
        windowModel.pane1.onFullInvalidation = { [weak self] in
            self?.comparisonCoordinator.rebuild()
        }
        windowModel.pane2.onFullInvalidation = { [weak self] in
            self?.comparisonCoordinator.rebuild()
        }
    }

    private func unwireComparison() {
        windowModel.pane1.companion = nil
        windowModel.pane2.companion = nil
        windowModel.pane1.onEdit = nil
        windowModel.pane2.onEdit = nil
        windowModel.pane1.onFullInvalidation = nil
        windowModel.pane2.onFullInvalidation = nil
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

    private func refreshMode() {
        apply(mode: windowModel.openPaneCount == 0 ? .empty : (windowModel.openPaneCount == 1 ? .singleFile : .comparison))
    }

    // MARK: - File > Open (§4.1)

    @objc func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.openFiles(panel.urls)
        }
    }

    private func openFiles(_ urls: [URL]) {
        let files = urls.filter(isOpenableFile)
        if files.count < urls.count {
            presentAlert(title: "Some files could not be opened",
                         message: "Directories and packages are not supported.")
        }
        guard let first = files.first else { return }

        switch (windowModel.pane1.isOpen, windowModel.pane2.isOpen) {
        case (false, _):
            // Rule 1: no panes occupied — first → pane 1, second → pane 2.
            guard openIntoPane(index: 0, url: first) else { return }
            if files.count >= 2 {
                _ = openIntoPane(index: 1, url: files[1])
            }
            windowModel.setActivePane(0)

        case (true, false):
            // Rule 2: only pane 1 occupied — first file opens in pane 2.
            guard openIntoPane(index: 1, url: first) else { return }
            windowModel.setActivePane(1)

        case (true, true):
            // Rule 3: both occupied — replace the active pane.
            guard openIntoPane(index: windowModel.activePaneIndex, url: first) else { return }
        }

        if files.count > 2 {
            presentAlert(title: "Additional files ignored",
                         message: "Only the first two selected files were opened.")
        }
        refreshMode()
    }

    /// Opens `url` into the pane at `index`, enforcing §4.1 rules 4–6 (dirty
    /// replacement confirmation, same-file reload, no same file in both panes).
    /// Returns false when the open was refused or failed.
    private func openIntoPane(index: Int, url: URL) -> Bool {
        let pane = index == 0 ? windowModel.pane1 : windowModel.pane2
        let other = index == 0 ? windowModel.pane2 : windowModel.pane1

        // Rule 6: same file already open in the other pane.
        if other.isOpen, FileIdentity(url: url) == other.document?.identity {
            presentAlert(title: "File already open",
                         message: "“\(url.lastPathComponent)” is already open in the other pane and cannot be opened twice.")
            return false
        }

        // Rule 5: same file already open in the target pane → reload/no-op.
        if pane.isOpen, FileIdentity(url: url) == pane.document?.identity {
            if pane.status.isDirty {
                let response = confirmAlert(title: "Reload file?",
                                            message: "“\(url.lastPathComponent)” has unsaved changes. Reload and discard them?",
                                            confirmTitle: "Reload",
                                            destructive: true)
                guard response == .alertFirstButtonReturn else { return false }
            }
            do {
                try pane.revert()
                return true
            } catch {
                presentError("Could not reload file.", error)
                return false
            }
        }

        // Rule 4: replacing a dirty pane requires confirmation.
        if pane.isOpen, pane.status.isDirty {
            let alert = NSAlert()
            alert.messageText = "Replace unsaved changes?"
            alert.informativeText = "“\(pane.status.fileName)” has unsaved changes. Save and replace, or replace without saving?"
            alert.addButton(withTitle: "Save and Replace")
            alert.addButton(withTitle: "Replace Without Saving")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:  // Save and Replace
                do {
                    try pane.save()
                } catch {
                    presentError("Save failed.", error)
                    return false
                }
            case .alertSecondButtonReturn:  // Replace Without Saving
                break
            default:
                return false
            }
        }

        do {
            try pane.open(url: url)
            return true
        } catch {
            presentError("Could not open file.", error)
            return false
        }
    }

    private func isOpenableFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == false
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

    // MARK: - Pane / window closing (§3.5/3.6)

    /// File > Close Pane: closes the active pane. In comparison mode this
    /// returns to single-file mode (with pane 2 promoted when pane 1 closes);
    /// closing the last pane returns to empty mode.
    @objc func closeCurrentFile() {
        closePane(at: windowModel.activePaneIndex)
    }

    /// Closes the pane at `index` after the standard dirty prompt.
    func closePane(at index: Int) {
        let pane = index == 0 ? windowModel.pane1 : windowModel.pane2
        guard pane.isOpen else { return }
        if pane.status.isDirty {
            switch confirmSaveDiscardCancel() {
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
        windowModel.closePane(index)
        refreshMode()
        if mode == .singleFile {
            activeFilePane?.focusHexView()
        }
    }

    // MARK: - Edit commands (§7, §12)

    @objc func undoEdit() {
        _ = try? activePane.undo()
    }

    @objc func redoEdit() {
        _ = try? activePane.redo()
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

    // MARK: - Comparison navigation (§10.3)

    @objc func nextDifference() { navigateBlock(kind: .different, direction: .forward) }
    @objc func previousDifference() { navigateBlock(kind: .different, direction: .backward) }
    @objc func nextSameBlock() { navigateBlock(kind: .same, direction: .forward) }
    @objc func previousSameBlock() { navigateBlock(kind: .same, direction: .backward) }

    private func navigateBlock(kind: DiffBlock.Kind, direction: SearchDirection) {
        guard mode == .comparison else { return }
        let from = windowModel.activePane.caretOffset
        Task {
            guard let block = await comparisonCoordinator.findBlock(kind: kind, direction: direction, from: from) else {
                let what = kind == .different ? "difference" : "same block"
                NSSound.beep()
                comparisonView?.showNavigationMessage("No more \(what)")
                return
            }
            let target = block.range.lowerBound
            windowModel.pane1.moveCaret(to: target)
            windowModel.pane2.moveCaret(to: target)
            comparisonView?.refreshComparisonInfo()
            focusActiveHexView()
        }
    }

    /// View > Toggle Pane Layout (§3.3).
    @objc func togglePaneLayout() {
        guard mode == .comparison else { return }
        comparisonView?.toggleLayout()
    }

    // MARK: - Dialogs (§10)

    @objc func goToPosition() {
        let pane = activePane
        guard pane.isOpen else { return }
        let largerSize = max(windowModel.pane1.fileSize, windowModel.pane2.fileSize)
        let sheet = GoToSheetController(fileSize: largerSize) { [weak self] offset in
            guard let self else { return }
            if offset > largerSize {
                self.presentAlert(
                    title: "Offset beyond end of file",
                    message: "Offset \(String(format: "0x%X", offset)) is beyond the end of the file(s) (\(String(format: "0x%X", largerSize)) bytes). Moved to the end."
                )
            }
            let target = min(offset, largerSize)
            if self.mode == .comparison {
                // §10.1: move both panes; each clamps to its own EOF.
                self.windowModel.pane1.moveCaret(to: target)
                self.windowModel.pane2.moveCaret(to: target)
            } else {
                pane.moveCaret(to: target)
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
            let from = selection.isEmpty ? selection.start : selection.start
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

// MARK: - Window closing (§3.6)

extension MainViewController: NSWindowDelegate {
    /// Combined dirty prompt on window close: list every modified file, offer
    /// Save / Don't Save / Cancel. Aborts the close when a save fails so no
    /// change is ever lost silently.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let panes = [windowModel.pane1, windowModel.pane2]
        let dirty = panes.filter { $0.isOpen && $0.status.isDirty }
        guard !dirty.isEmpty else { return true }

        let names = dirty.map { "“\($0.status.fileName)”" }.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "The following files have unsaved changes: \(names)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for pane in dirty {
                do {
                    try pane.save()
                } catch {
                    presentError("Could not save “\(pane.status.fileName)”.", error)
                    return false
                }
            }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
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
        case #selector(nextDifference),
             #selector(previousDifference),
             #selector(nextSameBlock),
             #selector(previousSameBlock),
             #selector(togglePaneLayout):
            return mode == .comparison
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
