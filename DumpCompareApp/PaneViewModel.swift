import Foundation
import DumpCompareCore

/// The visual state of a single byte in the hex grid (§6).
///
/// `isEOF` marks a placeholder cell past the file's end (muted rendering);
/// `isModified` means the byte differs from the last saved file on disk (red
/// foreground); `isDifferent` is the comparison state (background, Milestone 5).
struct HexByteState: Equatable {
    var byte: UInt8 = 0
    var isModified = false
    var isDifferent = false
    var isEOF = false
}

/// Which interactive region the hex caret lives in (§7): hex digits are typed
/// in the hex area, ASCII characters in the ASCII area. Clicking a region moves
/// the caret there.
enum HexInputRegion {
    case hex
    case ascii
}

/// Read-only snapshot of the pane's status-bar fields (§15).
struct PaneStatus: Equatable {
    var fileName = ""
    var fileSize: UInt64 = 0
    var cursorHex = ""
    var cursorDecimal = ""
    var selectionLength: UInt64 = 0
    var isDirty = false
    var isReadOnly = false
    var canUndo = false
    var canRedo = false
}

/// View-model for one file pane (single-file mode; comparison lands in M5).
///
/// Owns the `BinaryDocument`, the hex-typing caret (byte offset + nibble), and
/// the selection. All mutations go through here so the pane can:
/// - record edits via the document (undo/redo, dirty state);
/// - report which bytes are modified relative to the last saved file (red
///   foreground) by comparing against a fresh `FileBackedStorage` of the URL;
/// - notify the view (`onChange`) so it redraws and updates the status bar.
///
/// `PaneViewModel` is `MainActor`-confined (UI on MainActor). It contains no
/// AppKit, keeping the editing rules unit-testable.
@MainActor
final class PaneViewModel: HexViewDataSource {
    private(set) var document: BinaryDocument?
    /// Disk bytes as of the last open/save/revert — the "saved" reference for
    /// modified-byte detection. Recreated whenever the on-disk content is known
    /// to have changed (save, save as, revert) so a stale chunk cache can't
    /// misreport.
    private var savedStorage: FileBackedStorage?

    /// Hex caret: 0 = high nibble, 1 = low nibble of the current byte.
    private(set) var nibble = 0
    /// The interactive region the caret currently targets (§7).
    private(set) var inputRegion: HexInputRegion = .hex
    /// When typing over a selection, the selection being consumed (§7.4).
    private var overwriteSelection: SelectionModel?
    /// Anchor for shift-extended selections.
    private var selectionAnchor: UInt64?
    /// Whether a hex-byte edit group is open (the two nibbles of a byte coalesce
    /// into a single undo step; see `beginTypingGroup`/`endTypingGroup`).
    private var typingGroupOpen = false

    /// The other pane in comparison mode. Selection/caret sync is forwarded
    /// here; nil in single-file mode. Weak to avoid a retain cycle.
    weak var companion: PaneViewModel?

    /// Fired after a byte-mutating edit with the `DiffEdit` describing the
    /// affected region, so the `ComparisonCoordinator` can update the index
    /// (§8.3). Not fired for selection-only changes or undo/redo/revert (those
    /// use `onFullInvalidation`).
    var onEdit: ((DiffEdit) -> Void)?

    /// Fired after an edit that the coordinator cannot represent as a
    /// `DiffEdit` (undo/redo/revert replace the storage wholesale) so it can
    /// rebuild the whole index.
    var onFullInvalidation: (() -> Void)?

    /// Suppresses echo when applying a selection synced from the companion.
    private var isSynchronizingSelection = false

    /// Called after any change so the view can redraw and refresh the status bar.
    var onChange: (() -> Void)?

    /// Whether a document is currently open in this pane.
    var isOpen: Bool { document != nil }

    // MARK: - Document lifecycle

    func open(url: URL) throws {
        let doc = try BinaryDocument(url: url)
        document = doc
        refreshSavedStorage()
        resetEditingState()
    }

    func close() {
        document = nil
        savedStorage = nil
        resetEditingState()
    }

