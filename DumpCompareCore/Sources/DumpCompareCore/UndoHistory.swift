import Foundation

/// A single reversible byte mutation (decision D4).
///
/// Each case carries everything needed to apply and revert it without re-reading
/// the storage:
/// - `.overwrite` carries the bytes before and after (a fill is an overwrite
///   with a repeated pattern), so reverting simply writes `before` back.
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

    /// The op that reverts this one, for applying a transaction in reverse
    /// (undo): an overwrite swaps its before/after bytes, an insert becomes the
    /// delete of its bytes, a delete re-inserts its removed bytes.
    var inverted: UndoOperation {
        switch self {
        case .overwrite(let range, let before, let after):
            return .overwrite(range: range, before: after, after: before)
        case .insert(let at, let bytes):
            return .delete(range: at..<(at + UInt64(bytes.count)), bytes: bytes)
        case .delete(let range, let bytes):
            return .insert(at: range.lowerBound, bytes: bytes)
        }
    }
}

/// A committed undo step: the ops applied as a unit, plus the selections that
/// bracket it — what was selected when the edit started (`selectionBefore`,
/// restored by undo) and what the edit left selected (`selectionAfter`,
/// restored by redo). Captured by `BinaryDocument` at record time.
///
/// The whole selection is stored, not just the caret: typing into a selection
/// consumes it byte by byte, and an undo that dropped the selection would make
/// the two directions asymmetric — the state undo returns to would be one the
/// editing never passed through (§7.5).
public struct UndoTransaction: Equatable, Sendable {
    public let ops: [UndoOperation]
    public let selectionBefore: SelectionModel
    /// Set at record time from the edit's natural end, then refined by
    /// `noteSelectionAfterOnLast` once the command that made the edit has left
    /// the selection where it wants it.
    public private(set) var selectionAfter: SelectionModel

    /// Where the caret sits in each bracketing state — an empty selection is a
    /// caret, and a non-empty one's caret is its start.
    public var caretBefore: UInt64 { selectionBefore.start }
    public var caretAfter: UInt64 { selectionAfter.start }

    public init(ops: [UndoOperation], selectionBefore: SelectionModel, selectionAfter: SelectionModel) {
        self.ops = ops
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
    }

    /// Caret-only form, for edits recorded without a selection to speak of.
    public init(ops: [UndoOperation], caretBefore: UInt64, caretAfter: UInt64,
                fileSize: UInt64 = .max) {
        self.init(ops: ops,
                  selectionBefore: .empty(at: caretBefore, fileSize: fileSize),
                  selectionAfter: .empty(at: caretAfter, fileSize: fileSize))
    }

    fileprivate mutating func setSelectionAfter(_ selection: SelectionModel) {
        selectionAfter = selection
    }
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
    private var history: [UndoTransaction] = []
    private var cursor = 0
    private var savedIndex = 0

    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < history.count }
    /// True when the current state differs from the last saved state.
    public var isDirty: Bool { cursor != savedIndex }
    /// Number of committed transactions (the cursor position).
    public var undoDepth: Int { cursor }

    /// Records a transaction of ops applied to storage. Any undone transactions
    /// (the redo stack) are discarded, because the state has diverged. The
    /// selection pair records what the edit started from and what it left, so
    /// undo/redo can restore it.
    public func record(_ ops: [UndoOperation],
                       selectionBefore: SelectionModel,
                       selectionAfter: SelectionModel) {
        guard !ops.isEmpty else { return }
        if cursor < history.count {
            history.removeSubrange(cursor...)
        }
        history.append(UndoTransaction(ops: ops,
                                       selectionBefore: selectionBefore,
                                       selectionAfter: selectionAfter))
        cursor = history.count
    }

    /// Caret-only form of `record`, for edits with no selection to restore.
    public func record(_ ops: [UndoOperation], caretBefore: UInt64 = 0, caretAfter: UInt64 = 0,
                       fileSize: UInt64 = .max) {
        record(ops,
               selectionBefore: .empty(at: caretBefore, fileSize: fileSize),
               selectionAfter: .empty(at: caretAfter, fileSize: fileSize))
    }

    /// Refines the last recorded transaction's post-edit selection, so redo
    /// restores what the editing command left on screen rather than the bare
    /// end of the byte range it wrote. Ignored unless the last transaction is
    /// the current one (nothing has been undone since it was recorded).
    public func noteSelectionAfterOnLast(_ selection: SelectionModel) {
        guard cursor == history.count, cursor > 0 else { return }
        history[cursor - 1].setSelectionAfter(selection)
    }

    /// Reverts the most recent committed transaction, returning it (ops in
    /// committed order, for the caller to apply in reverse). Returns `nil` if
    /// there is nothing to undo.
    @discardableResult
    public func undo() -> UndoTransaction? {
        guard canUndo else { return nil }
        cursor -= 1
        return history[cursor]
    }

    /// Reapplies the next undone transaction, returning it for the caller to
    /// apply in order. Returns `nil` if there is nothing to redo.
    @discardableResult
    public func redo() -> UndoTransaction? {
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
