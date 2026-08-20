import Foundation

/// Errors specific to the document model.
public enum DocumentError: Error, Equatable, Sendable {
    /// The target file cannot be written; the UI maps this to a Save As prompt.
    case fileIsReadOnly
    /// The storage cannot be saved (the save path requires `EditOverlayStorage`).
    case unsupportedStorage
}

/// A single open binary file: the editable storage, its identity, read-only
/// state, undo history, and selection (M2, §4.2, §5, §7.5).
///
/// Every mutation records an undo op, applies it to the storage, and lets the
/// `UndoHistory` checkpoint drive dirty state. Mutations are permitted even on a
/// read-only file (edits live in memory and in temporary files); only saving to
/// the read-only original is rejected — the app auto-redirects to Save As.
///
/// This class is confined to a single thread (the main actor in the app). The
/// underlying storage is thread-safe and may be handed to background consumers
/// (diff, search) directly.
public final class BinaryDocument: @unchecked Sendable {
    public private(set) var storage: any EditableByteStorage
    public private(set) var url: URL
    public private(set) var identity: FileIdentity
    public private(set) var readOnly: Bool
    public private(set) var selection: SelectionModel
    public let undoHistory = UndoHistory()

    // MARK: - Init

    /// Opens `url` for editing. The file must exist and be a regular file.
    public convenience init(url: URL) throws {
        let base = try FileBackedStorage(url: url)
        self.init(storage: EditOverlayStorage(base: base), url: url)
    }

    /// Wraps an existing editable storage (used by tests and alternate backings).
    /// `readOnly` overrides the automatic on-disk check — needed for untitled
    /// in-memory documents, whose placeholder URL has no file yet (and would
    /// therefore look unwritable), but which must be saveable.
    public init(storage: any EditableByteStorage, url: URL, readOnly: Bool? = nil) {
        self.storage = storage
        self.url = url
        self.identity = FileIdentity(url: url)
        self.readOnly = readOnly ?? !FileManager.default.isWritableFile(atPath: url.path)
        self.selection = SelectionModel.empty(at: 0, fileSize: storage.size)
    }

    // MARK: - Reading

    public var size: UInt64 { storage.size }

