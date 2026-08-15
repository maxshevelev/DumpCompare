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
    public init(storage: any EditableByteStorage, url: URL) {
        self.storage = storage
        self.url = url
        self.identity = FileIdentity(url: url)
        self.readOnly = !FileManager.default.isWritableFile(atPath: url.path)
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
    public func fillZero(in range: Range<UInt64>) throws {
        try fill(pattern: [0], in: range)
    }

    /// Overwrites `range` by repeating `pattern` to cover it (§7.3 fill dialog).
    /// The final repetition is truncated when the range length isn't a multiple
    /// of the pattern length; a pattern longer than the range writes only its
    /// prefix. Recorded as an `.overwrite` so undo restores the original bytes.
    public func fill(pattern: [UInt8], in range: Range<UInt64>) throws {
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
        record([.overwrite(range: start..<end, before: before, after: after)])
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

    @discardableResult
    public func undo() throws -> Bool {
        guard let ops = undoHistory.undo() else { return false }
        for op in ops.reversed() { try applyInverse(op) }
        clampSelection()
        return true
    }

    @discardableResult
    public func redo() throws -> Bool {
        guard let ops = undoHistory.redo() else { return false }
        for op in ops { try applyForward(op) }
        clampSelection()
        return true
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
        selection = SelectionModel.empty(at: 0, fileSize: base.size)
    }

    // MARK: - Edit grouping (typing sessions coalesce into one undo)

    public func beginEditGroup() { groupDepth += 1 }

    public func endEditGroup() {
        groupDepth -= 1
        if groupDepth == 0, !pendingGroupOps.isEmpty {
            undoHistory.record(pendingGroupOps)
            pendingGroupOps.removeAll()
        }
    }

    // MARK: - Selection

    public func setSelection(_ selection: SelectionModel) {
        self.selection = selection.clamped(to: storage.size)
    }

    // MARK: - Internals

    private var groupDepth = 0
    private var pendingGroupOps: [UndoOperation] = []

    private func record(_ ops: [UndoOperation]) {
        if groupDepth > 0 {
            pendingGroupOps.append(contentsOf: ops)
        } else {
            undoHistory.record(ops)
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

    private func applyInverse(_ op: UndoOperation) throws {
        switch op {
        case .overwrite(let range, let before, _):
            try storage.overwrite(range: range, with: before)
        case .insert(let at, let bytes):
            try storage.delete(range: at..<(at + UInt64(bytes.count)))
        case .delete(let range, let bytes):
            try storage.insert(at: range.lowerBound, bytes: bytes)
        }
    }
}
