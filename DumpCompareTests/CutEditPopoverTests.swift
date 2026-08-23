import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §21.3 the Add Cut popover, driven the way the bookmark's is: the controller
/// is constructed directly and its fields set, because a popover anchored in a
/// window that never comes on screen closes the instant it opens. What is under
/// test is the controller's own contract — what a legal offset commits, what a
/// refused one beeps, and what a stray close keeps or drops.
///
/// The rules: **Return** makes the cut, **Esc** backs out, and a click outside
/// keeps the cut when the offset is legal but not when the field is red. A cut
/// at 0, at EOF, or on a seam another cut already holds is refused — every piece
/// must stay non-empty (§21.2).
@MainActor
final class CutEditPopoverTests: XCTestCase {

    /// A controller over a 16-byte file, with the outcomes captured. `existing`
    /// are the seams another cut already holds.
    private func makeController(fileSize: UInt64 = 16,
                                existing: [UInt64] = [],
                                commit: @escaping (UInt64, String) -> Void = { _, _ in })
        -> (controller: CutEditPopoverController, beeps: () -> Int) {
        var beepCount = 0
        let controller = CutEditPopoverController(
            prefillOffset: 8, fileSize: fileSize,
            isAlreadyACut: { existing.contains($0) },
            onCommit: commit)
        controller.loadViewIfNeeded()
        controller.beep = { beepCount += 1 }
        return (controller, { beepCount })
    }

    // MARK: - Committing

    /// A legal offset commits the cut at that offset, naming the piece that
    /// starts there. The offset is parsed as the dialogs parse one (§10.1):
    /// `0x`-prefixed hex here.
    func testCommitMakesACutAtTheTypedOffset() {
        var committed: (UInt64, String)?
        let (controller, beeps) = makeController(commit: { committed = ($0, $1) })

        controller.offsetField.stringValue = "0x0A"
        controller.descriptionField.stringValue = "header"
        controller.commit()

        XCTAssertEqual(committed?.0, 0x0A, "the cut is at the typed offset")
        XCTAssertEqual(committed?.1, "header", "the name goes with the piece that starts there")
        XCTAssertEqual(beeps(), 0, "a legal commit is quiet")
    }

    /// A decimal offset is parsed too — the field accepts whatever the dialogs
    /// accept, not just hex.
    func testCommitParsesADecimalOffset() {
        var committed: UInt64?
        let (controller, _) = makeController(commit: { committed = $0; _ = $1 })

        controller.offsetField.stringValue = "10"
        controller.commit()

        XCTAssertEqual(committed, 10, "a plain digit string is decimal")
    }

    // MARK: - Refusals

    /// A cut at 0 is refused: it would leave the first piece empty. The field is
    /// already red, so Return only owes a beep — no commit.
    func testCommitRefusesZero() {
        var committed: UInt64?
        let (controller, beeps) = makeController(commit: { committed = $0; _ = $1 })

        controller.offsetField.stringValue = "0"
        controller.commit()

        XCTAssertNil(committed, "no cut at the file start")
        XCTAssertEqual(beeps(), 1, "a refused commit beeps")
    }

    /// A cut at EOF is refused: it would leave the last piece empty.
    func testCommitRefusesEOF() {
        var committed: UInt64?
        let (controller, beeps) = makeController(fileSize: 16, commit: { committed = $0; _ = $1 })

        controller.offsetField.stringValue = "16"
        controller.commit()

        XCTAssertNil(committed, "no cut at EOF")
        XCTAssertEqual(beeps(), 1)
    }

    /// A cut on a seam another cut already holds is refused — the offset is
    /// legal in range but not a new cut.
    func testCommitRefusesAnExistingCut() {
        var committed: UInt64?
        let (controller, beeps) = makeController(existing: [8], commit: { committed = $0; _ = $1 })

        controller.offsetField.stringValue = "8"
        controller.commit()

        XCTAssertNil(committed, "no second cut on the same seam")
        XCTAssertEqual(beeps(), 1)
    }

    /// Unparseable text is refused the same way: no commit, a beep.
    func testCommitRefusesUnparseableText() {
        var committed: UInt64?
        let (controller, beeps) = makeController(commit: { committed = $0; _ = $1 })

        controller.offsetField.stringValue = "0xZZ"
        controller.commit()

        XCTAssertNil(committed)
        XCTAssertEqual(beeps(), 1)
    }

    /// A second commit on the same popover is a no-op: the first outcome settles
    /// it, so the close that follows cannot run a second one.
    func testASecondCommitIsIgnored() {
        var commits = 0
        let (controller, beeps) = makeController(commit: { _, _ in commits += 1 })

        controller.offsetField.stringValue = "0x08"
        controller.commit()
        controller.commit()

        XCTAssertEqual(commits, 1, "the popover settles on its first outcome")
        XCTAssertEqual(beeps(), 0)
    }

    // MARK: - Cancelling

    /// Esc backs out: no cut, no beep — there is nothing to refuse, because
    /// nothing exists until a commit.
    func testCancelMakesNoCut() {
        var committed: UInt64?
        let (controller, beeps) = makeController(commit: { committed = $0; _ = $1 })

        controller.offsetField.stringValue = "0x08"
        controller.cancel()

        XCTAssertNil(committed, "Esc makes no cut")
        XCTAssertEqual(beeps(), 0, "a cancel is quiet")
    }

    // MARK: - A stray close

    /// A click outside keeps the cut when the offset is legal: the user opened
    /// the popover to make a cut, so the cut is the quiet outcome.
    func testAClickOutsideCommitsWhenTheOffsetIsLegal() {
        var committed: (UInt64, String)?
        let (controller, beeps) = makeController(commit: { committed = ($0, $1) })

        controller.offsetField.stringValue = "0x0C"
        controller.descriptionField.stringValue = "payload"
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))

        XCTAssertEqual(committed?.0, 0x0C, "a legal offset survives a stray close")
        XCTAssertEqual(committed?.1, "payload")
        XCTAssertEqual(beeps(), 0)
    }

    /// A red field is the one thing a stray close does not keep: an illegal
    /// offset is not a cut the user asked for, so it closes without cutting.
    func testAClickOutsideRefusesWhenTheFieldIsRed() {
        var committed: UInt64?
        let (controller, beeps) = makeController(commit: { committed = $0; _ = $1 })

        controller.offsetField.stringValue = "0"
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))

        XCTAssertNil(committed, "a red field closes without cutting")
        XCTAssertEqual(beeps(), 0, "a stray close never beeps")
    }

    // MARK: - Validation as the offset is typed

    /// The field turns red as the offset becomes illegal and back to the label
    /// colour when it is legal again — the same validation as everywhere an
    /// offset is typed (§10.1), shown in the field rather than in a message.
    func testTheFieldColoursTrackLegalityAsItIsTyped() {
        let (controller, _) = makeController()

        // The prefill (8) is legal: the field starts in the label colour.
        controller.controlTextDidChange(Notification(name: .init("typed"), object: controller.offsetField))
        XCTAssertTrue(controller.offsetField.textColor == .labelColor, "a legal offset is not red")

        // Typing 0 makes it red.
        controller.offsetField.stringValue = "0"
        controller.controlTextDidChange(Notification(name: .init("typed"), object: controller.offsetField))
        XCTAssertTrue(controller.offsetField.textColor == .systemRed, "an illegal offset is red")

        // Typing a legal offset clears the red.
        controller.offsetField.stringValue = "0x08"
        controller.controlTextDidChange(Notification(name: .init("typed"), object: controller.offsetField))
        XCTAssertTrue(controller.offsetField.textColor == .labelColor, "a legal offset clears the red")
    }
}
