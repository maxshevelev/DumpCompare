import Foundation

/// A single reversible byte mutation (decision D4).
///
/// Each case carries everything needed to apply and revert it without re-reading
/// the storage:
/// - `.overwrite` / `.fillZero` carry the bytes before and after, so reverting
///   simply writes `before` back.
/// - `.insert` is reverted by deleting its bytes; `.delete` is reverted by
///   re-inserting the removed bytes at the original offset.
///
/// An overwrite that extended past EOF is never stored as a single op here:
/// `BinaryDocument` splits it into an overwrite of the existing bytes plus an
/// insert of the new tail, so every stored op is length-preserving and reverts
/// without a truncate operation.
public enum UndoOperation: Equatable, Sendable {
    case overwrite(range: Range<UInt64>, before: [UInt8], after: [UInt8])
    case insert(at: UInt64, bytes: [UInt8])
    case delete(range: Range<UInt64>, bytes: [UInt8])
    case fillZero(range: Range<UInt64>, before: [UInt8])
}

/// Linear undo/redo history with a dirty checkpoint (decision D4).
///
/// The history is a list of transactions (each transaction is one or more
/// `UndoOperation`s applied as a unit — a typing session coalesces into one).
/// A cursor separates committed ops (before it) from undone ops (after it).
///
/// Dirty state is defined entirely by the cursor vs a saved checkpoint:
/// `isDirty` is true when the cursor is not where the last `markSaved()` left
/// it. Undoing back to the saved state clears dirty; redoing past it sets it
/// again (§5.1, §17.7).
///
/// This class is confined to a single thread (the document it belongs to).
public final class UndoHistory: @unchecked Sendable {
    private var history: [[UndoOperation]] = []
    private var cursor = 0
    private var savedIndex = 0

    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < history.count }
    /// True when the current state differs from the last saved state.
    public var isDirty: Bool { cursor != savedIndex }
    /// Number of committed transactions (the cursor position).
    public var undoDepth: Int { cursor }

    /// Records a transaction of ops applied to storage. Any undone transactions
    /// (the redo stack) are discarded, because the state has diverged.
    public func record(_ ops: [UndoOperation]) {
        guard !ops.isEmpty else { return }
        if cursor < history.count {
            history.removeSubrange(cursor...)
        }
        history.append(ops)
        cursor = history.count
    }

    /// Reverts the most recent committed transaction, returning its ops (in
    /// committed order) for the caller to apply in reverse. Returns `nil` if
    /// there is nothing to undo.
    @discardableResult
    public func undo() -> [UndoOperation]? {
        guard canUndo else { return nil }
        cursor -= 1
        return history[cursor]
    }

    /// Reapplies the next undone transaction, returning its ops for the caller
    /// to apply in order. Returns `nil` if there is nothing to redo.
    @discardableResult
    public func redo() -> [UndoOperation]? {
        guard canRedo else { return nil }
        defer { cursor += 1 }
        return history[cursor]
    }

    /// Marks the current cursor position as the saved state (called after a
    /// successful save).
    public func markSaved() {
        savedIndex = cursor
    }

    /// Discards all history and the dirty checkpoint.
    public func reset() {
        history.removeAll()
        cursor = 0
        savedIndex = 0
    }
}
