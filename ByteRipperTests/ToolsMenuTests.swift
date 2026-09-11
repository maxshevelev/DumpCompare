import XCTest
import ToolModuleKit
@testable import ByteRipper

/// The Tools menu and the registry behind it (`Design/TOOL_MODULES_PLAN.md`).
@MainActor
final class ToolsMenuTests: XCTestCase {
    private func makeController(open: Bool) throws -> (MainViewController, NSWindow, URL?) {
        let controller = MainViewController()
        let window = makeTestWindow()
        window.contentViewController = controller
        guard open else { return (controller, window, nil) }
        let url = try tempFile([0x41, 0x42, 0x43])
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        return (controller, window, url)
    }

    private func item(_ menu: NSMenu, _ title: String) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title }, "a “\(title)” item")
    }

    func testTheMenuListsEveryModuleTheRegistryHoldsInItsOrder() {
        installToolStubs()

        let titles = MainMenu.makeToolsMenu().items.map(\.title)

        XCTAssertEqual(titles, ["None", "", "Stub A", "Stub B"],
                       "None first, then a separator, then the registry's order")
    }

    /// Nothing installed is a menu with nothing but None in it — which is what
    /// the app ships with until the first tool-module lands.
    func testWithNothingInstalledTheMenuOffersOnlyNone() {
        installToolStubs([])

        XCTAssertEqual(MainMenu.makeToolsMenu().items.map(\.title), ["None"])
    }

    /// The row carries the tool-module it stands for, so the action never has
    /// to match on a title.
    func testEachRowCarriesItsModulesIdentifier() throws {
        installToolStubs()
        let menu = MainMenu.makeToolsMenu()

        XCTAssertEqual(try item(menu, "Stub A").representedObject as? String, StubToolA.identifier)
        XCTAssertNil(try item(menu, "None").representedObject)
    }

    func testNoneIsCheckedUntilAModuleIsPicked() throws {
        installToolStubs()
        let (controller, _, url) = try makeController(open: true)
        defer { controller.windowModel.pane1.close(); try? url.map(FileManager.default.removeItem(at:)) }
        let menu = MainMenu.makeToolsMenu()
        let none = try item(menu, "None")
        let stubA = try item(menu, "Stub A")

        _ = controller.validateMenuItem(none)
        _ = controller.validateMenuItem(stubA)

        XCTAssertEqual(none.state, .on)
        XCTAssertEqual(stubA.state, .off)
    }

    func testPickingAModuleChecksItAndUnchecksNone() throws {
        installToolStubs()
        let (controller, _, url) = try makeController(open: true)
        defer { controller.windowModel.pane1.close(); try? url.map(FileManager.default.removeItem(at:)) }
        let menu = MainMenu.makeToolsMenu()
        let none = try item(menu, "None")
        let stubA = try item(menu, "Stub A")

        controller.activateTool(stubA)

        _ = controller.validateMenuItem(none)
        _ = controller.validateMenuItem(stubA)
        XCTAssertEqual(controller.tools.activeIdentifier, StubToolA.identifier)
        XCTAssertEqual(stubA.state, .on)
        XCTAssertEqual(none.state, .off)
    }

    func testNonePutsTheChoiceBack() throws {
        installToolStubs()
        let (controller, _, url) = try makeController(open: true)
        defer { controller.windowModel.pane1.close(); try? url.map(FileManager.default.removeItem(at:)) }
        let menu = MainMenu.makeToolsMenu()
        controller.activateTool(try item(menu, "Stub A"))

        controller.activateTool(try item(menu, "None"))

        XCTAssertNil(controller.tools.activeIdentifier)
    }

    /// A tool-module reads and writes the open file, so with none open there is
    /// nothing for it to do.
    func testAModuleNeedsAFileOpen() throws {
        installToolStubs()
        let (controller, _, _) = try makeController(open: false)
        let stubA = try item(MainMenu.makeToolsMenu(), "Stub A")

        XCTAssertFalse(controller.validateMenuItem(stubA))
    }

    /// None must never be the item that is greyed out: it is how the panel is
    /// closed.
    func testNoneStaysAvailableWithNoFileOpen() throws {
        installToolStubs()
        let (controller, _, _) = try makeController(open: false)
        let none = try item(MainMenu.makeToolsMenu(), "None")

        XCTAssertTrue(controller.validateMenuItem(none))
    }

    /// A choice can outlive the build that had that tool-module in it, and what
    /// it must not do is leave the tab pointing at nothing.
    func testAnIdentifierNothingAnswersToReadsAsNone() {
        installToolStubs()
        let tools = ToolController()

        tools.activate("dev.maxik.tool.removed")

        XCTAssertNil(tools.activeIdentifier)
        XCTAssertNil(tools.activeModule)
    }

    func testTheRegistryFindsAModuleByItsIdentifier() {
        installToolStubs()

        XCTAssertTrue(ToolRegistry.module(identified: StubToolB.identifier) is StubToolB.Type)
        XCTAssertNil(ToolRegistry.module(identified: "nobody"))
    }
}