    func save() throws {
        guard let doc = document else { return }
        try doc.save()
        refreshSavedStorage()
        resetEditingState()
    }

    func saveAs(to url: URL) throws {
        guard let doc = document else { return }
        try doc.save(to: url)
        refreshSavedStorage()
        resetEditingState()
    }

    func revert() throws {
        guard let doc = document else { return }
        try doc.revert()
        refreshSavedStorage()
        resetEditingState()
        // Revert replaces the storage wholesale; the comparison must re-read.
        onFullInvalidation?()
    }

    /// The document's live byte storage — the same class instance across edits,
    /// so a comparison coordinator can hold it and always read current bytes.
    var byteStorage: (any ByteStorage)? { document?.storage }

    private func refreshSavedStorage() {
        guard let doc = document else { savedStorage = nil; return }
        savedStorage = try? FileBackedStorage(url: doc.url)
    }

    private func resetEditingState() {
        endTypingGroup()
        nibble = 0
        inputRegion = .hex
        overwriteSelection = nil
        selectionAnchor = nil
    }

    /// Moves the caret's input region to `region` (set when the user clicks the
    /// hex or ASCII area).
    func setInputRegion(_ region: HexInputRegion) {
        inputRegion = region
        notify()
    }

    // MARK: - HexViewDataSource

    var fileSize: UInt64 { document?.size ?? 0 }

    func hexByteStates(in range: Range<UInt64>) -> [HexByteState] {
        guard let doc = document, range.lowerBound < range.upperBound else { return [] }
        let count = Int(range.upperBound - range.lowerBound)
        var states = [HexByteState](repeating: HexByteState(isEOF: true), count: count)

        let size = doc.size
        let start = min(range.lowerBound, size)
        guard start < size else { return states }
        let presentCount = Int(size - start)
        let n = min(count, presentCount)

        let current = (try? doc.read(at: start, length: n)) ?? []
        let saved = (try? savedStorage?.read(at: start, length: n)) ?? []
        let savedSize = savedStorage?.size ?? 0
        // Live visible diff (§8.3 rule 6): read the companion's bytes for the
        // same absolute range. Immediate, exact, and self-consistent with the
        // background block index (which only drives navigation).
        let other = companionBytes(in: start..<start + UInt64(n))
        let otherSize = companion?.fileSize ?? 0

        for i in 0..<n {
            let offset = start + UInt64(i)
            let byte = current.indices.contains(i) ? current[i] : 0
            var isModified = false
            if offset >= savedSize {
                isModified = true
            } else if saved.indices.contains(i) {
                isModified = saved[i] != byte
            }
            var isDifferent = false
            if let other {
                if offset >= otherSize {
                    // Only this pane has a byte here — EOF-only difference (§8.1).
                    isDifferent = true
                } else if other.indices.contains(i) {
                    isDifferent = other[i] != byte
                }
            }
            states[Int(offset - range.lowerBound)] = HexByteState(
                byte: byte, isModified: isModified, isDifferent: isDifferent, isEOF: false
            )
        }
        return states
    }

    /// The companion pane's bytes for `range`, or nil when not in comparison
    /// mode. Reads fewer bytes than requested past the companion's EOF.
    private func companionBytes(in range: Range<UInt64>) -> [UInt8]? {
        guard let other = companion, let doc = other.document else { return nil }
        return (try? doc.read(at: range.lowerBound, length: Int(range.count))) ?? []
    }

    func hexSelection() -> SelectionModel {
        document?.selection ?? SelectionModel.empty(at: 0, fileSize: 0)
    }

    func hexCaretNibble() -> Int { nibble }

    func hexInputRegion() -> HexInputRegion { inputRegion }

    // MARK: - Status

    var status: PaneStatus {
        guard let doc = document else { return PaneStatus() }
        let caret = doc.selection.start
        return PaneStatus(
            fileName: doc.url.lastPathComponent,
            fileSize: doc.size,
            cursorHex: String(format: "0x%X", caret),
            cursorDecimal: "\(caret)",
            selectionLength: doc.selection.count,
            isDirty: doc.isDirty,
            isReadOnly: doc.readOnly,
            canUndo: doc.canUndo,
            canRedo: doc.canRedo
        )
    }

