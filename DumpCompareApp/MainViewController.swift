import Cocoa
import DumpCompareCore

final class MainViewController: NSViewController {
    private(set) var mode: WindowMode = .empty
    let windowModel = WindowViewModel()
    private weak var activeFilePane: FilePaneView?
    private weak var comparisonView: ComparisonView?

    /// The non-modal Find bar shown at the top on Cmd+F (§11). It lives above
    /// the content area and pushes it down while visible; when hidden the
    /// content fills the window again.
    private let findBar = FindBarView()
    /// Host for the mode content (`setContentView` swaps what's inside).
    private let contentContainer = NSView()
    private var contentTopToView: NSLayoutConstraint!
    private var contentTopToFindBar: NSLayoutConstraint!
    private var findTask: Task<Void, Never>?
    /// The active search operation, surfaced in the active pane's status bar
    /// while a search runs (§14.4).
    private var findOperation: BackgroundOperation?

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
        wireExternalChangeDetection()

        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true  // shown by Cmd+F (§11)
        findBar.onSearch = { [weak self] pattern, direction, caseSensitive in
            self?.runSearch(pattern: pattern, direction: direction, caseSensitive: caseSensitive)
        }
        findBar.onError = { [weak self] message in
            self?.showFindMessage(message)
        }
        findBar.onClose = { [weak self] in
            self?.hideFindBar()
        }
        view.addSubview(findBar)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        contentTopToView = contentContainer.topAnchor.constraint(equalTo: view.topAnchor)
        contentTopToFindBar = contentContainer.topAnchor.constraint(equalTo: findBar.bottomAnchor)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: view.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentTopToView,
        ])

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
            // Returning to the launch state must also dismiss the find bar —
            // nothing is left to search (§11).
            hideFindBar()
            let emptyView = EmptyStateView()
            emptyView.onOpenFiles = { [weak self] urls in
                self?.handleEmptyDrop(urls)
            }
            setContentView(emptyView)

        case .singleFile:
            let pane = FilePaneView(viewModel: windowModel.pane1)
            // Close button: closing the last file returns to empty mode (§3.5).
            pane.onClose = { [weak self] in self?.closePane(at: 0) }
            // Wrap in the drop-target split view (§4.3 single-file mode). The
            // pane itself is NOT drop-registered here so the outer view wins.
            let dropView = SingleFileDropView(paneView: pane)
            dropView.onDrop = { [weak self] target, urls in
                self?.handleSingleFileDrop(target: target, urls: urls)
            }
            activeFilePane = pane
            comparisonView = nil
            comparisonCoordinator.stop()
            setContentView(dropView)
            pane.focusHexView()

        case .comparison:
            wireComparison()
            let pane1View = FilePaneView(viewModel: windowModel.pane1)
            let pane2View = FilePaneView(viewModel: windowModel.pane2)
            // Comparison-mode drops target the hovered pane (§4.3).
            pane1View.enableFileDrop()
            pane2View.enableFileDrop()
            pane1View.onDropFiles = { [weak self] urls in
                self?.handleComparisonDrop(targetPane: 0, urls: urls)
            }
            pane2View.onDropFiles = { [weak self] urls in
                self?.handleComparisonDrop(targetPane: 1, urls: urls)
            }
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
                // Focus follows activation (e.g. a header click), so typing and
                // the active-pane pointer stay aligned (§3.3).
                self.activeFilePane?.focusHexView()
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
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        newView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(newView)
        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            newView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            newView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
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
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }

        // §4.1 rules 1–3, decided against the pre-open occupancy.
        let pane1WasOpen = windowModel.pane1.isOpen
        let pane2WasOpen = windowModel.pane2.isOpen
        let plan = OpenPlacement.plan(
            activePaneIndex: windowModel.activePaneIndex,
            pane1Open: pane1WasOpen,
            pane2Open: pane2WasOpen,
            fileCount: files.count
        )

        if let target = plan.firstFilePane {
            guard openIntoPane(index: target, url: first) else { return }
        }
        if plan.openSecond, files.count >= 2 {
            _ = openIntoPane(index: 1, url: files[1])
        }

        // Active pane follows the rule that decided placement.
        if !pane1WasOpen {
            windowModel.setActivePane(0)
        } else if !pane2WasOpen {
            windowModel.setActivePane(1)
        }

        if plan.ignoredCount > 0 {
            notifyIgnored(count: plan.ignoredCount)
        }
        refreshMode()
    }

    // MARK: - Drop handlers (§4.3)

    /// Empty-mode drop: first two files → panes 1/2, extras ignored (§4.3).
    private func handleEmptyDrop(_ urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }
        guard openIntoPane(index: 0, url: first) else { return }
        if files.count >= 2 {
            _ = openIntoPane(index: 1, url: files[1])
        }
        windowModel.setActivePane(0)
        let ignored = max(0, files.count - 2)
        if ignored > 0 { notifyIgnored(count: ignored) }
        refreshMode()
    }

    /// Comparison-mode drop: first file → hovered pane; second file → other pane
    /// only if that pane is empty; extras (and an unplaceable second) ignored.
    private func handleComparisonDrop(targetPane: Int, urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }
        guard openIntoPane(index: targetPane, url: first) else { return }

        let otherIndex = 1 - targetPane
        let otherPane = otherIndex == 0 ? windowModel.pane1 : windowModel.pane2
        var ignored = max(0, files.count - 2)
        if files.count >= 2 {
            if otherPane.isOpen {
                ignored += 1  // the second file can't open — treated as ignored
            } else {
                _ = openIntoPane(index: otherIndex, url: files[1])
            }
        }
        windowModel.setActivePane(targetPane)
        if ignored > 0 { notifyIgnored(count: ignored) }
        refreshMode()
    }

    /// Single-file-mode drop onto one of the two visual targets (§4.3).
    private func handleSingleFileDrop(target: SingleFileDropTarget, urls: [URL]) {
        let files = openableFiles(from: urls)
        guard let first = files.first else { return }
        switch target {
        case .replace:
            // First replaces the current file; a second (if any) opens as pane 2.
            guard openIntoPane(index: 0, url: first) else { return }
            if files.count >= 2 {
                _ = openIntoPane(index: 1, url: files[1])
            }
            windowModel.setActivePane(0)
            let ignored = max(0, files.count - 2)
            if ignored > 0 { notifyIgnored(count: ignored) }
        case .addSecond:
            // First opens as pane 2; all additional files are ignored.
            guard openIntoPane(index: 1, url: first) else { return }
            windowModel.setActivePane(1)
            let ignored = max(0, files.count - 1)
            if ignored > 0 { notifyIgnored(count: ignored) }
        }
        refreshMode()
    }

    private func openableFiles(from urls: [URL]) -> [URL] {
        let files = urls.filter(isOpenableFile)
        if files.count < urls.count {
            presentAlert(title: "Some files could not be opened",
                         message: "Directories and packages are not supported.")
        }
        return files
    }

    private func notifyIgnored(count: Int) {
        let noun = count == 1 ? "file was" : "files were"
        presentAlert(title: "Additional files ignored",
                     message: "\(count) \(noun) not opened because only two files can be compared at once.")
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
            SandboxBookmarkStore.shared.record(url)
            return true
        } catch {
            presentFileError("Could not open file.", error, url: url)
            return false
        }
    }

    private func isOpenableFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == false && values?.isPackage != true
    }

    // MARK: - Save / Save As / Revert (§5)

    @objc func saveDocument() {
        let pane = activePane
        guard pane.isOpen else { return }
        do {
            try pane.save()
        } catch DocumentError.fileIsReadOnly {
            presentSaveAs(for: pane)  // §5.4: read-only file auto-redirects to Save As
        } catch {
            presentFileError("Save failed.", error, url: pane.document?.url)
        }
    }

    @objc func saveDocumentAs() {
        presentSaveAs(for: activePane)
    }

    /// Runs a Save As sheet for the given pane (active pane, or a specific pane
    /// from an external-change conflict, §5.5).
    private func presentSaveAs(for pane: PaneViewModel) {
        guard pane.isOpen else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = pane.status.fileName
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: view.window ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try pane.saveAs(to: url)
                SandboxBookmarkStore.shared.record(url)
            } catch {
                self.presentFileError("Save As failed.", error, url: url)
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
            presentFileError("Revert failed.", error, url: pane.document?.url)
        }
    }

    // MARK: - External change detection (§5.5)

    /// Wires each pane's watcher to the conflict prompt. Closures capture the
    /// specific pane objects, not indices, because closing pane 1 swaps the
    /// pane1/pane2 objects in WindowViewModel.
    private func wireExternalChangeDetection() {
        let pane1 = windowModel.pane1
        let pane2 = windowModel.pane2
        // Capture the pane objects weakly: the closures live on the panes, so a
        // strong capture would be a retain cycle. Weak keeps them equal-lifetime.
        pane1.onExternalChange = { [weak self, weak pane1] in
            guard let pane1 else { return }
            self?.presentExternalChange(for: pane1)
        }
        pane2.onExternalChange = { [weak self, weak pane2] in
            guard let pane2 else { return }
            self?.presentExternalChange(for: pane2)
        }
    }

    /// Prompt for a file that changed on disk (§5.5): reload/keep when clean;
    /// reload-and-discard / keep / save-as when dirty.
    private func presentExternalChange(for pane: PaneViewModel) {
        guard pane.isOpen else { return }
        let name = pane.status.fileName
        if pane.status.isDirty {
            let alert = NSAlert()
            alert.messageText = "File changed on disk"
            alert.informativeText = "“\(name)” has been changed by another program and has unsaved local changes."
            alert.addButton(withTitle: "Reload and Discard Changes")
            alert.addButton(withTitle: "Keep Local Changes")
            alert.addButton(withTitle: "Save As…")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    try pane.revert()
                } catch {
                    presentFileError("Reload failed.", error, url: pane.document?.url)
                }
            case .alertThirdButtonReturn:
                presentSaveAs(for: pane)
            default:
                break  // keep local changes
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "File changed on disk"
            alert.informativeText = "“\(name)” has been changed by another program. Reload to see the latest version?"
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Keep Current Contents")
            if alert.runModal() == .alertFirstButtonReturn {
                do {
                    try pane.revert()
                } catch {
                    presentFileError("Reload failed.", error, url: pane.document?.url)
                }
            }
        }
    }

    // MARK: - Pane / window closing (§3.5/3.6)

    /// File > Close (Cmd+W, "close document"): the active pane is the
    /// document, so it closes — in comparison mode this returns to single-file
    /// mode (with pane 2 promoted when pane 1 closes); closing the last pane
    /// returns to empty mode. With no panes open there is nothing to close, so
    /// the window closes instead.
    @objc func closeDocument() {
        guard windowModel.hasOpenFile else {
            view.window?.performClose(nil)
            return
        }
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
                    presentFileError("Save failed.", error, url: pane.document?.url)
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

    @objc func fillSelectionWithBytes() {
        let pane = activePane
        guard pane.isOpen, !pane.hexSelection().isEmpty else { return }
        let sheet = FillSheetController(selectionCount: pane.hexSelection().count) { [weak self] pattern in
            self?.activePane.fillSelection(with: pattern)
        }
        presentAsSheet(sheet)
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

    /// View > Word Size (§6): re-groups the hex dump into words of this size.
    @objc func setWordSize(_ sender: Any?) {
        guard let size = (sender as? NSMenuItem).flatMap({ WordSize(rawValue: $0.tag) }) else { return }
        WordSize.set(size)
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

    /// Edit > Find (Cmd+F): shows the non-modal Find bar at the top of the
    /// window (§11).
    @objc func findPattern() {
        let pane = activePane
        guard pane.isOpen else { return }
        showFindBar()
    }

    private func showFindBar() {
        contentTopToView.isActive = false
        contentTopToFindBar.isActive = true
        findBar.isHidden = false
        view.layoutSubtreeIfNeeded()
        findBar.prepareForShow()
    }

    private func hideFindBar() {
        findBar.isHidden = true
        contentTopToFindBar.isActive = false
        contentTopToView.isActive = true
        findTask?.cancel()
        findOperation?.finish()
        focusActiveHexView()
    }

    /// Launches a background search from the find bar. A new search cancels any
    /// in-flight one (rapid < > presses), and the bar stays open — only the
    /// selection moves (§11). The search runs as a `BackgroundOperation`, so
    /// its name, progress and (×) appear in the active pane's status bar while
    /// it runs and it can be cancelled (§14.4).
    private func runSearch(pattern: SearchPattern, direction: SearchDirection, caseSensitive: Bool) {
        findTask?.cancel()
        findOperation?.finish()
        let operation = BackgroundOperation(name: "Searching…") { [weak self] in
            self?.findTask?.cancel()
        }
        findOperation = operation
        activeFilePane?.beginOperation(operation)
        findTask = Task { [weak self] in
            guard let self else { return }
            let found = await self.performFind(pattern: pattern, direction: direction,
                                               caseSensitive: caseSensitive, operation: operation)
            operation.finish()
            guard !Task.isCancelled else { return }
            if !found {
                self.showFindMessage("No match found.")
            }
        }
    }

    /// Runs a search off the main thread and, on a match, selects it in the
    /// active pane (§13.8, §14.4, §18 #10). `operation` receives the search's
    /// progress so the status bar advances as the scan covers the file.
    private func performFind(pattern: SearchPattern, direction: SearchDirection, caseSensitive: Bool,
                             operation: BackgroundOperation) async -> Bool {
        let pane = activePane
        guard pane.isOpen, let storage = pane.document?.storage else { return false }
        // Find Next starts after the current selection (so it never re-selects
        // the match just found); Find Previous starts at the selection's start
        // (so it moves back). With no selection both anchor on the caret.
        let selection = pane.hexSelection()
        let from = selection.isEmpty ? pane.caretOffset
            : direction == .forward ? selection.end : selection.start
        let background = Task.detached(priority: .userInitiated) {
            do {
                return try SearchEngine.find(pattern: pattern.bytes, in: storage, from: from, direction: direction,
                                             caseSensitive: caseSensitive,
                                             shouldCancel: { Task.isCancelled },
                                             progress: { operation.report($0) })
            } catch is CancellationError {
                return nil
            } catch {
                return nil
            }
        }
        let range = await withTaskCancellationHandler(
            operation: { await background.value },
            onCancel: { background.cancel() }
        )
        guard !Task.isCancelled, let range, pane.isOpen else { return false }
        pane.select(range: range)
        // Show the match mid-pane: a plain reveal only scrolls the found row to
        // the nearest edge (bottom after Find Next, top after Find Previous) (§11).
        activeFilePane?.revealSelectionCentered()
        // A search launched from the find bar must leave focus in the pattern
        // field so a subsequent Enter re-searches; only when the bar is hidden
        // does the search hand focus to the hex view.
        if findBar.isHidden {
            focusActiveHexView()
        } else {
            findBar.focusPatternField()
        }
        return true
    }

    /// Beeps and flashes `message` in the active pane's status bar (used for
    /// parse errors and empty search results from the Find bar, §11).
    private func showFindMessage(_ message: String) {
        NSSound.beep()
        activeFilePane?.showTransientMessage(message)
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

    /// Shows a file-operation error, upgrading sandbox/permission denials to a
    /// clear "grant access" prompt (§16 sandbox access denied).
    private func presentFileError(_ title: String, _ error: Error, url: URL?) {
        if isSandboxAccessDenied(error) {
            let name = url?.lastPathComponent ?? "the file"
            presentAlert(title: "Access denied",
                         message: "DumpCompare cannot access “\(name)”. Choose it again with File > Open to grant access.")
        } else {
            presentError(title, error)
        }
    }

    private func isSandboxAccessDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == EACCES {
            return true
        }
        return false
    }

    // MARK: - Zoom-to-fit (§3.1)

    /// Ideal content width the window should be when zoomed (double-click on the
    /// title bar / Window > Zoom): the hex grid width for a single pane, or
    /// both grids plus the splitter divider for a left/right comparison. A
    /// stacked comparison keeps the wider of the two panes' grids.
    private func standardContentWidth() -> CGFloat {
        switch mode {
        case .singleFile:
            return activeFilePane?.contentFitWidth ?? 0
        case .comparison:
            guard let comparisonView else { return 0 }
            let w1 = comparisonView.paneView1.contentFitWidth
            let w2 = comparisonView.paneView2.contentFitWidth
            // Same source of truth as ComparisonView's layout toggle (§3.3).
            let isVertical = UserDefaults.standard.object(forKey: "ComparisonPaneLayoutIsVertical") as? Bool ?? true
            return isVertical ? w1 + w2 + comparisonView.splitView.dividerThickness : max(w1, w2)
        case .empty:
            return 0
        }
    }

    /// Ideal content height the window should be when zoomed (double-click on
    /// the title bar / Window > Zoom): the taller pane's full hex content plus
    /// its header and status bar — the height needed to show the biggest loaded
    /// file without scrolling. The empty state has no content, so the default
    /// zoom frame is kept.
    private func standardContentHeight() -> CGFloat {
        switch mode {
        case .singleFile:
            return activeFilePane?.contentFitHeight ?? 0
        case .comparison:
            guard let comparisonView else { return 0 }
            return max(comparisonView.paneView1.contentFitHeight,
                       comparisonView.paneView2.contentFitHeight)
        case .empty:
            return 0
        }
    }
}

// MARK: - Window closing (§3.6)

extension MainViewController: NSWindowDelegate {
    /// Double-click on the title bar / Window > Zoom sizes the window to the
    /// hex content instead of the default zoom-to-max: the width fits the hex
    /// grid(s), and the height stretches to show the taller loaded file's hex
    /// grid without scrolling — both capped at the screen's visible size when
    /// the content is larger (§3.1). The top edge stays put so the window grows
    /// or shrinks from the bottom. In the empty state there is no hex content,
    /// so the default zoom frame is kept.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let contentWidth = standardContentWidth()
        let contentHeight = standardContentHeight()
        guard contentWidth > 0, contentHeight > 0 else { return defaultFrame }

        var frame = window.frame
        let oldTop = frame.origin.y + frame.height
        let screen = window.screen ?? NSScreen.main
        // Convert the needed content height to a window-frame height (adds the
        // title bar, the only chrome outside the pane itself).
        let frameHeight = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 0, height: contentHeight)).height
        frame.size.width = min(contentWidth, screen?.visibleFrame.width ?? contentWidth)
        frame.size.height = min(frameHeight, screen?.visibleFrame.height ?? frameHeight)
        // Anchor the top edge and keep the window fully on the visible screen.
        frame.origin.y = oldTop - frame.size.height
        if let screen {
            frame.origin.y = min(max(frame.origin.y, screen.visibleFrame.minY),
                                 screen.visibleFrame.maxY - frame.size.height)
        }
        return frame
    }

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
                    presentFileError("Could not save “\(pane.status.fileName)”.", error, url: pane.document?.url)
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
             #selector(undoEdit),
             #selector(redoEdit),
             #selector(pasteWrite),
             #selector(pasteInsert),
             #selector(deleteBytes),
             #selector(selectBlock),
             #selector(goToPosition),
             #selector(findPattern),
             #selector(selectAllBytes):
            return activePane.isOpen
        case #selector(fillSelectionWithBytes):
            let pane = activePane
            return pane.isOpen && !pane.hexSelection().isEmpty
        case #selector(copySelection):
            let pane = activePane
            return pane.isOpen && !pane.hexSelection().isEmpty
        case #selector(nextDifference),
             #selector(previousDifference),
             #selector(nextSameBlock),
             #selector(previousSameBlock),
             #selector(togglePaneLayout):
            return mode == .comparison
        case #selector(setWordSize(_:)):
            // Radio state: check the item matching the current word size (§6).
            menuItem.state = menuItem.tag == WordSize.current.rawValue ? .on : .off
            return true
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
