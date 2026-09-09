import XCTest
import UEFIImage
import UEFITool
import UEFIToolUI
@testable import DumpCompare

/// The UEFI Structure tool's checksum pass end to end in the app: a volume whose
/// checksum a fixture corrupts, the red `(Invalid)` the detail then reads, the
/// node the session flags, and the Fix Checksum seam that rewrites the byte as
/// one undoable step and clears itself on the re-read its own write caused.
///
/// The tree icon and the context menu cannot be simulated — a right-click and
/// an inline text attachment are not things XCTest can drive — so what is
/// tested is the state that drives them: the session's `checksumProblems` and
/// the detail's `(Invalid)`/`(Valid)` text, and the seam the menu item calls.
@MainActor
final class UEFIChecksumFlowTests: XCTestCase {
    private var files: [URL] = []
    private var controller: MainViewController?
    private var window: NSWindow?
    private var defaultsName: String?

    override func setUp() {
        super.setUp()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        controller = nil
        window = nil
        files = []
        super.tearDown()
    }

    /// Opens an image and switches the UEFI tool on, waiting for the first parse
    /// — which happens off the main actor — to land.
    private func open(_ bytes: [UInt8]) throws -> MainViewController {
        let url = try tempFile(bytes)
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1200, height: 700)
        self.window = window
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1200, height: 700))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window.layoutIfNeeded()
        try waitForDisplay()
        return controller
    }

    /// Opens a *file on disk* — the read-only tests need real permissions — and
    /// switches the UEFI tool on the same way `open(_:)` does.
    private func openReadOnly(_ url: URL) throws {
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1200, height: 700)
        self.window = window
        window.contentViewController = controller
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window.layoutIfNeeded()
        try waitForDisplay()
    }

    /// Waits on the session's own seam rather than on the clock. With an
    /// expectation already installed this is also what a fix's re-parse is
    /// waited on: the write lands, the module re-reads, and the display is
    /// published again.
    private func waitForDisplay() throws {
        let session = try session()
        let parsed = expectation(description: "the UEFI parse lands")
        session.onDisplay = { _ in parsed.fulfill() }
        wait(for: [parsed], timeout: 5)
        session.onDisplay = nil
        window?.layoutIfNeeded()
    }

    private func session() throws -> UEFIToolSession {
        try XCTUnwrap(controller?.tools.session as? UEFIToolSession)
    }

    private func outline() throws -> NSOutlineView {
        let panel = try XCTUnwrap(controller?.tools.panel)
        return try XCTUnwrap(descendants(of: panel, NSOutlineView.self).first)
    }

    /// The detail's checksum rows read `(Valid)`/`(Invalid)` after the value.
    /// The fixture is a valid volume, so `make()` is the value a fix must
    /// restore.
    private func volumeChecksumBytes(of image: [UInt8]) -> [UInt8] {
        // The volume is the one root of the image, its header at 0x00 and its
        // checksum stored at 0x32..0x34 (§3.3, VolumeParser.checksumOffset).
        Array(image[0x32..<0x34])
    }

    /// The field a parse flags, found by kind so the tests do not assert on an
    /// id scheme that is the parser's to choose.
    private func nodeFlagged(with field: UEFIChecksumField) throws -> (NodeID, Set<UEFIChecksumField>) {
        let problems = try session().checksumProblems
        let entry = try XCTUnwrap(
            problems.first { $0.value.contains(field) },
            "a node should be flagged for \(field), got \(problems)"
        )
        return (entry.key, entry.value)
    }

    /// A corrupted volume checksum reaches the panel as a red reading, not only
    /// as a private flag: the volume's detail row says `(Invalid)`.
    func testACorruptedVolumeChecksumIsFlaggedAndReadsInvalid() throws {
        var image = UEFITestImage.make()
        image[0x32] ^= 0xFF
        _ = try open(image)
        let (_, fields) = try nodeFlagged(with: .volume)
        XCTAssertEqual(fields, [.volume])

        // The volume is the root the tree folded into the title, so it is read
        // through the click the title stands in for.
        try session().showTopNode()
        let text = descendants(of: try XCTUnwrap(controller?.tools.panel), NSTextField.self)
            .map(\.stringValue)
        XCTAssertTrue(text.contains { $0.hasSuffix("(Invalid)") }, "\(text)")
    }

    /// Fix Checksum recomputes the volume's checksum from the *current* bytes,
    /// writes it as one named undo step, and the re-read its own write caused
    /// stops flagging the node and turns the detail back to `(Valid)`.
    func testFixingAVolumeChecksumWritesTheByteAndClearsTheFlag() throws {
        let pristine = UEFITestImage.make()
        var corrupt = pristine
        corrupt[0x32] ^= 0xFF
        let controller = try open(corrupt)
        let volumeID = try nodeFlagged(with: .volume).0
        let pane = controller.windowModel.pane1

        // Install the expectation first: the fix re-parses off the main actor,
        // and the display it republishes is what says the node cleared.
        let fixed = expectation(description: "the fix's re-parse lands")
        try session().onDisplay = { _ in fixed.fulfill() }
        try session().fixChecksum(for: volumeID)
        wait(for: [fixed], timeout: 5)
        try session().onDisplay = nil

        XCTAssertNil(try session().checksumProblems[volumeID],
                     "the node is no longer flagged once its checksum checks out")
        XCTAssertEqual(try pane.byteStorage?.read(at: 0x32, length: 2),
                       volumeChecksumBytes(of: pristine),
                       "the write restored the value the fixture computed")

        // One named undo step takes it back.
        let item = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit),
                              keyEquivalent: "z")
        _ = controller.validateMenuItem(item)
        XCTAssertEqual(item.title, "Undo Fix Checksum")

        // Focus the volume — the root the tree folded into the title — and the
        // detail now reads the checksum as right, while the notice the fix
        // earned survives the very re-read its own write caused.
        try session().showTopNode()
        let panel = try XCTUnwrap(controller.tools.panel)
        let note = descendants(of: panel, NSTextField.self).map(\.stringValue)
        XCTAssertTrue(note.contains { $0.contains("Checksum written") }, "\(note)")
        XCTAssertTrue(note.contains { $0.hasSuffix("(Valid)") }, "\(note)")
        XCTAssertFalse(note.contains { $0.hasSuffix("(Invalid)") }, "\(note)")
    }

    /// A file the user cannot write is one the tool cannot write either: the
    /// refusal leaves the corrupt byte alone and the flag in place.
    func testAFixRefusesOnAReadOnlyFile() throws {
        var corrupt = UEFITestImage.make()
        corrupt[0x32] ^= 0xFF
        let url = try tempFile(corrupt)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        try openReadOnly(url)
        let (volumeID, _) = try nodeFlagged(with: .volume)

        try session().fixChecksum(for: volumeID)

        XCTAssertEqual(try session().checksumProblems[volumeID]?.contains(.volume), true,
                       "the refusal wrote nothing, so the flag stays")
        let host = try XCTUnwrap(controller?.windowModel.pane1)
        XCTAssertEqual(try host.byteStorage?.read(at: 0x32, length: 2), volumeChecksumBytes(of: corrupt),
                       "no byte changed")
    }

    /// The icon a flagged row wears in the tree is an SF Symbol riding inside
    /// the name as a text attachment — so a flagged file (a row that exists, a
    /// file being visible where a folded-away volume is not) shows one, and a
    /// clean row shows plain text with no stale triangle from a recycled cell.
    func testAFlaggedFileRowWearsAWarningAndACleanOneDoesNot() throws {
        var image = UEFITestImage.make()
        // The file's body-checksum field is at 0x11 of its header, the file at
        // 0x48: 0x59. Under a revision-2 volume with the checksum bit unset the
        // field must read the fixed 0xAA, so a 0 breaks it (§5.4).
        image[0x59] = 0
        _ = try open(image)
        try nodeFlagged(with: .fileBody)
        let outline = try outline()

        func nameCell(of row: Int) throws -> NSTextField {
            let cell = try XCTUnwrap(
                outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                "the tree is view-based"
            )
            return try XCTUnwrap(cell.textField, "the cell shows its text in a field")
        }

        // The file is the top row — the volume that held it folded into the
        // title — so its name cell is the flagged one.
        let flagged = try nameCell(of: 0)
        var range = NSRange(location: 0, length: 0)
        XCTAssertNotNil(flagged.attributedStringValue.attribute(.attachment, at: 0, effectiveRange: &range),
                        "the row's name leads with the warning triangle")

        // A clean row beside it — the padding under the file — shows plain text
        // with no stale triangle from a shared cell pool.
        let clean = try nameCell(of: 1)
        range = NSRange(location: 0, length: 0)
        XCTAssertNil(clean.attributedStringValue.attribute(.attachment, at: 0, effectiveRange: &range),
                     "a row that checks out shows no triangle")
    }
}