    var caretOffset: UInt64 { document?.selection.start ?? 0 }

    // MARK: - Hex input (§7)

    /// Types one hex digit (0–15) into the current nibble (§7: hex nibble
    /// input; after the second nibble the caret advances to the next byte).
    /// The two nibbles of a byte coalesce into one undo step.
    func typeHexNibble(_ digit: Int) {
        guard let doc = document, (0...15).contains(digit) else { return }

        if nibble == 0 {
            prepareForTyping()
            let offset = typingOffset(doc)
            let old = byteAt(offset) ?? 0
            beginTypingGroup()
            try? doc.overwrite(range: offset..<offset + 1, with: [(UInt8(digit) << 4) | (old & 0x0F)])
            nibble = 1
            onEdit?(.overwrite(range: offset..<offset + 1))
        } else {
            let offset = typingOffset(doc)
            let old = byteAt(offset) ?? 0
            try? doc.overwrite(range: offset..<offset + 1, with: [(old & 0xF0) | UInt8(digit)])
            nibble = 0
            endTypingGroup()
            advanceAfterByte()
            onEdit?(.overwrite(range: offset..<offset + 1))
        }
        notify()
    }

    /// Types one ASCII character (only printable 0x20…0x7E are accepted; the
    /// rest are ignored with no effect, §7). A whole-byte edit: one undo step.
    func typeASCII(_ byte: UInt8) {
        guard (0x20...0x7E).contains(byte), let doc = document else { return }
        endTypingGroup()
        prepareForTyping()
        let offset = typingOffset(doc)
        try? doc.overwrite(range: offset..<offset + 1, with: [byte])
        nibble = 0
        advanceAfterByte()
        onEdit?(.overwrite(range: offset..<offset + 1))
        notify()
    }

    /// Delete: fill the selection (or the current byte) with 0x00 (§7.3).
    func deleteForward() {
        guard let doc = document else { return }
        endTypingGroup()
        if !doc.selection.isEmpty {
            fillSelection()
            return
        }
        let caret = doc.selection.start
        guard caret < doc.size else { return }
        try? doc.fillZero(in: caret..<caret + 1)
        nibble = 0
        onEdit?(.overwrite(range: caret..<caret + 1))
        notify()
    }

    /// Backspace: fill the selection (or the previous byte) with 0x00 and move
    /// the caret back (§7.3).
    func deleteBackward() {
        guard let doc = document else { return }
        endTypingGroup()
        if !doc.selection.isEmpty {
            fillSelection()
            return
        }
        let caret = doc.selection.start
        guard caret > 0 else { return }
        try? doc.fillZero(in: (caret - 1)..<caret)
        doc.setSelection(SelectionModel.empty(at: caret - 1, fileSize: doc.size))
        nibble = 0
        onEdit?(.overwrite(range: (caret - 1)..<caret))
        notify()
    }

    /// Fill Selection with Zero (menu command, §7.3).
    func fillSelectionWithZero() {
        guard let doc = document, !doc.selection.isEmpty else { return }
        endTypingGroup()
        fillSelection()
    }

    /// True length-changing delete (Edit > Delete Bytes…, §7.2, confirmed by
    /// the UI before calling).
    func deleteBytes(in range: Range<UInt64>) throws {
        guard let doc = document else { return }
        endTypingGroup()
        try doc.delete(range: range)
        doc.setSelection(SelectionModel.empty(at: range.lowerBound, fileSize: doc.size))
        nibble = 0
        overwriteSelection = nil
        onEdit?(.delete(range: range))
        notify()
    }

    /// Paste Write: overwrite from the caret (or selection start), extending
    /// past EOF without confirmation (§7.1, §12.2).
    func pasteWrite(_ bytes: [UInt8]) throws {
        guard let doc = document, !bytes.isEmpty else { return }
        let start = doc.selection.start
        let range = start..<start + UInt64(bytes.count)
        try doc.overwrite(range: range, with: bytes)
        doc.setSelection(SelectionModel.empty(at: range.upperBound, fileSize: doc.size))
        resetEditingState()
        // The engine's `.overwrite` recomputes `[start, end)`, which covers the
        // paste even when it extends past EOF (the recompute reads current bytes).
        onEdit?(.overwrite(range: range))
        notify()
    }

