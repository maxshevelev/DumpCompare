import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.4 pane header: a system document glyph sits before the file name —
/// "document" (outline) while the file is clean, "document.fill" once there
/// are unsaved changes. The fill replaces the "*" the title used to append.
@MainActor
final class PaneHeaderIconTests: XCTestCase {
    /// The pane's document glyph: the NSImageView inside the PaneHeaderView.
    private func documentIcon(of pane: FilePaneView) throws -> NSImageView {
        let header = try XCTUnwrap(descendants(of: pane, PaneHeaderView.self).first)
        return try XCTUnwrap(descendants(of: header, NSImageView.self).first,
                             "the header must contain the document glyph")
    }

    /// A pane with a small file open.
    private func makePane(_ bytes: [UInt8]) throws -> (FilePaneView, URL) {
        let url = try tempFile(bytes)
        let viewModel = PaneViewModel()
        try viewModel.open(url: url)
        let pane = FilePaneView(viewModel: viewModel)
        return (pane, url)
    }

    func testHeaderShowsDocumentGlyphBeforeTheName() throws {
        let (pane, url) = try makePane([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        let icon = try documentIcon(of: pane)
        XCTAssertNotNil(icon.image, "the header must render a document glyph")
        XCTAssertEqual(pane.documentSymbolName, "document")
    }

    func testEditingSwitchesToDocumentFill() throws {
        let (pane, url) = try makePane([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        try documentIcon(of: pane)
        XCTAssertEqual(pane.documentSymbolName, "document")

        pane.viewModel.moveCaret(to: 0)
        pane.viewModel.typeHexNibble(0xA)
        pane.viewModel.typeHexNibble(0x5)
        XCTAssertEqual(pane.documentSymbolName, "document.fill",
                       "an unsaved edit must switch the glyph to document.fill")
    }

    func testSavingRevertsToDocumentOutline() throws {
        let (pane, url) = try makePane([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        try documentIcon(of: pane)

        pane.viewModel.moveCaret(to: 0)
        pane.viewModel.typeHexNibble(0xA)
        pane.viewModel.typeHexNibble(0x5)
        XCTAssertEqual(pane.documentSymbolName, "document.fill")

        try pane.viewModel.save()
        XCTAssertEqual(pane.documentSymbolName, "document",
                       "saving clears the dirty state, so the glyph returns to the outline")
    }
}
