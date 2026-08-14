import XCTest
@testable import DumpCompareCore

/// Smoke test for the package scaffold.
/// Real storage/model tests arrive in Milestones 1–3 (see IMPLEMENTATION_PLAN.md).
final class DumpCompareCoreSmokeTests: XCTestCase {
    func testCoreModuleLoads() {
        // Compile-time sanity that the module builds and is importable.
        XCTAssertTrue(true)
    }
}
