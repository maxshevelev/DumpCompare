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
/// The history is a list of *steps* — one step is one undo gesture: either a
/// single transaction (a normal edit, or one entered byte of a typing series)
/// or a batch of transactions (the rest of a series removed by one fast
/// Cmd+Z). A step's `seriesID` links the steps of one typing series; `nil`
/// means the step is outside a series.
///
/// `undo(batch: true)` removes one step, but when the previous undo removed a
/// single series byte and the top step belongs to the same series, it removes
/// every remaining step of that series as one batch — the "coalescing window"
/// of segmented undo. `redo()` restores one step; a batch is unfolded back
/// into individual byte steps on the undo stack, so byte-by-byte rollback is
/// available again after a redo.
///
/// Dirty state is defined entirely by the committed transaction count vs a
/// saved checkpoint (counted in transactions, not steps — unfolding a batch
/// on redo does not change the count): `isDirty` is true when the count is
/// not where the last `markSaved()` left it. Undoing back to the saved state
/// clears dirty; redoing past it sets it again (§5.1, §17.7).
///
/// This class is confined to a single thread (the document it belongs to).
public final class UndoHistory: @unchecked Sendable {
    /// One undo gesture: a transaction (a normal edit or one entered byte)
    /// or a batch of transactions (the rest of a series removed by one fast
    /// press). `seriesID` links the steps of one typing series; nil is
    /// outside a series.
    private struct Step {
        var transactions: [UndoTransaction]   // in recording order (first..last)
        var seriesID: UInt64?
    }

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    private var savedTransactionIndex = 0     // dirty control: transaction count
    private var undoTransactionCount = 0

    // Fast-rollback state:
    private var lastUndoWasSeriesByte = false
    private var lastUndoSeriesID: UInt64?

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    /// True when the current state differs from the last saved state.
    public var isDirty: Bool { undoTransactionCount != savedTransactionIndex }
    /// Number of committed transactions.
    public var undoDepth: Int { undoTransactionCount }

    /// Records a transaction of ops applied to storage. Any undone steps
    /// (the redo stack) are discarded, because the state has diverged. The
    /// selection pair records what the edit started from and what it left, so
    /// undo/redo can restore it. `seriesID` marks the transaction as part of a
    /// typing series (nil for everything else). A new record also breaks the
    /// fast-rollback window — a fresh edit is never batched with a previous
    /// undo.
    public func record(_ ops: [UndoOperation],
                       selectionBefore: SelectionModel,
                       selectionAfter: SelectionModel,
                       seriesID: UInt64? = nil) {
        guard !ops.isEmpty else { return }
        redoSteps.removeAll()
        undoSteps.append(Step(transactions: [UndoTransaction(ops: ops,
                                                             selectionBefore: selectionBefore,
                                                             selectionAfter: selectionAfter)],
                              seriesID: seriesID))
        undoTransactionCount += 1
        lastUndoWasSeriesByte = false
        lastUndoSeriesID = nil
    }

    /// Caret-only form of `record`, for edits with no selection to restore.
    public func record(_ ops: [UndoOperation], caretBefore: UInt64 = 0, caretAfter: UInt64 = 0,
                       fileSize: UInt64 = .max, seriesID: UInt64? = nil) {
        record(ops,
               selectionBefore: .empty(at: caretBefore, fileSize: fileSize),
               selectionAfter: .empty(at: caretAfter, fileSize: fileSize),
               seriesID: seriesID)
    }

    /// Refines the last recorded transaction's post-edit selection, so redo
    /// restores what the editing command left on screen rather than the bare
    /// end of the byte range it wrote. Ignored unless the last transaction is
    /// the current one (nothing has been undone since it was recorded).
    public func noteSelectionAfterOnLast(_ selection: SelectionModel) {
        guard redoSteps.isEmpty, let step = undoSteps.indices.last else { return }
        undoSteps[step].transactions[undoSteps[step].transactions.count - 1].setSelectionAfter(selection)
    }

    /// Reverts the most recent step, returning its transactions in recording
    /// order (for the caller to apply in reverse). With `batch == true`, a
    /// fast repeat of a series-byte undo removes the rest of that series as
    /// one step instead. Returns `nil` if there is nothing to undo.
    @discardableResult
    public func undo(batch: Bool = false) -> [UndoTransaction]? {
        guard let last = undoSteps.popLast() else { return nil }
        var collected = [last]
        if batch, let sid = last.seriesID, sid == lastUndoSeriesID, lastUndoWasSeriesByte {
            while let next = undoSteps.last, next.seriesID == sid {
                undoSteps.removeLast()
                collected.append(next)
            }
        }
        let ordered = collected.reversed().flatMap(\.transactions)   // recording order
        undoTransactionCount -= ordered.count
        redoSteps.append(Step(transactions: ordered, seriesID: last.seriesID))
        lastUndoWasSeriesByte = (collected.count == 1 && last.seriesID != nil)
        lastUndoSeriesID = last.seriesID
        return ordered
    }

    /// Reapplies the next undone step, returning its transactions in
    /// recording order for the caller to apply in order. A batch step is
    /// unfolded back into individual byte steps on the undo stack, restoring
    /// the series' byte-by-byte structure. Returns `nil` if there is nothing
    /// to redo.
    @discardableResult
    public func redo() -> [UndoTransaction]? {
        guard let step = redoSteps.popLast() else { return nil }
        for txn in step.transactions {
            undoSteps.append(Step(transactions: [txn], seriesID: step.seriesID))
        }
        undoTransactionCount += step.transactions.count
        lastUndoWasSeriesByte = false
        lastUndoSeriesID = nil
        return step.transactions
    }

    /// Marks the current transaction count as the saved state (called after a
    /// successful save).
    public func markSaved() {
        savedTransactionIndex = undoTransactionCount
    }

    /// Discards all history and the dirty checkpoint.
    public func reset() {
        undoSteps.removeAll()
        redoSteps.removeAll()
        savedTransactionIndex = 0
        undoTransactionCount = 0
        lastUndoWasSeriesByte = false
        lastUndoSeriesID = nil
    }
}
