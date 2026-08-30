import XCTest
@testable import DumpCompare

/// §23: what a copy is called before it is saved.
///
/// "Untitled" is true of a copy and useless the moment there are two: two panes
/// under one name say nothing about which dump each came from. Nothing is
/// written to disk for these names — they are what the header shows and what the
/// save panel pre-fills.
@MainActor
final class DuplicateNameTests: XCTestCase {

    // MARK: - The rule

    /// A copy is the second of its kind, so it starts at 2.
    func testACopyIsTheSecondOfItsKind() {
        XCTAssertEqual(DuplicateName.next(after: "bios.bin", taken: []), "bios-2.bin")
    }

    /// A copy of a copy counts on rather than nesting: a series of duplicates
    /// reads as one series, which is the whole reason for the suffix.
    func testACopyOfACopyCountsOn() {
        XCTAssertEqual(DuplicateName.next(after: "bios-2.bin", taken: []), "bios-3.bin")
        XCTAssertEqual(DuplicateName.next(after: "bios-9.bin", taken: []), "bios-10.bin")
    }

    /// A taken name is skipped, however many are taken.
    func testTakenNamesAreSkipped() {
        XCTAssertEqual(DuplicateName.next(after: "bios.bin", taken: ["bios-2.bin"]),
                       "bios-3.bin")
        XCTAssertEqual(DuplicateName.next(after: "bios.bin",
                                          taken: ["bios-2.bin", "bios-3.bin", "bios-4.bin"]),
                       "bios-5.bin")
    }

    /// The extension is kept, and the split is at the last dot — a name with
    /// dots in it keeps all but the last.
    func testTheExtensionIsKept() {
        XCTAssertEqual(DuplicateName.next(after: "bios.v2.bin", taken: []), "bios.v2-2.bin")
        XCTAssertEqual(DuplicateName.next(after: "dump", taken: []), "dump-2")
    }

    /// Digits at the end of a name are not a series unless a dash introduces
    /// them: a chip's name ends in numbers, and `W25Q128` is not the 128th of
    /// anything.
    func testTrailingDigitsAreNotASeries() {
        XCTAssertEqual(DuplicateName.next(after: "W25Q128.bin", taken: []), "W25Q128-2.bin")
        XCTAssertEqual(DuplicateName.next(after: "W25Q128FV_20260821_1a2b3c4d.bin", taken: []),
                       "W25Q128FV_20260821_1a2b3c4d-2.bin")
    }

    /// A dash with something other than digits after it is part of the name.
    func testADashThatIsNotASeriesIsLeftAlone() {
        XCTAssertEqual(DuplicateName.next(after: "bios-donor.bin", taken: []),
                       "bios-donor-2.bin")
    }

    // MARK: - What a pane gets called

    /// Duplicating a file names the copy after it, and the file itself is not
    /// created — the copy is untitled, with a name to show.
    func testADuplicatedPaneIsNamedAfterItsSource() throws {
        let controller = MainViewController()
        let url = try tempFile([UInt8](repeating: 0xAA, count: 32))
        controller.openFiles([url])

        controller.duplicate(from: controller.windowModel.pane1)

        let copy = controller.windowModel.pane2
        XCTAssertTrue(copy.isUntitled, "nothing was written to disk")
        XCTAssertEqual(copy.status.fileName,
                       DuplicateName.next(after: url.lastPathComponent, taken: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            url.deletingLastPathComponent().appendingPathComponent(copy.status.fileName).path),
            "the name is a proposal, not a file")
    }

    /// The line the copy reports itself with names both ends, so the pair can be
    /// told apart without reading the two headers: it said "as Untitled" when a
    /// copy had no name of its own, and the copy has one now.
    func testTheDuplicateReportNamesTheCopy() throws {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        let url = try tempFile([UInt8](repeating: 0xAA, count: 32))
        controller.openFiles([url])

        controller.duplicate(from: controller.windowModel.pane1)
        window.layoutIfNeeded()

        let copy = controller.windowModel.pane2
        let copyView = try XCTUnwrap(descendants(of: controller.view, FilePaneView.self).last)
        XCTAssertEqual(copyView.statusLabel.stringValue,
                       "Duplicated \(url.lastPathComponent) as \(copy.status.fileName). Size: 32 bytes.")
    }

    /// The names in use anywhere in the app are avoided, not just this window's:
    /// two tabs each showing a `bios-2.bin` would be the confusion this naming
    /// exists to remove.
    func testNamesTakenInAnotherWindowAreAvoided() throws {
        let registry = OpenDocumentRegistry()
        let first = MainViewController()
        let second = MainViewController()
        for controller in [first, second] {
            controller.openDocuments = registry
            registry.register(controller)
        }
        let url = try tempFile([UInt8](repeating: 0xAA, count: 32))
        first.openFiles([url])
        first.duplicate(from: first.windowModel.pane1)
        let firstCopyName = first.windowModel.pane2.status.fileName

        // The second window duplicates the same source; the first copy's name is
        // already on screen.
        XCTAssertNotEqual(second.unsavedName(for: first.windowModel.pane1), firstCopyName)
    }

    /// A copy of something that has no name of its own stays untitled — there is
    /// nothing to name it after.
    func testACopyOfAnUntitledDocumentStaysUntitled() {
        let controller = MainViewController()
        controller.newDocument()

        XCTAssertNil(controller.unsavedName(for: controller.windowModel.pane1))
    }

    /// A copy is untitled the moment it is made, and copying it again continues
    /// the series rather than falling back to "Untitled": the name a pane wears
    /// is what the next copy is named after, saved or not.
    func testACopyOfAnUnsavedCopyContinuesTheSeries() throws {
        let controller = MainViewController()
        let url = try tempFile([UInt8](repeating: 0xAA, count: 32))
        controller.openFiles([url])
        controller.duplicate(from: controller.windowModel.pane1)

        let copy = controller.windowModel.pane2
        XCTAssertTrue(copy.isUntitled, "the copy is not on disk")
        XCTAssertEqual(controller.unsavedName(for: copy),
                       DuplicateName.next(after: copy.status.fileName,
                                          taken: [copy.status.fileName]))
    }
}
