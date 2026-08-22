import XCTest
@testable import DumpCompare

/// Unit tests for the background-operation abstraction (§14.4): the ~1%
/// progress throttle, the always-dispatch final step, clamping, idempotent
/// finish, and cancel routing to the owner's action.
@MainActor
final class BackgroundOperationTests: XCTestCase {
    /// Updates that move the bar by less than ~1% are skipped; every ≥1% step
    /// is dispatched to the main actor.
    func testReportThrottlesToOnePercentSteps() async {
        let op = BackgroundOperation(name: "Test") {}
        var reported: [Double] = []
        op.onProgress = { reported.append($0) }

        op.report(0.001)
        op.report(0.002)
        op.report(0.005)
        op.report(0.01)
        op.report(0.02)
        op.report(0.5)

        let settled = await awaitUntil(2) { reported.count == 3 }
        XCTAssertTrue(settled, "the dispatched progress updates never landed")
        XCTAssertEqual(reported.first ?? -1, 0.01, accuracy: 1e-9,
                       "0.001–0.005 are < 1% away from 0 and must be skipped")
        XCTAssertEqual(reported[1], 0.02, accuracy: 1e-9)
        XCTAssertEqual(reported.last ?? -1, 0.5, accuracy: 1e-9)
    }

    /// The final `progress(1)` always dispatches even when it is closer than 1%
    /// to the last step — the bar must reach 100% before the operation hides.
    func testFinalProgressAlwaysDispatches() async {
        let op = BackgroundOperation(name: "Test") {}
        var reported: [Double] = []
        op.onProgress = { reported.append($0) }

        op.report(0.995)
        op.report(1)

        let settled = await awaitUntil(2) { reported.last == 1 }
        XCTAssertTrue(settled, "the final 1 must always be dispatched")
    }

    /// Fractions above 1 are clamped to 1 — the bar must never overshoot. (The
    /// lower bound clamps to 0 too, but a report moving the bar backwards is
    /// throttled away before it reaches the UI, so 0 is unobservable.)
    func testReportClampsAboveUnit() async {
        let op = BackgroundOperation(name: "Test") {}
        var reported: [Double] = []
        op.onProgress = { reported.append($0) }

        op.report(0.5)
        op.report(1.5)

        let settled = await awaitUntil(2) { reported.count == 2 }
        XCTAssertTrue(settled, "the clamped updates never landed")
        XCTAssertEqual(reported.first ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(reported.last ?? -1, 1, accuracy: 1e-9)
    }

    /// `finish()` fires `onFinish` exactly once, and a report arriving after
    /// finish is ignored.
    func testFinishIsIdempotentAndSwallowsLateReports() async {
        let op = BackgroundOperation(name: "Test") {}
        var finishCount = 0
        op.onFinish = { finishCount += 1 }

        op.finish()
        op.finish()

        let settled = await awaitUntil(2) { finishCount == 1 }
        XCTAssertTrue(settled, "onFinish must fire exactly once")

        var reported: [Double] = []
        op.onProgress = { reported.append($0) }
        op.report(0.5)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(reported.isEmpty, "a report after finish must be ignored")
    }

    /// `cancel()` routes to the owner's cancel action — the (×) button path.
    func testCancelCallsCancelAction() {
        var cancelled = false
        let op = BackgroundOperation(name: "Test") { cancelled = true }
        op.cancel()
        XCTAssertTrue(cancelled, "cancel() must invoke the owner's cancel action")
    }
}
