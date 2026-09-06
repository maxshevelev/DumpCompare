import XCTest
import ToolModuleKit
@testable import DumpCompare

/// A tool-module asking the user for a file, and offering one back
/// (`Design/TOOL_MODULES_PLAN.md`).
///
/// Both go through the app's own panels, which is the point: what the user
/// picks is reachable because this process was granted it, and a tool-module
/// gets bytes rather than a URL it would have to hold a security scope for.
@MainActor
final class ToolFileTests: XCTestCase {
    private var files: [URL] = []
    private var controller: MainViewController?
    private var defaultsName: String?

    override func setUp() {
        super.setUp()
        installToolStubs()
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
        files = []
        super.tearDown()
    }

    private func makeHost() throws -> (any ToolHost, MainViewController) {
        let url = try tempFile([UInt8](repeating: 0xFF, count: 0x40))
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 900, height: 600)
        window.contentViewController = controller
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(StubToolA.identifier, animated: false)
        return (try XCTUnwrap(StubToolA.log.session).host, controller)
    }

    func testAPickedFileArrivesAsNameAndBytes() async throws {
        let (host, controller) = try makeHost()
        let picked = try tempFile([0x01, 0x02, 0x03, 0x04])
        files.append(picked)
        controller.toolOpenPanel = { _ in picked }

        let file = await host.requestFile(kinds: ["bin"])

        XCTAssertEqual(file?.name, picked.lastPathComponent)
        XCTAssertEqual(file?.bytes, [0x01, 0x02, 0x03, 0x04])
    }

    func testCancellingThePanelHandsBackNothing() async throws {
        let (host, controller) = try makeHost()
        controller.toolOpenPanel = { _ in nil }

        let file = await host.requestFile(kinds: [])

        XCTAssertNil(file)
    }

    /// The kinds a tool-module asks for reach the panel, so the user is not
    /// offered everything on the disk.
    func testTheKindsReachThePanel() async throws {
        let (host, controller) = try makeHost()
        var offered: [String] = []
        controller.toolOpenPanel = { panel in
            offered = panel.allowedContentTypes.compactMap(\.preferredFilenameExtension)
            return nil
        }

        _ = await host.requestFile(kinds: ["bin", "rom"])

        XCTAssertEqual(offered, ["bin", "rom"])
    }

    /// A mistaken pick — a disk image, a video — is refused with a sentence
    /// rather than read into memory whole.
    func testAFileOverTheLimitIsRefused() async throws {
        let (host, controller) = try makeHost()
        let big = try tempFile([UInt8](repeating: 0, count: 16))
        files.append(big)
        controller.toolOpenPanel = { _ in big }
        // The cap, moved under the file rather than a 64 MiB fixture.
        let limit = MainViewController.toolFileSizeLimitForTesting
        MainViewController.toolFileSizeLimitForTesting = 8
        defer { MainViewController.toolFileSizeLimitForTesting = limit }

        let file = await host.requestFile(kinds: [])

        XCTAssertNil(file)
    }

    func testExportWritesTheBytesTheToolModuleOffered() async throws {
        let (host, controller) = try makeHost()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-export-\(UUID().uuidString).bin")
        files.append(destination)
        var suggested: String?
        controller.toolSavePanel = { panel in
            suggested = panel.nameFieldStringValue
            return destination
        }

        let wrote = await host.exportFile([0xAA, 0xBB], suggestedName: "region.bin")

        XCTAssertTrue(wrote)
        XCTAssertEqual(suggested, "region.bin")
        XCTAssertEqual([UInt8](try Data(contentsOf: destination)), [0xAA, 0xBB])
    }

    func testCancellingTheSavePanelWritesNothing() async throws {
        let (host, controller) = try makeHost()
        controller.toolSavePanel = { _ in nil }

        let wrote = await host.exportFile([0xAA], suggestedName: "region.bin")

        XCTAssertFalse(wrote)
    }
}
