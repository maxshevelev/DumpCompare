import XCTest
@testable import DumpCompareCore

final class UndoHistoryTests: XCTestCase {
    private func op(_ i: UInt64) -> UndoOperation {
        .overwrite(range: i..<(i + 1), before: [0], after: [1])
    }

    /// The ops of each returned transaction, for comparing gesture results.
    private func ops(_ txns: [UndoTransaction]?) -> [[UndoOperation]] {
        txns?.map(\.ops) ?? []
    }

    func testUndoRedoCycle() {
        let history = UndoHistory()
        history.record([op(0)])
        history.record([op(1)])

        XCTAssertEqual(history.undo()?.count, 1)
        XCTAssertEqual(history.undo()?.count, 1)
        XCTAssertNil(history.undo())
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)

        XCTAssertNotNil(history.redo())
        XCTAssertNotNil(history.redo())
        XCTAssertNil(history.redo())
        XCTAssertTrue(history.canUndo)
    }

    func testDirtyCheckpointLifecycle() {
        let history = UndoHistory()
        XCTAssertFalse(history.isDirty)

        history.record([op(0)])          // edit
        XCTAssertTrue(history.isDirty)

        history.markSaved()              // save → clean
        XCTAssertFalse(history.isDirty)

        history.record([op(1)])          // edit again
        XCTAssertTrue(history.isDirty)

        history.undo()                   // undo to saved state → clean
        XCTAssertFalse(history.isDirty)

        history.redo()                   // redo past it → dirty again
        XCTAssertTrue(history.isDirty)
    }

    /// The saved checkpoint names a *state*, not a depth: undo an edit, make a
    /// different one, and the document must still be dirty even though as many
    /// edits stand as when it was saved (§7.5). Counting them reported clean, and
    /// closing the file would have discarded the change with no prompt.
    func testADifferentEditAtTheSameDepthIsNotTheSavedState() {
        let history = UndoHistory()
        history.record([op(0)])
        history.record([op(1)])
        history.markSaved()
        XCTAssertFalse(history.isDirty)

        history.undo()
        XCTAssertTrue(history.isDirty, "one edit short of the saved state")

        history.record([op(2)])          // a different second edit
        XCTAssertTrue(history.isDirty,
                      "as many edits stand, but not the ones that were saved")

        history.undo()
        XCTAssertTrue(history.isDirty, "and the state it replaced is gone for good")
    }

    /// The same rule through a series batch: the serials come back with the
    /// transactions, so a redo that lands on the saved state is clean again,
    /// while fresh bytes of the same count are not.
    func testABatchAndFreshBytesOfTheSameCountAreDifferentStates() {
        let history = UndoHistory()
        for i in 0..<3 { history.record([op(UInt64(i))], seriesID: 1) }
        history.markSaved()

        history.undo(batch: false)
        history.undo(batch: true)        // the rest of the series, in one step
        XCTAssertTrue(history.isDirty)
        history.redo()                   // unfolds — back to the saved state
        history.redo()
        XCTAssertFalse(history.isDirty, "the saved state is reachable again")

        history.undo(batch: false)
        history.undo(batch: true)
        for i in 10..<13 { history.record([op(UInt64(i))], seriesID: 2) }
        XCTAssertTrue(history.isDirty, "three other bytes are not the three saved ones")
    }

    func testNewEditClearsRedoStack() {
        let history = UndoHistory()
        history.record([op(0)])
        history.record([op(1)])
        history.undo()                   // now at transaction 0
        XCTAssertTrue(history.canRedo)

        history.record([op(2)])          // diverges: redo stack (t1) discarded
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undo()?.count, 1)  // t2
        XCTAssertEqual(history.undo()?.count, 1)  // t0 still committed
        XCTAssertNil(history.undo())
    }

    func testRecordEmptyTransactionIsNoop() {
        let history = UndoHistory()
        history.record([])
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertFalse(history.isDirty)
    }

    func testResetClearsEverything() {
        let history = UndoHistory()
        history.record([op(0)])
        history.record([op(1)])
        history.undo()
        XCTAssertTrue(history.isDirty)

        history.reset()
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertFalse(history.isDirty)
        XCTAssertEqual(history.undoDepth, 0)
    }

    func testGroupedTransactionsUndoAsUnit() {
        let history = UndoHistory()
        history.record([op(0), op(1), op(2)])  // one transaction, three ops
        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.undo()?[0].ops.count, 3) // all three revert together
        XCTAssertFalse(history.canUndo)
    }

    func testTransactionCarriesCaretPositions() {
        let history = UndoHistory()
        history.record([op(0)], caretBefore: 5, caretAfter: 6)
        history.record([op(1)], caretBefore: 7, caretAfter: 8)

        let undone = history.undo()
        XCTAssertEqual(undone?[0].ops, [op(1)])
        XCTAssertEqual(undone?[0].caretBefore, 7)
        XCTAssertEqual(undone?[0].caretAfter, 8)

        let redone = history.redo()
        XCTAssertEqual(redone?[0].ops, [op(1)])
        XCTAssertEqual(redone?[0].caretBefore, 7)
        XCTAssertEqual(redone?[0].caretAfter, 8)

        // Caret-less records (legacy callers) default to 0/0.
        history.record([op(2)])
        XCTAssertEqual(history.undo()?[0].caretBefore, 0)
    }

    // MARK: - Typing series (segmented undo, Variant B)

    func testFastSecondUndoRemovesTheRestOfTheSeries() {
        let history = UndoHistory()
        history.record([op(0)], seriesID: 1)
        history.record([op(1)], seriesID: 1)
        history.record([op(2)], seriesID: 1)

        XCTAssertEqual(ops(history.undo(batch: false)), [[op(2)]])
        // The fast repeat removes the rest of the series, in recording order.
        XCTAssertEqual(ops(history.undo(batch: true)), [[op(0)], [op(1)]])
        XCTAssertFalse(history.canUndo)
    }

    func testUndoAfterAPauseRemovesOneByteAgain() {
        let history = UndoHistory()
        history.record([op(0)], seriesID: 1)
        history.record([op(1)], seriesID: 1)
        history.record([op(2)], seriesID: 1)

        XCTAssertEqual(ops(history.undo(batch: false)), [[op(2)]])
        XCTAssertEqual(ops(history.undo(batch: false)), [[op(1)]])
    }

    /// When the fast repeat must *not* fold a series: the whole point of the
    /// batch window is that it only rolls back what one uninterrupted typing run
    /// recorded. In each case the second press comes back with a single
    /// transaction, exactly as if `batch` had not been asked for.
    func testBatchIsRefusedOutsideOneTypingRun() {
        let cases: [(name: String, records: [(UInt64, UInt64?)],
                     firstUndo: [[UndoOperation]],
                     interlude: [(UInt64, UInt64?)],
                     batchUndo: [[UndoOperation]])] = [
            // The top is series 1, the last undo was series 2 → no batch.
            ("the batch stops at a series boundary",
             [(0, 1), (1, 2)], [[op(1)]], [], [[op(0)]]),
            // The top has no seriesID at all → no batch.
            ("a transaction with no series is never batched",
             [(0, nil), (1, 1)], [[op(1)]], [], [[op(0)]]),
            // A new edit between the two presses breaks the fast window, so the
            // second press undoes that edit alone.
            ("a new edit closes the fast window",
             [(0, 1), (1, 1)], [[op(1)]], [(2, nil)], [[op(2)]]),
        ]
        for testCase in cases {
            let history = UndoHistory()
            for (offset, series) in testCase.records {
                history.record([op(offset)], seriesID: series)
            }
            XCTAssertEqual(ops(history.undo(batch: false)), testCase.firstUndo,
                           "\(testCase.name): the first press")
            for (offset, series) in testCase.interlude {
                history.record([op(offset)], seriesID: series)
            }
            XCTAssertEqual(ops(history.undo(batch: true)), testCase.batchUndo,
                           "\(testCase.name): the second press")
        }
    }

    func testRedoOfABatchRestoresByteByByteStructure() {
        let history = UndoHistory()
        history.record([op(0)], seriesID: 1)
        history.record([op(1)], seriesID: 1)
        history.record([op(2)], seriesID: 1)

        XCTAssertEqual(ops(history.undo(batch: false)), [[op(2)]])
        XCTAssertEqual(ops(history.undo(batch: true)), [[op(0)], [op(1)]])
        // Redo is symmetric with undo: one press restores one step — first
        // the batch, unfolded back into individual byte steps on the undo
        // stack, then the single byte.
        XCTAssertEqual(ops(history.redo()), [[op(0)], [op(1)]])
        XCTAssertEqual(ops(history.redo()), [[op(2)]])
        XCTAssertEqual(history.undoDepth, 3)

        // The series is byte-by-byte again: a plain undo removes the last byte.
        XCTAssertEqual(ops(history.undo(batch: false)), [[op(2)]])
        XCTAssertEqual(history.undoDepth, 2)
    }

    func testDirtyControlAcrossABatch() {
        let history = UndoHistory()
        history.record([op(0)], seriesID: 1)
        history.record([op(1)], seriesID: 1)
        history.record([op(2)], seriesID: 1)
        history.markSaved()
        XCTAssertFalse(history.isDirty)

        history.undo(batch: false)
        history.undo(batch: true)
        XCTAssertTrue(history.isDirty)

        // Redo restores one step at a time: the batch step brings back two
        // transactions, still short of the saved count (dirty is counted in
        // transactions, not steps).
        history.redo()
        XCTAssertTrue(history.isDirty)
        history.redo()
        XCTAssertFalse(history.isDirty)
    }
}
