import Foundation

/// Errors specific to the document model.
public enum DocumentError: Error, Equatable, Sendable {
    /// The target file cannot be written; the UI maps this to a Save As prompt.
    case fileIsReadOnly
    /// The storage cannot be saved (the save path requires `EditOverlayStorage`).
    case unsupportedStorage
}

/// Where a join places the source's bytes (§22.1): before the content or after
/// it. Two positions rather than an arbitrary offset — the two commands are
/// "Insert File at Start…" and "Append File…", and a join at any other offset
/// would be an insert-and-shift the user did not ask for.
public enum JoinPosition: Sendable {
    case start
    case end
}

/// Errors thrown by `BinaryDocument.join` (§22).
public enum JoinError: Error, Equatable, Sendable {
    /// The source has no bytes; joining it would add nothing and only detach the
    /// document from its file, so it is refused before anything changes.
    case emptySource
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

    /// Fired exactly when a transaction is committed to the undo history — a
    /// forward edit, or the close of a coalesced typing group. Not fired for
    /// undo/redo (which restore, not record) or a cancelled group. The
    /// `PaneViewModel` uses it to push a parallel segment snapshot so undo can
    /// restore the partition (§21.2). `nil` under pure unit tests.
    public var onTransactionCommitted: (() -> Void)?

    /// The placeholder a detached document points at: a temp-dir path with no
    /// file behind it, giving the document an identity until a real location is
    /// chosen (§22.2). Shared by the join's detach and the pane's `openUntitled`.
    public static let placeholderURL: URL =
        FileManager.default.temporaryDirectory.appendingPathComponent("Untitled")

    /// Whether the document is attached to a real file, as opposed to the
    /// placeholder a join detaches it to (§22.2). The pane reads this after an
    /// undo/redo to follow the document's attachment (watcher, `isUntitled`).
    public var isAttached: Bool { url != Self.placeholderURL }

    /// One join's mark: the serial of its transaction, and the file attachment
    /// the document had before that join detached it (§22.2).
    private struct JoinMark {
        let serial: UInt64
        let url: URL
        let identity: FileIdentity
        let readOnly: Bool
    }
    /// The joins sitting on the undo stack, oldest first — a stack, not a single
    /// slot: joining twice and undoing twice has to give the document back the
    /// file the FIRST join left, and one slot held only the second join's
    /// attachment, which by then was the placeholder. Undoing both left a
    /// document byte-identical to its file yet still detached from it.
    private var joinMarks: [JoinMark] = []
    /// The joins that have been undone and could still be redone. Discarded
    /// whenever a forward transaction clears the redo stack.
    private var undoneJoinMarks: [JoinMark] = []

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

    // MARK: - Join (document-level, §22)

    /// The size of each streamed chunk when joining: the same 1 MiB the
    /// segment writer and replacer use, so a large source is never read whole
    /// into memory (CLAUDE.md).
    static let joinChunkSize = 1024 * 1024

    /// Joins the bytes of `source` into this document, at the start or the end
    /// (§22.1). The source is streamed in `joinChunkSize` chunks — each chunk
    /// is inserted at the running offset, so its bytes land in order and the
    /// original content stays after them (an insert at the start pushes the
    /// original right; an append leaves it in place) — and the whole join is
    /// one undo transaction: the edit group coalesces the chunks into a single
    /// commit, so `onTransactionCommitted` fires exactly once.
    ///
    /// The join is a document-level act (§22.2): it detaches the document from
    /// the file it came from (the result is an untitled, never-saved document),
    /// but it is **undoable** — the byte insert is a normal transaction on the
    /// undo stack, and the pre-join file attachment is remembered so undoing the
    /// join re-attaches the document to the original file. The join stacks on
    /// top of any earlier edits, which undo as usual. The document is left dirty
    /// so a close still warns. A mid-stream failure cancels the group and
    /// rethrows with the document unchanged.
    public func join(contentsOf source: any ByteStorage, at position: JoinPosition) throws {
        guard source.size > 0 else { throw JoinError.emptySource }
        // The file the document is attached to right now, so undoing this join
        // can re-attach to it (§22.2). Captured before the insert, which is what
        // commits the transaction.
        let attachmentBeforeJoin = (url: url, identity: identity, readOnly: readOnly)
        let anchor: UInt64 = (position == .start) ? 0 : storage.size
        beginEditGroup()
        do {
            var at = anchor
            var readOffset: UInt64 = 0
            while readOffset < source.size {
                let chunk = try source.read(at: readOffset, length: Self.joinChunkSize)
                guard !chunk.isEmpty else { break }
                try insert(at: at, bytes: chunk)
                at += UInt64(chunk.count)
                readOffset += UInt64(chunk.count)
            }
            endEditGroup()
        } catch {
            try? cancelEditGroup()
            throw error
        }
        // The caret goes to the start of the added part (§22.5) — the byte
        // boundary the join opened — and that is what redo restores. The
        // join's transaction just committed (transactionAwaitingSelection is
        // set), so note the caret now, before detachIdentityOnly clears the
        // flag; undo already returns the caret to its pre-join spot via
        // selectionBefore.
        selection = SelectionModel.empty(at: anchor, fileSize: storage.size)
        noteSelectionAfterEdit()
        // Mark the join's transaction so undo/redo can recognise it and
        // re-attach/detach the file (§22.2). Pushed after the commit, which has
        // already cleared the redo side (see `record`).
        if let serial = undoHistory.lastCommittedSerial {
            joinMarks.append(JoinMark(serial: serial,
                                      url: attachmentBeforeJoin.url,
                                      identity: attachmentBeforeJoin.identity,
                                      readOnly: attachmentBeforeJoin.readOnly))
        }
        // Detach the identity only — the history is kept, so the join is undoable.
        detachIdentityOnly()
    }

