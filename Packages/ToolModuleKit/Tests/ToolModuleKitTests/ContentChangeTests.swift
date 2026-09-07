import XCTest
@testable import ToolModuleKit

/// Coalescing what the session is told, so a host can hold a change back
/// briefly rather than waking a parse per keystroke.
final class ContentChangeTests: XCTestCase {

    /// Once the content has been replaced there is nothing left to be precise
    /// about — from either side, since the reload may arrive first.
    func testAReloadSwallowsAnEdit() {
        let edit = ToolContentChange.edited(0x10..<0x20, sizeDelta: 0)

        XCTAssertEqual(edit.merged(with: .reloaded), .reloaded)
        XCTAssertEqual(ToolContentChange.reloaded.merged(with: edit), .reloaded)
        XCTAssertEqual(ToolContentChange.reloaded.merged(with: .reloaded), .reloaded)
    }

    /// A run of typing: the stretch from the earliest start to the latest end,
    /// which is what a tool-module has to re-read.
    func testTwoEditsBecomeTheStretchTheyBothTouched() {
        let first = ToolContentChange.edited(0x40..<0x41, sizeDelta: 0)
        let second = ToolContentChange.edited(0x10..<0x11, sizeDelta: 0)

        XCTAssertEqual(first.merged(with: second), .edited(0x10..<0x41, sizeDelta: 0))
    }

    /// Length changes add up: two insertions have moved the tail by both.
    func testLengthChangesAddUp() {
        let first = ToolContentChange.edited(0x10..<0x14, sizeDelta: 4)
        let second = ToolContentChange.edited(0x20..<0x20, sizeDelta: -2)

        XCTAssertEqual(first.merged(with: second), .edited(0x10..<0x20, sizeDelta: 2))
    }

    /// What a tool-module acts on: where the content stopped being what it read.
    func testTheEarliestAffectedOffset() {
        XCTAssertEqual(ToolContentChange.edited(0x30..<0x40, sizeDelta: 0).earliestAffectedOffset, 0x30)
        XCTAssertNil(ToolContentChange.reloaded.earliestAffectedOffset)
    }
}
