import XCTest
import ToolModuleKit
@testable import ByteRipper

/// What a tool-module leaves behind when it stops being the one on screen, and
/// gets handed back when the user returns to it
/// (`Design/TOOL_MODULES_PLAN.md`).
///
/// The point of it is that the panel is switchable: one tool-module at a time
/// is the rule, and it only works if going to another one and back is going
/// back rather than starting over.
@MainActor
final class ToolParkedStateTests: XCTestCase {
    private var files: [URL] = []
    private var controllers: [MainViewController] = []
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
        for controller in controllers {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
        }
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        controllers = []
        files = []
        super.tearDown()
    }

    private func file(_ byte: UInt8) throws -> URL {
        let url = try tempFile([UInt8](repeating: byte, count: 0x100))
        files.append(url)
        return url
    }

    private func makeController(comparison: Bool = false) throws -> MainViewController {
        let controller = MainViewController()
        controllers.append(controller)
        let window = makeTestWindow(width: 1000, height: 600)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 600))
        try controller.windowModel.pane1.open(url: try file(0xA0))
        if comparison {
            try controller.windowModel.pane2.open(url: try file(0xB0))
            controller.apply(mode: .comparison)
        } else {
            controller.apply(mode: .singleFile)
        }
        window.layoutIfNeeded()
        return controller
    }

    private func activate(_ module: (any ToolModule.Type)?, in controller: MainViewController) {
        controller.tools.activate(module?.identifier, animated: false)
    }

    /// Parks `note` on whatever session is running now.
    private func park(_ note: String, _ log: ToolStubLog) {
        log.session?.stateToPark = StubToolState(note: note)
    }

    // MARK: - Coming back

    func testComingBackToAToolModuleHandsItsStateBack() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)
        park("rows", StubToolA.log)

        activate(nil, in: controller)
        XCTAssertEqual(controller.tools.parkedModuleIdentifiers, [StubToolA.identifier])
        activate(StubToolA.self, in: controller)

        XCTAssertEqual(StubToolA.log.restored, ["rows"])
        XCTAssertEqual(StubToolA.log.started, 2, "a second session, with the first one's state")
    }

    /// Two tool-modules, each keeping its own place. This is the whole reason
    /// the box is keyed by tool-module rather than being one slot.
    func testEachToolModuleKeepsItsOwnPlace() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)
        park("a-rows", StubToolA.log)
        activate(StubToolB.self, in: controller)
        park("b-rows", StubToolB.log)

        activate(StubToolA.self, in: controller)
        activate(StubToolB.self, in: controller)

        XCTAssertEqual(StubToolA.log.restored, ["a-rows"])
        XCTAssertEqual(StubToolB.log.restored, ["b-rows"])
    }

    /// The default is to keep nothing, which is right for a panel that is a
    /// function of the file — and a tool-module gets that without writing a
    /// line.
    func testAToolModuleThatKeepsNothingIsHandedNothing() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)

        activate(nil, in: controller)
        XCTAssertTrue(controller.tools.parkedModuleIdentifiers.isEmpty)
        activate(StubToolA.self, in: controller)

        XCTAssertTrue(StubToolA.log.restored.isEmpty)
        XCTAssertEqual(StubToolA.log.started, 2)
    }

    /// Handed over, not copied: the state belongs to the session that got it,
    /// and what comes back next time is whatever *that* session leaves.
    func testTheStateIsHandedOverOnlyOnce() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)
        park("rows", StubToolA.log)
        activate(nil, in: controller)
        activate(StubToolA.self, in: controller)

        // The second session parks nothing of its own.
        activate(nil, in: controller)
        activate(StubToolA.self, in: controller)

        XCTAssertEqual(StubToolA.log.restored, ["rows"])
    }

    // MARK: - When it is dropped

    /// A parked selection in a file that has been closed is a selection in a
    /// file nobody has any more.
    func testClosingTheFileForgetsWhatWasParked() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)
        park("rows", StubToolA.log)

        controller.closePane(at: 0)

        XCTAssertTrue(controller.tools.parkedModuleIdentifiers.isEmpty)
    }

    /// A revert, a change from outside, a join: the running tool-module is told
    /// and re-reads, and the parked ones have no way to hear it.
    func testReplacingTheContentForgetsWhatWasParked() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)
        park("rows", StubToolA.log)
        activate(nil, in: controller)
        XCTAssertFalse(controller.tools.parkedModuleIdentifiers.isEmpty)

        controller.windowModel.pane1.onFullInvalidation?()

        XCTAssertTrue(controller.tools.parkedModuleIdentifiers.isEmpty)
    }

    /// Ordinary editing does not: an edit is what a tool-module is for, and the
    /// state is a hint the next session checks rather than a copy of the bytes.
    func testAnEditDoesNotForgetWhatWasParked() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)
        park("rows", StubToolA.log)
        activate(nil, in: controller)

        try controller.windowModel.pane1.pasteWrite([0x01])
        controller.tools.flushPendingChangeForTesting()

        XCTAssertEqual(controller.tools.parkedModuleIdentifiers, [StubToolA.identifier])
    }

    /// The state describes one file. The other pane is another file, so the
    /// tool-module opens there with nothing.
    func testStateParkedOnOnePaneIsNotHandedToTheOther() throws {
        let controller = try makeController(comparison: true)
        activate(StubToolA.self, in: controller)
        XCTAssertIdentical(controller.tools.boundPane, controller.windowModel.pane1)
        park("left", StubToolA.log)
        activate(nil, in: controller)

        controller.windowModel.setActivePane(1)
        activate(StubToolA.self, in: controller)

        XCTAssertIdentical(controller.tools.boundPane, controller.windowModel.pane2)
        XCTAssertTrue(StubToolA.log.restored.isEmpty)
        XCTAssertTrue(controller.tools.parkedModuleIdentifiers.isEmpty, "and it is not kept for later")
    }

    /// A pane moved into another tab takes its file with it, so what was parked
    /// against it here is about a file this tab no longer shows.
    func testAPaneLeavingForgetsWhatWasParked() throws {
        let source = try makeController(comparison: true)
        let destination = try makeController()
        source.windowModel.setActivePane(1)
        activate(StubToolA.self, in: source)
        park("right", StubToolA.log)
        activate(nil, in: source)

        destination.adoptPane(source.releasePane(at: 1), bookmarks: [])

        XCTAssertTrue(source.tools.parkedModuleIdentifiers.isEmpty)
    }
}
