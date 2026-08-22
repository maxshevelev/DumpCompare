import DumpCompareCore
import XCTest
@testable import DumpCompare

/// File > New File (not in REQUIREMENTS.md): an untitled in-memory document —
/// nothing is written to disk until the first Save / Save As. The pane reports
/// "Untitled" with a "document.badge.plus" glyph in the header.
@MainActor
final class UntitledFileTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("untitled-\(UUID().uuidString)-\(name)")
    }

    /// The pane's document glyph: the NSImageView inside the PaneHeaderView.
    private func documentIcon(of pane: FilePaneView) throws -> NSImageView {
        let header = try XCTUnwrap(descendants(of: pane, PaneHeaderView.self).first)
        return try XCTUnwrap(descendants(of: header, NSImageView.self).first,
                             "the header must contain the document glyph")
    }

    // MARK: - Pane-level behavior

    func testUntitledPaneStartsCleanAndEmpty() {
        let pane = PaneViewModel()
        pane.openUntitled()
        defer { pane.close() }

        XCTAssertTrue(pane.isOpen)
        XCTAssertTrue(pane.isUntitled)
        XCTAssertEqual(pane.status.fileName, "Untitled")
        XCTAssertEqual(pane.fileSize, 0)
        XCTAssertFalse(pane.status.isDirty)
    }

    func testTypingMarksUntitledDirtyButNotRedForeground() {
        let pane = PaneViewModel()
        pane.openUntitled()
        defer { pane.close() }

        pane.typeHexNibble(0xA)
        pane.typeHexNibble(0xB)

        XCTAssertTrue(pane.status.isDirty, "editing an untitled file must mark it modified")
        XCTAssertEqual(pane.fileSize, 1)
        // No on-disk reference exists, so bytes must not be red-foreground
        // "modified" — the dirty marker in the header conveys the unsaved state.
        let states = pane.hexByteStates(in: 0..<1)
        XCTAssertEqual(states.first?.byte, 0xAB)
        XCTAssertFalse(states.first?.isModified ?? true)
    }

    func testUndoWorksOnUntitledDocument() throws {
        let pane = PaneViewModel()
        pane.openUntitled()
        defer { pane.close() }

        pane.typeHexNibble(0x1)
        pane.typeHexNibble(0x2)
        XCTAssertEqual(pane.fileSize, 1)

        XCTAssertTrue(try pane.undo())
        XCTAssertEqual(pane.fileSize, 0)
        XCTAssertFalse(pane.status.isDirty)
    }

    func testSaveOnUntitledRequiresLocation() {
        let pane = PaneViewModel()
        pane.openUntitled()
        defer { pane.close() }
        pane.typeASCII(0x41)

        XCTAssertThrowsError(try pane.save()) { error in
            XCTAssertTrue(error is PaneSaveError,
                          "an untitled document must refuse to save to its placeholder URL")
        }
    }

    func testSaveAsRebasesUntitledToRealFileAndClearsDirty() throws {
        let pane = PaneViewModel()
        pane.openUntitled()
        let url = tempURL("saved.bin")
        defer {
            pane.close()
            try? FileManager.default.removeItem(at: url)
        }

        pane.typeHexNibble(0xC)
        pane.typeHexNibble(0xD)
        XCTAssertTrue(pane.status.isDirty)

        try pane.saveAs(to: url)

        XCTAssertFalse(pane.isUntitled, "after Save As the pane is a normal file document")
        XCTAssertEqual(pane.status.fileName, url.lastPathComponent)
        XCTAssertFalse(pane.status.isDirty)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xCD]),
                       "the buffer content must be written to the chosen file")
    }

    // MARK: - Pane header (§3.4)

    func testUntitledHeaderShowsPlusBadgeAndUntitledName() throws {
        let viewModel = PaneViewModel()
        viewModel.openUntitled()
        let pane = FilePaneView(viewModel: viewModel)
        defer { viewModel.close() }
        _ = try documentIcon(of: pane)

        XCTAssertEqual(viewModel.status.fileName, "Untitled")
        XCTAssertEqual(pane.documentSymbolName, "document.badge.plus",
                       "a clean untitled file carries the outline plus badge")
    }

    func testUntitledHeaderFillsAfterEdit() throws {
        let viewModel = PaneViewModel()
        viewModel.openUntitled()
        let pane = FilePaneView(viewModel: viewModel)
        defer { viewModel.close() }
        _ = try documentIcon(of: pane)
        XCTAssertEqual(pane.documentSymbolName, "document.badge.plus")

        viewModel.typeHexNibble(0xB)
        viewModel.typeHexNibble(0x7)

        XCTAssertEqual(pane.documentSymbolName, "document.badge.plus.fill",
                       "an edited untitled file keeps its plus badge and fills it")
    }

    func testSaveAsSwitchesHeaderBackToDocumentGlyph() throws {
        let viewModel = PaneViewModel()
        viewModel.openUntitled()
        let pane = FilePaneView(viewModel: viewModel)
        let url = tempURL("saved.bin")
        defer {
            viewModel.close()
            try? FileManager.default.removeItem(at: url)
        }
        _ = try documentIcon(of: pane)

        viewModel.typeHexNibble(0xC)
        viewModel.typeHexNibble(0xD)
        XCTAssertEqual(pane.documentSymbolName, "document.badge.plus.fill")

        try viewModel.saveAs(to: url)

        XCTAssertEqual(pane.documentSymbolName, "document",
                       "a saved untitled file is a normal clean file again")
    }
}