    /// Paste Insert: insert before the caret (confirmed by the UI, §7.2/§12.3).
    func pasteInsert(_ bytes: [UInt8]) throws {
        guard let doc = document, !bytes.isEmpty else { return }
        let at = doc.selection.start
        try doc.insert(at: at, bytes: bytes)
        doc.setSelection(SelectionModel.empty(at: at + UInt64(bytes.count), fileSize: doc.size))
        resetEditingState()
        onEdit?(.insert(at: at, length: UInt64(bytes.count)))
        notify()
    }

    // MARK: - Caret & selection

    func moveCaret(by delta: Int64, extendSelection: Bool = false) {
        guard let doc = document else { return }
        let current = doc.selection.start
        var target: UInt64
        if delta >= 0 {
            target = min(doc.size, current + UInt64(delta))
        } else {
            let amount = UInt64(-delta)
            target = amount > current ? 0 : current - amount
        }
        moveCaret(to: target, extendSelection: extendSelection)
    }

    func moveCaret(to offset: UInt64, extendSelection: Bool = false) {
        guard let doc = document else { return }
        let clamped = min(offset, doc.size)
        if extendSelection {
            let anchor = selectionAnchor
                ?? (clamped >= doc.selection.start ? doc.selection.start : doc.selection.end)
            selectionAnchor = anchor
            doc.setSelection(SelectionModel(start: anchor, end: clamped, fileSize: doc.size))
        } else {
            selectionAnchor = nil
            doc.setSelection(SelectionModel.empty(at: clamped, fileSize: doc.size))
        }
        nibble = 0
        overwriteSelection = nil
        notify()
    }

    func selectAll() {
        guard let doc = document else { return }
        doc.setSelection(SelectionModel(start: 0, end: doc.size, fileSize: doc.size))
        resetEditingState()
        notify()
    }

    func setSelection(_ selection: SelectionModel) {
        guard let doc = document else { return }
        doc.setSelection(selection)
        resetEditingState()
        notify()
    }

    /// Selects `range`, clamped to the file size (used by Find and Select Block).
    func select(range: Range<UInt64>) {
        guard let doc = document else { return }
        doc.setSelection(SelectionModel(start: range.lowerBound, end: range.upperBound, fileSize: doc.size))
        resetEditingState()
        notify()
    }

    /// Finds `pattern` in the current (unsaved) contents (§11). `from` is the
    /// offset at which to start; searches read live storage so pending edits are
    /// included. Returns the match range, or nil when not found.
    func find(pattern: [UInt8], from offset: UInt64, direction: SearchDirection) throws -> Range<UInt64>? {
        guard let doc = document else { return nil }
        return try SearchEngine.find(pattern: pattern, in: doc.storage, from: offset, direction: direction)
    }

    // MARK: - Undo / Redo

    @discardableResult
    func undo() throws -> Bool {
        guard let doc = document else { return false }
        let ok = try doc.undo()
        resetEditingState()
        // Undo applies inverse ops directly to storage; the comparison must
        // re-derive the whole index rather than apply a single DiffEdit.
        if ok { onFullInvalidation?() }
        notify()
        return ok
    }

    @discardableResult
    func redo() throws -> Bool {
        guard let doc = document else { return false }
        let ok = try doc.redo()
        resetEditingState()
        if ok { onFullInvalidation?() }
        notify()
        return ok
    }

    // MARK: - Internals

    /// When a selection exists and the user types, switch to consuming it one
    /// byte at a time from its start (§7.4).
    private func prepareForTyping() {
        guard let doc = document else { return }
        if overwriteSelection == nil, !doc.selection.isEmpty {
            overwriteSelection = doc.selection
            nibble = 0
            // Show the still-unconsumed part of the selection shrinking as we type.
            doc.setSelection(SelectionModel(start: doc.selection.start, end: doc.selection.end, fileSize: doc.size))
        }
    }

