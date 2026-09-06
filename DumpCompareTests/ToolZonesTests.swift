import XCTest
import ToolModuleKit
@testable import DumpCompare

/// Zones on screen: what a published map does to the dump
/// (`Design/TOOL_MODULES_PLAN.md`).
@MainActor
final class ToolZonesTests: XCTestCase {
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

    private func makeController() throws -> (MainViewController, NSWindow) {
        let url = try tempFile([UInt8](repeating: 0xAA, count: 0x400))
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1000, height: 700)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 700))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func host(_ controller: MainViewController) throws -> any ToolHost {
        controller.tools.activate(StubToolA.identifier, animated: false)
        return try XCTUnwrap(StubToolA.log.session).host
    }

    private func hexView(_ window: NSWindow) throws -> HexView {
        try XCTUnwrap(descendants(of: window.contentView!, HexView.self).first)
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// How many pixels differ between two renders inside `rect`.
    ///
    /// A difference rather than a colour: what the test is about is that
    /// publishing a map changes the dump where the zone is and leaves it alone
    /// everywhere else, and asking "is this pixel teal enough" means guessing
    /// what a translucent, anti-aliased stroke blends to over whatever was
    /// under it.
    private func changedPixels(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep,
                               in rect: NSRect, of view: NSView) -> Int {
        let scale = CGFloat(before.pixelsWide) / max(view.bounds.width, 1)
        var changed = 0
        for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 1) {
            for y in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 1) {
                guard x >= 0, y >= 0, x < before.pixelsWide, y < before.pixelsHigh,
                      let old = before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let new = after.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(old.redComponent - new.redComponent) > 0.02
                    || abs(old.greenComponent - new.greenComponent) > 0.02
                    || abs(old.blueComponent - new.blueComponent) > 0.02 {
                    changed += 1
                }
            }
        }
        return changed
    }

    // MARK: - The map reaches the pane

    func testAPublishedMapReachesThePaneTheSessionIsBoundTo() throws {
        let (controller, _) = try makeController()
        let host = try host(controller)

        host.publish(ZoneMap(zones: [Zone(id: "fv", name: "Volume", range: 0x20..<0x60)],
                             focus: "fv"))

        XCTAssertEqual(controller.windowModel.pane1.zones.zones.map(\.name), ["Volume"])
        XCTAssertEqual(controller.windowModel.pane1.hexZoneSpans(in: 0..<0x100).map(\.isFocused),
                       [true])
    }

    /// The dump asks per drawn range, like the pieces and the matches do.
    func testOnlyTheZonesReachingTheDrawnRangeAreHandedOver() throws {
        let (controller, _) = try makeController()
        let host = try host(controller)
        host.publish(ZoneMap(zones: [Zone(id: "a", name: "A", range: 0x00..<0x10),
                                     Zone(id: "b", name: "B", range: 0x300..<0x310)]))

        let spans = controller.windowModel.pane1.hexZoneSpans(in: 0x100..<0x200)

        XCTAssertTrue(spans.isEmpty)
        XCTAssertEqual(controller.windowModel.pane1.hexZoneSpans(in: 0x00..<0x100).map(\.name), ["A"])
    }

    /// Nothing else draws zones, so when the session goes the dump must stop
    /// showing a tool-module's reading of a file after that tool-module has gone.
    func testEndingTheSessionTakesTheMapOffTheDump() throws {
        let (controller, _) = try makeController()
        let host = try host(controller)
        host.publish(ZoneMap(zones: [Zone(id: "fv", name: "Volume", range: 0x20..<0x60)]))

        controller.tools.activate(nil, animated: false)

        XCTAssertTrue(controller.windowModel.pane1.zones.zones.isEmpty)
        XCTAssertTrue(controller.windowModel.pane1.hexZoneSpans(in: 0..<0x400).isEmpty)
    }

    /// A map that changed has to be repainted, and the dump does not know when
    /// one arrives except by being told.
    func testAPublishAsksTheDumpToRepaint() throws {
        let (controller, window) = try makeController()
        let host = try host(controller)
        let hexView = try hexView(window)
        hexView.displayIfNeeded()
        XCTAssertFalse(hexView.needsDisplay, "precondition: nothing pending")

        host.publish(ZoneMap(zones: [Zone(id: "fv", name: "Volume", range: 0x20..<0x60)]))

        XCTAssertTrue(hexView.needsDisplay)
    }

    // MARK: - On screen

    /// The outline is actually drawn, over the bytes the zone covers — and not
    /// over the bytes it does not.
    func testTheZoneIsDrawnWhereItIsAndNowhereElse() throws {
        let (controller, window) = try makeController()
        let host = try host(controller)
        let hexView = try hexView(window)
        hexView.displayIfNeeded()
        let before = try render(hexView)

        host.publish(ZoneMap(zones: [Zone(id: "fv", name: "Volume", range: 0x00..<0x20)],
                             focus: "fv"))
        hexView.displayIfNeeded()
        let after = try render(hexView)

        let layout = hexView.hexLayout
        XCTAssertGreaterThan(changedPixels(before, after, in: layout.rowFrame(row: 0), of: hexView), 50,
                             "the zone's first row is drawn differently once it exists")
        XCTAssertEqual(changedPixels(before, after, in: layout.rowFrame(row: 8), of: hexView), 0,
                       "a row outside the zone is untouched")
    }

    /// A map of a dozen regions drawn as loudly as each other is a cage over
    /// the bytes, so only the focused one is at full strength.
    func testTheFocusedZoneIsStrokedMoreStronglyThanTheRest() throws {
        XCTAssertGreaterThan(HexView.zoneFocusedAlpha, HexView.zoneAlpha)
    }

    /// The wash marks the one region being worked on. The others say where they
    /// are with an outline: a dozen washes, nested, would stack pale teal on
    /// pale teal until the dump read as a colour rather than as bytes.
    func testOnlyTheFocusedZoneIsWashed() throws {
        let (controller, window) = try makeController()
        let host = try host(controller)
        let hexView = try hexView(window)
        hexView.displayIfNeeded()
        let before = try render(hexView)

        host.publish(ZoneMap(zones: [
            Zone(id: "outer", name: "Outer", range: 0x00..<0x90),
            Zone(id: "inner", name: "Inner", range: 0x30..<0x60)
        ], focus: "inner"))
        hexView.displayIfNeeded()
        let after = try render(hexView)

        let layout = hexView.hexLayout
        XCTAssertGreaterThan(
            changedPixels(before, after, in: interior(layout, row: 4), of: hexView), 200,
            "the focused zone's middle row is washed"
        )
        XCTAssertEqual(
            changedPixels(before, after, in: interior(layout, row: 7), of: hexView), 0,
            "a row well inside an unfocused zone keeps its paper"
        )
    }

    /// A band across the middle of a row's hex cells, clear of the outline that
    /// runs down either side of a zone — so what it measures is the fill.
    private func interior(_ layout: HexLayout, row: Int) -> NSRect {
        let first = layout.hexByteFrame(row: row, column: 2)
        let last = layout.hexByteFrame(row: row, column: 13)
        return NSRect(x: first.minX, y: first.minY + 2,
                      width: last.maxX - first.minX, height: first.height - 4)
    }

    // MARK: - Picking a zone in the dump

    /// A right-click inside a zone offers that zone by name — the one way the
    /// user has of reaching a tool-module's map from the dump itself.
    func testARightClickInsideAZoneOffersItByName() throws {
        let (controller, _) = try makeController()
        let host = try host(controller)
        host.publish(ZoneMap(zones: [Zone(id: "fv", name: "FFSv2", range: 0x100..<0x200)]))

        let menu = controller.makeOffsetMenu(for: controller.windowModel.pane1, offset: 0x180)

        XCTAssertTrue(menu.items.contains { $0.title == "Select Zone “FFSv2”" })
    }

    /// Most files have no zones at all, and a menu should say nothing about
    /// what is not there.
    func testARightClickOutsideEveryZoneOffersNothing() throws {
        let (controller, _) = try makeController()
        let host = try host(controller)
        host.publish(ZoneMap(zones: [Zone(id: "fv", name: "FFSv2", range: 0x100..<0x200)]))

        let menu = controller.makeOffsetMenu(for: controller.windowModel.pane1, offset: 0x300)

        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("Select Zone") })
    }

    /// Zones nest — a table, a row in it, what the row points at — so a byte is
    /// often inside several. All of them are offered, innermost first, because
    /// the smallest one under the pointer is what is being aimed at.
    func testOverlappingZonesBecomeASubmenuInnermostFirst() throws {
        let (controller, _) = try makeController()
        let host = try host(controller)
        host.publish(ZoneMap(zones: [
            Zone(id: "table", name: "FIT table", range: 0x100..<0x200),
            Zone(id: "row", name: "#1 Microcode", range: 0x110..<0x120)
        ]))

        let menu = controller.makeOffsetMenu(for: controller.windowModel.pane1, offset: 0x118)
        let parent = try XCTUnwrap(menu.items.first { $0.title == "Select Zone" })

        XCTAssertEqual(parent.submenu?.items.map(\.title), ["#1 Microcode", "FIT table"])
    }

    /// Picking one selects its bytes — that is the host's own doing — and tells
    /// the tool-module, which is the only side that knows what the zone stands
    /// for.
    func testPickingAZoneSelectsItsBytesAndTellsTheModule() throws {
        let (controller, _) = try makeController()
        let host = try host(controller)
        host.publish(ZoneMap(zones: [Zone(id: "fv", name: "FFSv2", range: 0x100..<0x200)]))
        let menu = controller.makeOffsetMenu(for: controller.windowModel.pane1, offset: 0x180)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Select Zone “FFSv2”" })

        controller.selectZone(item)

        let selection = controller.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x100..<0x200)
        XCTAssertEqual(StubToolA.log.selectedZones, ["fv"])
    }

    /// A zone map belongs to the pane its session was bound to, so a right
    /// click in the other pane is about somebody else's bytes.
    func testAZoneOfTheOtherPaneReachesNoModule() throws {
        let (controller, _) = try makeController()
        let host = try host(controller)
        host.publish(ZoneMap(zones: [Zone(id: "fv", name: "FFSv2", range: 0x100..<0x200)]))

        controller.tools.zoneSelected("fv", in: controller.windowModel.pane2)

        XCTAssertTrue(StubToolA.log.selectedZones.isEmpty)
    }
}

