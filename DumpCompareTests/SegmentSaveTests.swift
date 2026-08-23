import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §21.5 writing pieces out, exercised through the real `MainViewController`:
/// Save All as Separate Files… (the directory panel, the preview/overwrite
/// confirmation, and the write) and Save Segment… (one file). The panels and
/// the confirmation are driven through the controller's seams and the write
/// runs inline, so the tests assert on the preview's mapping, the
/// confirmation's inputs, and the bytes that land on disk — unsaved edits
/// included.
@MainActor
final class SegmentSaveTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    /// What a save flow leaves behind: the confirmation alert (Save All only),
    /// the panels it configured, and any error the inline write threw.
    private final class SaveCapture {
        var alert: NSAlert?
        var directoryPanel: NSOpenPanel?
        var savePanel: NSSavePanel?
        var writeError: Error?
    }

    /// A full controller whose active pane is open over `bytes`. The file's name
    /// (the base for the part names) is the URL's last component.
    private func makeController(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow, URL) {
        let url = try tempFile(bytes)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window, url)
    }

    private func cleanup(_ controller: MainViewController, _ url: URL) {
        controller.windowModel.pane1.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// A temp directory for the written pieces, removed when the test ends.
    private func makeOutputDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentSaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// The bytes of a written piece.
    private func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Captures the segments form the controller would present modally and
    /// returns it — the test drives its `saveAll`/`savePiece` closures directly.
    private func capturedForm(_ controller: MainViewController) throws -> SegmentsFormController {
        var captured: SegmentsFormController?
        controller.segmentsFormPresenter = { captured = $0 }
        controller.showSegments()
        controller.segmentsFormPresenter = nil
        return try XCTUnwrap(captured, "showSegments must present the form")
    }

    /// Wires the controller's save seams: the directory/save panels return fixed
    /// URLs (and are captured), the confirmation is captured and allowed, and the
    /// write runs inline (any error captured).
    private func wire(_ controller: MainViewController, _ capture: SaveCapture,
                      directory: URL, file: URL? = nil) {
        controller.segmentDirectoryPanel = { panel in
            capture.directoryPanel = panel
            return directory
        }
        controller.segmentSavePanel = { panel in
            capture.savePanel = panel
            return file
        }
        controller.segmentWriteConfirm = { alert in
            capture.alert = alert
            return .alertFirstButtonReturn  // Save
        }
        controller.segmentWriteRunner = { parts, storage, dir in
            do { try SegmentWriter.write(parts, from: storage, to: dir) }
            catch { capture.writeError = error }
        }
    }

    // MARK: - Save All: the preview's mapping

    /// Save All previews every part — `S<i> → <base>_S<i>.bin (size)` — chooses
    /// the folder in directory mode, and writes each piece to its own file.
    func testSaveAllPreviewsEveryPartWithItsNameAndSize() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.segmentStore.addCut(at: 8)  // S0 [0,8), S1 [8,16)
        let baseName = url.lastPathComponent

        let form = try capturedForm(controller)
        let capture = SaveCapture()
        let directory = try makeOutputDirectory()
        wire(controller, capture, directory: directory)

        let started = form.saveAll?() ?? false

        XCTAssertTrue(started, "the write started")
        XCTAssertNil(capture.writeError)
        // The folder is chosen in directory mode: directories, not files.
        let panel = try XCTUnwrap(capture.directoryPanel)
        XCTAssertTrue(panel.canChooseDirectories, "the panel chooses a directory")
        XCTAssertFalse(panel.canChooseFiles, "the panel does not choose files")
        // The preview names every part with its file name and size.
        let alert = try XCTUnwrap(capture.alert, "the confirmation was shown")
        XCTAssertTrue(alert.informativeText.contains("S0 → \(baseName)_S0.bin (8 B)"),
                      "S0 is previewed with its name and size: \(alert.informativeText)")
        XCTAssertTrue(alert.informativeText.contains("S1 → \(baseName)_S1.bin (8 B)"),
                      "S1 is previewed with its name and size")
        XCTAssertFalse(alert.informativeText.contains("will be replaced"),
                       "nothing exists yet, so nothing is replaced")
        // The write published both pieces, each holding its own bytes.
        XCTAssertEqual(try read(directory.appendingPathComponent("\(baseName)_S0.bin")),
                       Data([UInt8](0..<8)))
        XCTAssertEqual(try read(directory.appendingPathComponent("\(baseName)_S1.bin")),
                       Data([UInt8](8..<16)))
        _ = window
    }

    // MARK: - Save All: the confirmation's inputs

    /// When a target file already exists, the one confirmation names the ones
    /// that would be replaced — before anything is written — and the write then
    /// replaces it.
    func testSaveAllConfirmsTheFilesItWouldReplace() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.segmentStore.addCut(at: 8)
        let baseName = url.lastPathComponent

        let directory = try makeOutputDirectory()
        // Pre-create S0's target so the confirmation must name it.
        let s0 = directory.appendingPathComponent("\(baseName)_S0.bin")
        try Data([UInt8](repeating: 0xFF, count: 8)).write(to: s0)

        let form = try capturedForm(controller)
        let capture = SaveCapture()
        wire(controller, capture, directory: directory)

        _ = form.saveAll?() ?? false

        let alert = try XCTUnwrap(capture.alert, "the confirmation was shown")
        XCTAssertTrue(alert.informativeText.contains("will be replaced"),
                      "the confirmation names the overwrite: \(alert.informativeText)")
        XCTAssertTrue(alert.informativeText.contains("\(baseName)_S0.bin"),
                      "S0's existing file is named")
        XCTAssertFalse(alert.informativeText.contains("\(baseName)_S1.bin\n") &&
                       alert.informativeText.contains("replaced:\n\(baseName)_S1.bin"),
                       "S1 does not exist, so it is not named as replaced")
        // The existing file was replaced with the piece's bytes.
        XCTAssertEqual(try read(s0), Data([UInt8](0..<8)), "the existing file is replaced")
        _ = window
    }

    /// A cancelled confirmation writes nothing: the directory is left as it was.
    func testSaveAllCancelledConfirmationWritesNothing() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.segmentStore.addCut(at: 8)
        let baseName = url.lastPathComponent

        let directory = try makeOutputDirectory()
        let form = try capturedForm(controller)
        let capture = SaveCapture()
        controller.segmentDirectoryPanel = { _ in directory }
        controller.segmentWriteConfirm = { alert in
            capture.alert = alert
            return .alertSecondButtonReturn  // Cancel
        }
        controller.segmentWriteRunner = { parts, storage, dir in
            do { try SegmentWriter.write(parts, from: storage, to: dir) }
            catch { capture.writeError = error }
        }

        let started = form.saveAll?() ?? false

        XCTAssertFalse(started, "a cancel does not start the write")
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(entries, [], "a cancelled confirmation writes nothing")
        _ = window
        _ = baseName
    }

    // MARK: - The written content includes unsaved edits

    /// The write reads the document's current bytes, so an unsaved edit is in
    /// what lands on disk — the piece holds the edited bytes, not the file's.
    func testSaveAllWritesUnsavedEdits() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.segmentStore.addCut(at: 8)  // S0 [0,8), S1 [8,16)
        let baseName = url.lastPathComponent

        // An unsaved edit: overwrite the first two bytes.
        pane.setSelection(SelectionModel.empty(at: 0, fileSize: 16))
        try pane.pasteWrite([0xAA, 0xBB])

        let form = try capturedForm(controller)
        let capture = SaveCapture()
        let directory = try makeOutputDirectory()
        wire(controller, capture, directory: directory)

        _ = form.saveAll?() ?? false

        XCTAssertNil(capture.writeError)
        XCTAssertEqual(try read(directory.appendingPathComponent("\(baseName)_S0.bin")),
                       Data([0xAA, 0xBB, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]),
                       "the written piece includes the unsaved edit")
        XCTAssertEqual(try read(directory.appendingPathComponent("\(baseName)_S1.bin")),
                       Data([UInt8](8..<16)), "the other piece is untouched")
        _ = window
    }

    // MARK: - Save Segment…

    /// Save Segment… writes the one piece to the chosen file — the ordinary save
    /// panel, pre-filled with the base name and the piece's label.
    func testSaveSegmentWritesOnePieceToTheChosenFile() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.segmentStore.addCut(at: 8)  // S0 [0,8), S1 [8,16)
        let baseName = url.lastPathComponent

        let form = try capturedForm(controller)
        let capture = SaveCapture()
        let directory = try makeOutputDirectory()
        let target = directory.appendingPathComponent("my_piece.bin")
        wire(controller, capture, directory: directory, file: target)

        let piece = try XCTUnwrap(pane.segmentStore.segments.first { $0.index == 1 })
        let started = form.savePiece?(piece) ?? false

        XCTAssertTrue(started, "the write started")
        XCTAssertNil(capture.writeError)
        // The save panel was pre-filled with the base name and the piece's label.
        let panel = try XCTUnwrap(capture.savePanel)
        XCTAssertEqual(panel.nameFieldStringValue, "\(baseName)_S1.bin",
                       "the panel is pre-filled for the piece")
        // The piece's bytes are written to the chosen file, under the chosen name.
        XCTAssertEqual(try read(target), Data([UInt8](8..<16)),
                       "the piece's bytes are written to the chosen file")
        _ = window
    }
}