    /// The offset the next typed byte lands on: selection start while a
    /// selection is being consumed, otherwise the caret.
    private func typingOffset(_ doc: BinaryDocument) -> UInt64 {
        overwriteSelection?.start ?? doc.selection.start
    }

    private func byteAt(_ offset: UInt64) -> UInt8? {
        guard let doc = document, offset < doc.size else { return nil }
        return (try? doc.read(at: offset, length: 1))?.first
    }

    /// Opens an edit group so the low nibble of the byte being typed coalesces
    /// with its high nibble into a single undo step (§7.5).
    private func beginTypingGroup() {
        guard let doc = document, !typingGroupOpen else { return }
        doc.beginEditGroup()
        typingGroupOpen = true
    }

    /// Closes the edit group opened by `beginTypingGroup`, if any. Called on
    /// every path that leaves the mid-byte state (nibble 1 pending), so a half
    /// typed byte never swallows a later unrelated edit into the same undo step.
    private func endTypingGroup() {
        guard let doc = document, typingGroupOpen else { return }
        doc.endEditGroup()
        typingGroupOpen = false
    }

    /// After a complete typed byte, advance one byte through a consuming
    /// selection, or past the caret.
    private func advanceAfterByte() {
        guard let doc = document else { return }
        if let sel = overwriteSelection {
            let next = sel.start + 1
            if next < sel.end {
                overwriteSelection = SelectionModel(start: next, end: sel.end, fileSize: doc.size)
                doc.setSelection(overwriteSelection!)
            } else {
                overwriteSelection = nil
                doc.setSelection(SelectionModel.empty(at: next, fileSize: doc.size))
            }
        } else {
            doc.setSelection(SelectionModel.empty(at: doc.selection.start + 1, fileSize: doc.size))
        }
    }

    private func fillSelection() {
        guard let doc = document else { return }
        let start = doc.selection.start
        let end = doc.selection.end
        try? doc.fillZero(in: start..<end)
        doc.setSelection(SelectionModel.empty(at: start, fileSize: doc.size))
        nibble = 0
        overwriteSelection = nil
        onEdit?(.overwrite(range: start..<end))
        notify()
    }

    /// Applies a selection synced from `other` (the active pane), clamped to
    /// this pane's own file size (§9: shorter pane clamps to EOF/missing area).
    func syncSelectionFromCompanion(_ other: PaneViewModel) {
        guard let doc = document, !isSynchronizingSelection else { return }
        isSynchronizingSelection = true
        defer { isSynchronizingSelection = false }
        let selection = other.hexSelection().clamped(to: doc.size)
        doc.setSelection(selection)
        notify()
    }

    private func notify() {
        if !isSynchronizingSelection {
            companion?.syncSelectionFromCompanion(self)
        }
        onChange?()
    }
}

// MARK: - HexEditorDelegate

extension PaneViewModel: HexEditorDelegate {
    func hexEditor(_ editor: HexView, typeHexNibble digit: Int) {
        typeHexNibble(digit)
    }

    func hexEditor(_ editor: HexView, typeASCIIByte byte: UInt8) {
        typeASCII(byte)
    }

    func hexEditorDeleteForward(_ editor: HexView) {
        deleteForward()
    }

    func hexEditorDeleteBackward(_ editor: HexView) {
        deleteBackward()
    }

    func hexEditor(_ editor: HexView, moveCaretBy delta: Int64, extendSelection: Bool) {
        moveCaret(by: delta, extendSelection: extendSelection)
    }

    func hexEditor(_ editor: HexView, moveCaretTo offset: UInt64, extendSelection: Bool) {
        moveCaret(to: offset, extendSelection: extendSelection)
    }

    func hexEditorSelectAll(_ editor: HexView) {
        selectAll()
    }

    func hexEditor(_ editor: HexView, didClickAt offset: UInt64, region: HexInputRegion, extendSelection: Bool) {
        moveCaret(to: offset, extendSelection: extendSelection)
        setInputRegion(region)
    }
}