/// Following a tool-module's focus with the dump
/// (`Design/TOOL_MODULES_PLAN.md`).
@MainActor
final class ToolZoneFocusTests: XCTestCase {
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

    /// A file long enough that a zone can be well past the bottom of the window.
    private func makeHost() throws -> (any ToolHost, MainViewController, NSWindow) {
        let url = try tempFile([UInt8](repeating: 0xAA, count: 0x4000))
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1000, height: 500)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 500))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(StubToolA.identifier, animated: false)
        window.layoutIfNeeded()
        return (try XCTUnwrap(StubToolA.log.session).host, controller, window)
    }

    private func hexView(_ window: NSWindow) throws -> HexView {
        try XCTUnwrap(descendants(of: window.contentView!, HexView.self).first)
    }

    func testFocusingAZoneOffScreenBringsItsStartIntoView() throws {
        let (host, controller, window) = try makeHost()
        let hexView = try hexView(window)
        XCTAssertFalse(hexView.visibleByteRange().contains(0x3000), "precondition: far below")

        host.publish(ZoneMap(zones: [Zone(id: "far", name: "Far", range: 0x3000..<0x3010)],
                             focus: "far"))
        window.layoutIfNeeded()

        XCTAssertTrue(hexView.visibleByteRange().contains(0x3000),
                      "the zone's start is on screen")
        XCTAssertEqual(controller.windowModel.pane1.caretOffset, 0,
                       "looking is not going: the caret stays put")
        XCTAssertEqual(controller.windowModel.pane1.status.selectionLength, 0)
    }

    /// A scroll that moves the rows under a reader who can already see them is
    /// worse than no scroll at all.
    func testFocusingAZoneAlreadyOnScreenScrollsNothing() throws {
        let (host, _, window) = try makeHost()
        let hexView = try hexView(window)
        // Away from the file's start, so centring would visibly move the rows:
        // at the top the scroll is already clamped and a centre would be a
        // no-op for reasons that have nothing to do with the rule.
        hexView.scrollRowToTop(containing: 0x1000)
        window.layoutIfNeeded()
        let before = hexView.visibleByteRange()
        let nearTheBottom = before.upperBound - 0x20
        XCTAssertTrue(before.contains(nearTheBottom), "precondition: on screen, low down")

        host.publish(ZoneMap(zones: [Zone(id: "near", name: "Near",
                                          range: nearTheBottom..<(nearTheBottom + 0x10))],
                             focus: "near"))
        window.layoutIfNeeded()

        XCTAssertEqual(hexView.visibleByteRange(), before)
    }

    /// A republish that focuses the same zone is not a new place to be shown.
    func testRepublishingTheSameFocusDoesNotScrollAgain() throws {
        let (host, _, window) = try makeHost()
        let hexView = try hexView(window)
        host.publish(ZoneMap(zones: [Zone(id: "far", name: "Far", range: 0x3000..<0x3010)],
                             focus: "far"))
        window.layoutIfNeeded()
        let afterFirst = hexView.visibleByteRange()
        hexView.scrollRowToTop(containing: 0)
        window.layoutIfNeeded()
        let scrolledAway = hexView.visibleByteRange()

        host.publish(ZoneMap(zones: [Zone(id: "far", name: "Far", range: 0x3000..<0x3010)],
                             focus: "far"))
        window.layoutIfNeeded()

        XCTAssertNotEqual(scrolledAway, afterFirst, "precondition: the user scrolled away")
        XCTAssertEqual(hexView.visibleByteRange(), scrolledAway,
                       "the same focus republished leaves the scroll alone")
    }

    /// A map with nothing focused is not a place to go.
    func testAMapWithNoFocusScrollsNothing() throws {
        let (host, _, window) = try makeHost()
        let hexView = try hexView(window)
        let before = hexView.visibleByteRange()

        host.publish(ZoneMap(zones: [Zone(id: "far", name: "Far", range: 0x3000..<0x3010)]))
        window.layoutIfNeeded()

        XCTAssertEqual(hexView.visibleByteRange(), before)
    }
}