    public func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        try storage.read(at: offset, length: length)
    }

    // MARK: - Mutations (each records an undo op)

    /// Overwrites `bytes` at `range.lowerBound`, extending past EOF when needed.
    public func overwrite(range: Range<UInt64>, with bytes: [UInt8]) throws {
        record(try applyOverwrite(start: range.lowerBound, bytes: bytes))
        clampSelection()
    }

    /// Inserts `bytes` at `offset` (clamped to EOF), shifting subsequent bytes.
    public func insert(at offset: UInt64, bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        let at = min(offset, storage.size)
        try storage.insert(at: at, bytes: bytes)
        record([.insert(at: at, bytes: bytes)])
        clampSelection()
    }

    /// Removes `range`, shifting subsequent bytes.
    public func delete(range: Range<UInt64>) throws {
        let start = min(range.lowerBound, storage.size)
        let end = min(range.upperBound, storage.size)
        guard end > start else { return }
        let removed = try storage.read(at: start, length: Int(end - start))
        try storage.delete(range: start..<end)
        record([.delete(range: start..<end, bytes: removed)])
        clampSelection()
    }

    /// Overwrites `range` with zero bytes (§7.3: Delete/Backspace fill 0x00).
    /// `caretAfter` overrides the caret position redo restores (a fill leaves
    /// the caret at the range start, not the upper bound).
    public func fillZero(in range: Range<UInt64>, caretAfter: UInt64? = nil) throws {
        try fill(pattern: [0], in: range, caretAfter: caretAfter)
    }

    /// Overwrites `range` by repeating `pattern` to cover it (§7.3 fill dialog).
    /// The final repetition is truncated when the range length isn't a multiple
    /// of the pattern length; a pattern longer than the range writes only its
    /// prefix. Recorded as an `.overwrite` so undo restores the original bytes.
    /// `caretAfter` overrides the caret position redo restores (a fill leaves
    /// the caret at the range start, not the upper bound).
    public func fill(pattern: [UInt8], in range: Range<UInt64>, caretAfter: UInt64? = nil) throws {
        guard !pattern.isEmpty else { return }
        let start = min(range.lowerBound, storage.size)
        let end = min(range.upperBound, storage.size)
        guard end > start else { return }
        let count = Int(end - start)
        let before = try storage.read(at: start, length: count)
        var after = [UInt8]()
        after.reserveCapacity(count)
        for i in 0..<count {
            after.append(pattern[i % pattern.count])
        }
        try storage.overwrite(range: start..<end, with: after)
        record([.overwrite(range: start..<end, before: before, after: after)], caretAfter: caretAfter)
        clampSelection()
    }

    /// Replaces `range` with `bytes`: writes `bytes` from the range start, then
    /// deletes the leftover tail when `bytes` is shorter than the range. This is
    /// what "typed text overwrites a selection" needs (§7.1).
    public func replace(range: Range<UInt64>, with bytes: [UInt8]) throws {
        var ops = try applyOverwrite(start: range.lowerBound, bytes: bytes)
        let writtenEnd = range.lowerBound + UInt64(bytes.count)
        let leftoverEnd = min(range.upperBound, storage.size)
        if leftoverEnd > writtenEnd {
            let removed = try storage.read(at: writtenEnd, length: Int(leftoverEnd - writtenEnd))
            try storage.delete(range: writtenEnd..<leftoverEnd)
            ops.append(.delete(range: writtenEnd..<leftoverEnd, bytes: removed))
        }
        record(ops)
        clampSelection()
    }

    // MARK: - Undo / Redo

    /// Reverts the most recent undo step: applies the inverse ops of every
    /// transaction in the gesture (transactions in reverse recording order,
    /// each op's `inverted` in reverse order), restores the selection the
    /// gesture's first edit started from, and returns the net `DiffEdit`
    /// describing the storage change — so a comparison can update
    /// incrementally instead of re-scanning both files.
    ///
    /// `batch == true` asks the history to remove the rest of the current
    /// typing series as one step (the fast-undo window, decided by
    /// `UndoHistory`). `nil` when there is nothing to undo.
    @discardableResult
    public func undo(batch: Bool = false) throws -> DiffEdit? {
        guard let txns = undoHistory.undo(batch: batch) else { return nil }
        var applied: [UndoOperation] = []
        for txn in txns.reversed() {
            applied.append(contentsOf: txn.ops.reversed().map(\.inverted))
        }
        for op in applied { try applyForward(op) }
        selection = txns.first!.selectionBefore.clamped(to: storage.size)
        transactionAwaitingSelection = false
        return DiffEdit.netDiffEdit(ops: applied)
    }

    /// Reapplies the next undone step in its original order (all of a batch's
    /// transactions, in recording order), restores the selection the gesture's
    /// last edit left, and returns the net `DiffEdit` for the storage change
    /// (see `undo(batch:)`). `nil` when there is nothing to redo.
    @discardableResult
    public func redo() throws -> DiffEdit? {
        guard let txns = undoHistory.redo() else { return nil }
        var applied: [UndoOperation] = []
        for txn in txns {
            applied.append(contentsOf: txn.ops)
        }
        for op in applied { try applyForward(op) }
        selection = txns.last!.selectionAfter.clamped(to: storage.size)
        transactionAwaitingSelection = false
        return DiffEdit.netDiffEdit(ops: applied)
    }

    /// Records the selection as the state the last edit left behind, so redo
    /// returns to it. Called by the editing command once it has placed the
    /// selection — the document itself cannot know whether a command collapses
    /// the selection (a fill does) or keeps consuming what is left of it
    /// (typing does). A no-op unless an edit was recorded since the last call.
    public func noteSelectionAfterEdit() {
        guard transactionAwaitingSelection else { return }
        transactionAwaitingSelection = false
        undoHistory.noteSelectionAfterOnLast(selection)
    }

    // MARK: - Save / Revert

    public var isDirty: Bool { undoHistory.isDirty }
    public var canUndo: Bool { undoHistory.canUndo }
    public var canRedo: Bool { undoHistory.canRedo }

    /// Saves to `target`, or to the document's own URL when `target` is nil.
    /// A Save As rebases the document (and its storage) onto the new file.
    public func save(to target: URL? = nil) throws {
        let destination = target ?? url
        if destination.path == url.path, readOnly {
            throw DocumentError.fileIsReadOnly
        }
        if FileManager.default.fileExists(atPath: destination.path),
           !FileManager.default.isWritableFile(atPath: destination.path) {
            throw DocumentError.fileIsReadOnly
        }
        guard let editable = storage as? EditOverlayStorage else {
            throw DocumentError.unsupportedStorage
        }
        try StorageSaver.save(editable, to: destination)
        editable.rebaseOriginalURL(destination)
        url = destination
        identity = FileIdentity(url: destination)
        readOnly = !FileManager.default.isWritableFile(atPath: destination.path)
        undoHistory.markSaved()
    }

    /// Discards all in-memory edits and reloads the document from `url`.
    public func revert() throws {
        let base = try FileBackedStorage(url: url)
        storage = EditOverlayStorage(base: base)
        identity = FileIdentity(url: url)
        readOnly = !FileManager.default.isWritableFile(atPath: url.path)
        undoHistory.reset()
        currentSeriesID = nil
        transactionAwaitingSelection = false
        selection = SelectionModel.empty(at: 0, fileSize: base.size)
    }

    // MARK: - Edit grouping (typing sessions coalesce into one undo)

    public func beginEditGroup() {
        if groupDepth == 0 { groupStartSelection = selection }
        groupDepth += 1
    }

    public func endEditGroup() {
        groupDepth -= 1
        if groupDepth == 0, !pendingGroupOps.isEmpty {
            undoHistory.record(
                pendingGroupOps,
                selectionBefore: groupStartSelection ?? selection,
                selectionAfter: .empty(at: naturalCaretAfter(pendingGroupOps), fileSize: storage.size),
                seriesID: currentSeriesID
            )
            transactionAwaitingSelection = true
            pendingGroupOps.removeAll()
            groupStartSelection = nil
        }
    }

    /// Cancels the open edit group: reverts the ops collected so far (in
    /// reverse order) and clears the group state, recording **no** transaction.
    /// The selection is restored to the one the group began with. Used to roll
    /// back a half-typed insert-mode byte as if it never happened — the byte
    /// disappears and the tail shifts back, leaving nothing on the undo stack.
    public func cancelEditGroup() throws {
        guard groupDepth > 0 else { return }
        for op in pendingGroupOps.reversed() {
            try applyForward(op.inverted)
        }
        pendingGroupOps.removeAll()
        groupDepth = 0
        selection = (groupStartSelection ?? selection).clamped(to: storage.size)
        groupStartSelection = nil
    }

    // MARK: - Typing series (segmented undo, Variant B)

    /// The id of the typing series currently open, stamped onto every
    /// transaction recorded while it lasts. `nil` outside a series.
    private var currentSeriesID: UInt64?

    /// Opens a typing series: transactions recorded until `endSeries()` share
    /// `id`, so a fast undo can roll the series back in one batch.
    public func beginSeries(_ id: UInt64) {
        currentSeriesID = id
    }

    /// Closes the current typing series (a breaker fired, or the input simply
    /// ended).
    public func endSeries() {
        currentSeriesID = nil
    }

    // MARK: - Selection

    public func setSelection(_ selection: SelectionModel) {
        self.selection = selection.clamped(to: storage.size)
    }

    // MARK: - Internals

    private var groupDepth = 0
    private var pendingGroupOps: [UndoOperation] = []
    /// The selection when the open edit group began (undo of a coalesced typing
    /// session returns to it).
    private var groupStartSelection: SelectionModel?
    /// True between recording a transaction and `noteSelectionAfterEdit`, so a
    /// note cannot attach the selection to an older transaction.
    private var transactionAwaitingSelection = false

    /// Records ops as one transaction, capturing the selection pair:
    /// `selectionBefore` is the current selection (mutations never move it
    /// before recording), `selectionAfter` the override or the natural
    /// post-edit caret of the final op, until the command refines it.
    private func record(_ ops: [UndoOperation], caretAfter: UInt64? = nil) {
        guard !ops.isEmpty else { return }
        if groupDepth > 0 {
            pendingGroupOps.append(contentsOf: ops)
        } else {
            undoHistory.record(
                ops,
                selectionBefore: selection,
                selectionAfter: .empty(at: caretAfter ?? naturalCaretAfter(ops), fileSize: storage.size),
                seriesID: currentSeriesID
            )
            transactionAwaitingSelection = true
        }
    }

    /// The caret position the final op of a transaction naturally leaves:
    /// overwrite/fill end at the range's upper bound, insert at `at+count`,
    /// delete at the range start.
    private func naturalCaretAfter(_ ops: [UndoOperation]) -> UInt64 {
        guard let last = ops.last else { return selection.start }
        switch last {
        case .overwrite(let range, _, _): return range.upperBound
        case .insert(let at, let bytes): return at + UInt64(bytes.count)
        case .delete(let range, _): return range.lowerBound
        }
    }

    private func clampSelection() {
        selection = selection.clamped(to: storage.size)
    }

    /// Applies an overwrite that may extend past EOF, returning the ops. Split
    /// into an overwrite of the existing bytes plus an insert of the new tail so
    /// that undoing shrinks the file back to its previous size.
    private func applyOverwrite(start: UInt64, bytes: [UInt8]) throws -> [UndoOperation] {
        guard !bytes.isEmpty else { return [] }
        let end = start + UInt64(bytes.count)
        let existingEnd = min(end, storage.size)
        var ops: [UndoOperation] = []

        if existingEnd > start {
            let before = try storage.read(at: start, length: Int(existingEnd - start))
            let existingAfter = Array(bytes.prefix(before.count))
            ops.append(.overwrite(range: start..<existingEnd, before: before, after: existingAfter))
            try storage.overwrite(range: start..<existingEnd, with: existingAfter)
        }
        if end > existingEnd {
            let newPart = Array(bytes.dropFirst(Int(existingEnd - start)))
            ops.append(.insert(at: existingEnd, bytes: newPart))
            try storage.append(newPart)
        }
        return ops
    }

    private func applyForward(_ op: UndoOperation) throws {
        switch op {
        case .overwrite(let range, _, let after):
            try storage.overwrite(range: range, with: after)
        case .insert(let at, let bytes):
            try storage.insert(at: at, bytes: bytes)
        case .delete(let range, _):
            try storage.delete(range: range)
        }
    }

}
