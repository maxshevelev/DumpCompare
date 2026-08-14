import XCTest
@testable import DumpCompareCore

final class UndoHistoryTests: XCTestCase {
    private func op(_ i: UInt64) -> UndoOperation {
        .overwrite(range: i..<(i + 1), before: [0], after: [1])
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
        XCTAssertEqual(history.undo()?.count, 3) // all three revert together
        XCTAssertFalse(history.canUndo)
    }
}