    /// Detaches the document from the file it came from: the join's result is
    /// an untitled, never-saved document (§22.2), mirroring `openUntitled` —
    /// placeholder URL and writable. The undo history is **not** cleared: the
    /// join is one undo step, and the `JoinMark` it pushes lets undo re-attach
    /// the document to the file it left.
    private func detachIdentityOnly() {
        url = Self.placeholderURL
        identity = FileIdentity(url: Self.placeholderURL)
        readOnly = false
        currentSeriesID = nil
        transactionAwaitingSelection = false
    }

    /// Re-attaches the document to the file it had before a join detached it
    /// (§22.2) — the inverse of `detachIdentityOnly`, called when the join's
    /// transaction is undone.
    private func reattach(_ a: (url: URL, identity: FileIdentity, readOnly: Bool)) {
        url = a.url
        identity = a.identity
        readOnly = a.readOnly
    }

    // MARK: - Duplicate (document-level, §23)

    /// A second document holding a copy of this one's current content — edits
    /// included — as an untitled, never-saved file (§23).
    ///
    /// Like a join, this is a document-level act rather than an edit: the copy is
    /// its own document, attached to nothing (the placeholder URL, writable), and
    /// **dirty with an empty history** — its bytes have never been on disk, so
    /// closing it must warn (§3.6), and there is no earlier state to undo to. The
    /// source is left completely untouched: its file, its edits, its undo history
    /// and its dirty state are all exactly as they were.
    ///
    /// The bytes are not copied. The copy's overlay is built on an immutable
    /// snapshot of this document's content (`EditOverlayStorage.contentSnapshot`)
    /// that the two share for as long as they both live, and each side's later
    /// edits go into its own overlay — so neither can disturb the other, and no
    /// copy is needed when either is modified or closed.
    ///
    /// Throws `unsupportedStorage` when this document's storage is not an
    /// `EditOverlayStorage` (nothing else can be snapshotted), or a
    /// `StorageError` when the snapshot needs a file it cannot write.
    public func duplicate() throws -> BinaryDocument {
        guard let overlay = storage as? EditOverlayStorage else {
            throw DocumentError.unsupportedStorage
        }
        // The scratch store belongs to the copy: whatever file the snapshot needs
        // lives as long as the copy does, and goes when it does.
        let scratch = TemporaryFileStore()
        let snapshot = try overlay.contentSnapshot(scratch: scratch)
        let copy = BinaryDocument(
            storage: EditOverlayStorage(base: snapshot, tempStore: scratch),
            url: Self.placeholderURL,
            readOnly: false
        )
        // Never-saved content that cannot be undone — the same state a join's
        // history is left in (§22.2), and what makes a close warn.
        copy.undoHistory.clearKeepingDirty()
        return copy
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
        // Undoing a join's transaction re-attaches the document to the file that
        // join left (§22.2). Only the newest join can be the one being undone,
        // and it moves to the redo side so a later redo re-detaches.
        if let mark = joinMarks.last, txns.contains(where: { $0.serial == mark.serial }) {
            reattach((url: mark.url, identity: mark.identity, readOnly: mark.readOnly))
            joinMarks.removeLast()
            undoneJoinMarks.append(mark)
        }
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
        // Redoing a join's transaction re-detaches the document (§22.2), and the
        // mark goes back to the undo side.
        if let mark = undoneJoinMarks.last, txns.contains(where: { $0.serial == mark.serial }) {
            detachIdentityOnly()
            undoneJoinMarks.removeLast()
            joinMarks.append(mark)
        }
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
        // Every edit is gone, joins included: their marks have nothing left to
        // re-attach or re-detach (§22.2).
        joinMarks.removeAll()
        undoneJoinMarks.removeAll()
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
            onTransactionCommitted?()
            // As in `record`: the redo stack is gone, so the joins that sat on
            // it can never be redone.
            undoneJoinMarks.removeAll()
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
            onTransactionCommitted?()
            // A forward edit clears the redo stack, so the joins that were
            // sitting on it can never be redone: drop their marks. Safe on the
            // join's own commit too — `join` pushes its mark AFTER the commit
            // returns, so there is nothing of its own to lose here.
            undoneJoinMarks.removeAll()
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
