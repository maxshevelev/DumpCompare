import XCTest
import ToolModuleKit
@testable import ByteRipper

/// § The zone gutter (§19.4.5): the brackets a tool-module's published zones
/// get left of each map, in the dump's own zone colours — what they are shaped
/// like, what they cost the map's width, and what hovering, clicking and
/// right-clicking one does (`Design/TOOL_MODULES_PLAN.md`,
/// `Design/ZONES_IDEA.md`).
@MainActor
final class MinimapZoneTests: XCTestCase {
    private var files: [URL] = []
    private var controller: MainViewController?
    private var isolatedSuiteName = ""
    private var isolatedStore: UserDefaults!

    override func setUp() {
        super.setUp()
        installToolStubs()
        (isolatedSuiteName, isolatedStore) = isolatedDefaults(for: self)
        ToolController.defaults = isolatedStore
        ToolController.changeDelay = 0
        MainViewController.minimapDefaults = isolatedStore
        // AppKit saves a window's frame into `UserDefaults.standard` itself,
        // so this one key is not the app's to redirect — clearing it in the
        // test suite would leave the real saved frame to be restored.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame MainWindow")
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        discardIsolatedDefaults(isolatedSuiteName, isolatedStore)
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        MainViewController.minimapDefaults = .standard
        isolatedStore = nil
        controller = nil
        files = []
        super.tearDown()
    }

    // MARK: - A window with a tool-module running

    /// One file open in single-file mode, the minimap shown and pinned to
    /// detail, and a stub tool-module running on the pane — everything needed
    /// to publish a map and look at what the gutter does with it.
    private func makeWindow(size: Int = 0x400)
        throws -> (MainViewController, NSWindow, MinimapView, any ToolHost) {
        let url = try tempFile([UInt8](repeating: 0xAA, count: size))
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 800, height: 600))
        window.contentView?.heightAnchor
            .constraint(greaterThanOrEqualToConstant: 600).isActive = true
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        let panel = try XCTUnwrap(descendants(of: window.contentView!, MinimapView.self).first,
                                  "the minimap panel")
        controller.setMinimapPanelVisible(true, animated: false)
        window.layoutIfNeeded()
        // These tests aim at exact rows, so the detail window's mapping is the
        // one they want — the same pin the rest of the minimap's tests use.
        controller.setMinimapRenderModeForTesting(.detail)
        window.layoutIfNeeded()
        controller.tools.activate(StubToolA.identifier, animated: false)
        let host = try XCTUnwrap(StubToolA.log.session, "the stub's session").host
        return (controller, window, panel, host)
    }

    /// Publishes `map` and lets the panel take it: the publish is synchronous,
    /// the repaint is not.
    private func publish(_ map: ZoneMap, to host: any ToolHost,
                         _ window: NSWindow) {
        host.publish(map)
        window.layoutIfNeeded()
    }

    private func zone(_ id: String, _ name: String, _ range: Range<UInt64>) -> Zone {
        Zone(id: id, name: name, range: range)
    }

    /// The y an offset sits at on a map, by the detail window's own mapping —
    /// so a test can aim at a zone's exact start or end.
    private func mapY(_ offset: UInt64, in panel: MinimapView) -> CGFloat {
        CGFloat(Double(offset) / Double(MinimapView.bytesPerRow) - Double(panel.topRow))
            * MinimapView.rowStep
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func colour(_ rep: NSBitmapImageRep, at point: NSPoint,
                        of view: NSView) throws -> NSColor {
        let scaleX = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        let scaleY = CGFloat(rep.pixelsHigh) / max(view.bounds.height, 1)
        let x = min(max(Int(point.x * scaleX), 0), rep.pixelsWide - 1)
        let y = min(max(Int(point.y * scaleY), 0), rep.pixelsHigh - 1)
        return try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                             "a pixel at \(point)")
    }

    /// How far a colour is from another, summed over the three channels — what
    /// "louder" means for a translucent stroke over paper, without guessing
    /// what the blend comes to.
    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    // MARK: - Lanes

    /// Nesting decides the lane: an outermost zone gets lane 0 and each level
    /// inside it steps one lane toward the map, so the gutter reads as the tree
    /// it stands for. Past `zoneMaxLanes` the deeper zones share the innermost
    /// lane rather than eating the map's width without end.
    func testNestingDecidesTheLane() {
        let map = ZoneMap(zones: [
            zone("volume", "Volume", 0..<0x400),
            zone("file", "File", 0x100..<0x300),
            zone("section", "Section", 0x140..<0x200),
            zone("deeper", "Deeper", 0x150..<0x180),
            zone("sibling", "Second file", 0x300..<0x400),
        ]).normalized(contentSize: 0x400)
        let lanes = MinimapView.brackets(for: map)
            .reduce(into: [String: Int]()) { $0[$1.id] = $1.lane }

        XCTAssertEqual(lanes["volume"], 0, "the outermost zone is furthest from the map")
        XCTAssertEqual(lanes["file"], 1, "a zone inside it steps one lane in")
        XCTAssertEqual(lanes["section"], 2, "and one more for the next level")
        XCTAssertEqual(lanes["deeper"], MinimapView.zoneMaxLanes - 1,
                       "past the cap the deeper zones share the innermost lane")
        XCTAssertEqual(lanes["sibling"], 1,
                       "a second child of the volume is back in the volume's own inner "
                       + "lane: the stack closes down to the zone that actually contains it, "
                       + "however deep the one before it went")
    }

    /// Two zones that merely overlap — which no parser produces and the model
    /// does not forbid — are not nested, so neither is drawn inside the other.
    func testOverlappingZonesShareALane() {
        let map = ZoneMap(zones: [
            zone("a", "A", 0x000..<0x200),
            zone("b", "B", 0x100..<0x300),
        ]).normalized(contentSize: 0x400)
        XCTAssertEqual(MinimapView.brackets(for: map).map(\.lane), [0, 0],
                       "an overlap is not a nesting, so both stay outermost")
    }

    /// The focus is the published map's, and only one bracket carries it.
    func testTheFocusedBracketIsTheFocusedZone() {
        let map = ZoneMap(zones: [zone("a", "A", 0..<0x100), zone("b", "B", 0x100..<0x200)],
                          focus: "b").normalized(contentSize: 0x400)
        let brackets = MinimapView.brackets(for: map)
        XCTAssertEqual(brackets.filter(\.isFocused).map(\.id), ["b"],
                       "exactly the focused zone is drawn as focused")
    }

    // MARK: - Layout

    /// No tool-module has anything to say about most files, so the gutter is
    /// absent and the map loses no width to it. It appears with the first
    /// published zone and goes when the map does.
    func testTheGutterIsAbsentWithoutZonesAndAppearsWithOne() throws {
        let (_, window, panel, host) = try makeWindow()
        XCTAssertFalse(panel.zoneGutterVisible(forMapAt: 0),
                       "nothing published, so no gutter")
        XCTAssertNil(panel.zoneGutterRect(forMapAt: 0), "and no gutter to hit-test")
        let bare = panel.contentAreaForTesting(forMapAt: 0)

        publish(ZoneMap(zones: [zone("bios", "BIOS", 0x100..<0x300)]), to: host, window)
        XCTAssertTrue(panel.zoneGutterVisible(forMapAt: 0), "a published zone brings the gutter")
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        XCTAssertEqual(gutter.width, MinimapView.zoneBracketArm,
                       "one level of nesting is one stem and its arm wide")
        XCTAssertEqual(gutter.height, panel.bounds.height, "it runs the map's full height")
        let withZones = panel.contentAreaForTesting(forMapAt: 0)
        XCTAssertEqual(withZones.minX - bare.minX,
                       MinimapView.zoneBracketArm + MinimapView.zoneGutterGap,
                       "the content retreats by exactly the gutter and its gap")

        publish(.empty, to: host, window)
        XCTAssertFalse(panel.zoneGutterVisible(forMapAt: 0), "an empty map takes the gutter away")
        XCTAssertEqual(panel.contentAreaForTesting(forMapAt: 0).minX, bare.minX,
                       "and gives the width back")
    }

    /// The gutter sits between the panel's left inset and the map, with its own
    /// gap of paper — the segment strip's layout mirrored, so the panel reads as
    /// gutter – gap – map – gap – strip (§19.4.4).
    func testTheGutterSitsLeftOfTheMapWithItsGapOfPaper() throws {
        let (_, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("bios", "BIOS", 0..<0x400)]), to: host, window)
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        let content = panel.contentAreaForTesting(forMapAt: 0)
        XCTAssertEqual(gutter.minX, panel.bounds.minX + MinimapView.contentPadding,
                       "the gutter starts at the panel's own left inset")
        XCTAssertEqual(content.minX - gutter.maxX, MinimapView.zoneGutterGap,
                       "and keeps its gap of paper off the dump it names")
    }

    /// Nesting widens the gutter a lane at a time, and never past the cap.
    func testTheGutterWidensWithTheNestingAndStopsAtTheCap() throws {
        let (_, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("a", "A", 0..<0x400), zone("b", "B", 0x100..<0x200)]),
                to: host, window)
        XCTAssertEqual(panel.zoneGutterLaneCount(forMapAt: 0), 2, "two levels, two lanes")

        publish(ZoneMap(zones: [
            zone("a", "A", 0..<0x400),
            zone("b", "B", 0x100..<0x300),
            zone("c", "C", 0x140..<0x200),
            zone("d", "D", 0x150..<0x180),
            zone("e", "E", 0x160..<0x170),
        ]), to: host, window)
        XCTAssertEqual(panel.zoneGutterLaneCount(forMapAt: 0), MinimapView.zoneMaxLanes,
                       "five levels of nesting still cost only the capped three lanes")
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        XCTAssertEqual(gutter.width,
                       CGFloat(MinimapView.zoneMaxLanes - 1) * MinimapView.zoneLaneStep
                           + MinimapView.zoneBracketArm,
                       "which is two indents and the innermost lane's arm")
    }

    /// The bookmark marks and the brackets share the left margin, and neither is
    /// drawn over the other: the gutter's lanes are not paper a mark may point
    /// across, so the mark's apex stops at the gutter's outer edge (§19.4.3).
    func testBookmarkMarksKeepClearOfTheGutter() throws {
        let (controller, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("bios", "BIOS", 0..<0x400)]), to: host, window)
        _ = controller.windowModel.bookmarkStore.add(rowContaining: 0x100)
        window.layoutIfNeeded()
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        let mark = try XCTUnwrap(panel.bookmarkMarkRect(row: 0x100, forMapAt: 0),
                                 "the bookmarked row is in the detail window")
        XCTAssertFalse(mark.intersects(gutter),
                       "the mark keeps out of the gutter's lanes: \(mark) vs \(gutter)")
        XCTAssertLessThanOrEqual(mark.maxX, gutter.minX,
                                 "which puts it outside the gutter, not past it")
    }

    // MARK: - What a bracket looks like

    /// The brackets are painted in the dump's own zone colours — the focused
    /// one in `HexTheme.zoneFrame` teal and every other in the fixed yellow of
    /// `HexTheme.zoneFrameInactive`, at the same strength and width, because a
    /// zone on the map and the same zone in the dump are one statement about
    /// the file and must not be told apart by their looks (§19.4.5).
    func testTheBracketsWearTheDumpsZoneColours() throws {
        let (_, window, panel, host) = try makeWindow()
        // Two siblings, so both brackets are in lane 0 and their stems share an
        // x — what differs between the two samples is only the focus.
        publish(ZoneMap(zones: [zone("plain", "Plain", 0x000..<0x180),
                                zone("focused", "Focused", 0x200..<0x380)],
                        focus: "focused"),
                to: host, window)
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        let rep = try render(panel)

        let stemX = gutter.minX + 0.5
        let plain = try colour(rep, at: NSPoint(x: stemX, y: mapY(0x100, in: panel)), of: panel)
        let focused = try colour(rep, at: NSPoint(x: stemX, y: mapY(0x300, in: panel)), of: panel)
        let paper = try colour(rep, at: NSPoint(x: gutter.midX, y: mapY(0x1C0, in: panel)),
                               of: panel)

        XCTAssertGreaterThan(distance(plain, paper), 0.05,
                             "an unfocused bracket is still a line: \(plain) vs \(paper)")
        XCTAssertGreaterThan(distance(plain, focused), 0.3,
                             "and the two are told apart by hue, not strength: "
                             + "\(plain) vs \(focused)")

        // Each hue is the dump's own: the focused bracket moves away from the
        // paper toward `HexTheme.zoneFrame`, and an unfocused one toward
        // `HexTheme.zoneFrameInactive`, channel by channel. Asserting the blend
        // itself would be asserting how AppKit composites a translucent stroke.
        for (sample, target, who) in [(focused, HexTheme.zoneFrame, "the focused bracket"),
                                      (plain, HexTheme.zoneFrameInactive,
                                       "an unfocused bracket")] {
            let targetRGB = try XCTUnwrap(target.usingColorSpace(.deviceRGB))
            for (name, channel) in [("red", \NSColor.redComponent),
                                    ("green", \NSColor.greenComponent),
                                    ("blue", \NSColor.blueComponent)]
                as [(String, KeyPath<NSColor, CGFloat>)] {
                let toTarget = targetRGB[keyPath: channel] - paper[keyPath: channel]
                guard abs(toTarget) > 0.1 else { continue }
                let moved = sample[keyPath: channel] - paper[keyPath: channel]
                XCTAssertEqual(moved > 0, toTarget > 0,
                               "\(who)'s \(name) moves toward the dump's zone colour")
            }
        }
    }

    /// A zone larger than the detail window keeps its stem and loses the arm at
    /// the end that is off the map: an arm at the window's edge would say the
    /// zone stops there, which is the one thing it must not say.
    func testAClippedEndLosesItsArm() throws {
        // 64 KB is far taller than the panel, so a zone over the whole file has
        // its start on the map (the pane opens at the top) and its end below it.
        let (_, window, panel, host) = try makeWindow(size: 0x10000)
        publish(ZoneMap(zones: [zone("all", "All", 0..<0x10000)]), to: host, window)
        let bracket = try XCTUnwrap(panel.zoneBrackets.first?.first)
        let bounds = try XCTUnwrap(panel.zoneBracketBounds(bracket, forMapAt: 0))
        XCTAssertTrue(bounds.hasStart, "the file's first row is on the map, so its arm is drawn")
        XCTAssertFalse(bounds.hasEnd, "its end is far below the window, so that arm is not")
        XCTAssertEqual(bounds.bottom, panel.bounds.maxY,
                       "and the stem runs to the map's edge rather than stopping short")
    }

    /// A zone of a few bytes on a map where a row is kilobytes is thinner than a
    /// pixel; the bracket is grown around its own middle so the zone can be seen
    /// and hit at all (§19.6 makes the same trade for the viewport band).
    func testATinyZoneIsGrownToItsFloor() throws {
        let (_, window, panel, host) = try makeWindow(size: 0x10000)
        publish(ZoneMap(zones: [zone("fit", "FIT", 0x8000..<0x8010)]), to: host, window)
        let bracket = try XCTUnwrap(panel.zoneBrackets.first?.first)
        // Overview bins the whole file into the panel's height, which is where a
        // sixteen-byte zone really does land inside one pixel row.
        panel.setRenderMode(.overview)
        window.layoutIfNeeded()
        let bounds = try XCTUnwrap(panel.zoneBracketBounds(bracket, forMapAt: 0))
        XCTAssertEqual(bounds.bottom - bounds.top, MinimapView.zoneBracketMinHeight,
                       "a bracket is never drawn thinner than its floor")
    }

    // MARK: - Hover

    /// Hovering a bracket names its zone: the name, the range and the size — the
    /// shape the segment strip's own hover text takes (§19.4.4).
    func testHoveringABracketNamesTheZone() throws {
        let (_, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("bios", "BIOS region", 0x100..<0x300)]), to: host, window)
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        let text = panel.zoneBracketTooltipText(
            at: NSPoint(x: gutter.minX, y: mapY(0x200, in: panel)))
        XCTAssertTrue(text.contains("BIOS region"), "the hover names the zone: \(text)")
        XCTAssertTrue(text.contains("0x100"), "and gives its start: \(text)")
        XCTAssertTrue(text.contains("0x2FF"), "and its last byte, not the bound: \(text)")
        XCTAssertTrue(text.contains("512"), "and its size: \(text)")

        let offBracket = panel.zoneBracketTooltipText(
            at: NSPoint(x: gutter.minX, y: mapY(0x380, in: panel)))
        XCTAssertEqual(offBracket, "", "and says nothing off every bracket")
    }

    /// An unnamed zone is named by its range alone — a stretch worth drawing is
    /// worth naming even before it has a name (`Zone.name`).
    func testAnUnnamedZoneIsNamedByItsRange() throws {
        let (_, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("x", "", 0x100..<0x180)]), to: host, window)
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        let text = panel.zoneBracketTooltipText(
            at: NSPoint(x: gutter.minX, y: mapY(0x140, in: panel)))
        XCTAssertTrue(text.hasPrefix("0x100"), "the range is all there is to say: \(text)")
        XCTAssertFalse(text.contains("—"), "and there is no empty name in front of it: \(text)")
    }

    /// The innermost zone under the pointer wins where several share a lane:
    /// the smallest one is what is being aimed at, the rule the dump's own zone
    /// menu follows.
    func testTheInnermostZoneUnderThePointerWins() throws {
        let (_, window, panel, host) = try makeWindow()
        // Five levels, so the two deepest share the capped innermost lane.
        publish(ZoneMap(zones: [
            zone("a", "A", 0x000..<0x400),
            zone("b", "B", 0x000..<0x380),
            zone("c", "C", 0x100..<0x300),
            zone("d", "D", 0x140..<0x200),
        ]), to: host, window)
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        let innermostLaneX = gutter.minX + CGFloat(MinimapView.zoneMaxLanes - 1)
            * MinimapView.zoneLaneStep
        let text = panel.zoneBracketTooltipText(
            at: NSPoint(x: innermostLaneX, y: mapY(0x180, in: panel)))
        XCTAssertTrue(text.hasPrefix("D"),
                      "the smallest zone sharing the lane is the one named: \(text)")
    }

    /// Each lane owns the column around its own stem, so pointing at a parent's
    /// stem names the parent even where a child's bracket runs alongside it —
    /// which is the whole reason the brackets are indented (§19.4.5).
    func testEachLaneNamesItsOwnZone() throws {
        let (_, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("outer", "Outer", 0x000..<0x400),
                                zone("inner", "Inner", 0x100..<0x300)]),
                to: host, window)
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        // A height both brackets cover, so only the x can tell them apart.
        let y = mapY(0x200, in: panel)

        let outer = panel.zoneBracketTooltipText(at: NSPoint(x: gutter.minX, y: y))
        XCTAssertTrue(outer.hasPrefix("Outer"), "lane 0's column names the parent: \(outer)")
        let inner = panel.zoneBracketTooltipText(
            at: NSPoint(x: gutter.minX + MinimapView.zoneLaneStep, y: y))
        XCTAssertTrue(inner.hasPrefix("Inner"), "lane 1's names the child: \(inner)")
    }

    /// A lane with no bracket at that height falls back to whatever bracket is
    /// beside the pointer: the gutter is mostly paper and a zone map is sparse,
    /// so a column that answers nothing where a bracket is plainly there would
    /// read as broken.
    func testAnEmptyLaneFallsBackToTheBracketBesideIt() throws {
        let (_, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("outer", "Outer", 0x000..<0x400),
                                zone("inner", "Inner", 0x040..<0x080)]),
                to: host, window)
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        // 0x200 is inside Outer and far below Inner, so lane 1's column is
        // empty there.
        let text = panel.zoneBracketTooltipText(
            at: NSPoint(x: gutter.minX + MinimapView.zoneLaneStep, y: mapY(0x200, in: panel)))
        XCTAssertTrue(text.hasPrefix("Outer"),
                      "the only bracket at that height answers: \(text)")
    }

    /// Hovering paints the bracket louder and repaints nothing but the gutter:
    /// a hover is not a file change, so the maps must not be redrawn for one
    /// (§19.9).
    func testHoveringABracketRepaintsOnlyTheGutter() throws {
        let (_, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("bios", "BIOS", 0x100..<0x300)]), to: host, window)
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        let before = try render(panel)

        let point = NSPoint(x: gutter.minX, y: mapY(0x200, in: panel))
        panel.mouseMoved(with: mouse(.mouseMoved, at: panel.convert(point, to: nil),
                                     window: window))
        let asked = try XCTUnwrap(panel.lastRepaintRequest,
                                  "a hover asks for rectangles, not the whole panel")
        XCTAssertTrue(asked.allSatisfy { gutter.insetBy(dx: -2, dy: -2).contains($0) },
                      "and only the gutter's own: \(asked)")

        window.layoutIfNeeded()
        panel.displayIfNeeded()
        let after = try render(panel)
        let stem = NSPoint(x: gutter.minX + 0.5, y: mapY(0x200, in: panel))
        XCTAssertGreaterThan(distance(try colour(after, at: stem, of: panel),
                                      try colour(before, at: stem, of: panel)),
                             0.02,
                             "the hovered bracket is painted louder")
    }

    // MARK: - Click

    /// A click on a zone's start or its end goes to that exact offset — the two
    /// facts a bracket states — the way a click near a cut goes to the cut
    /// (§19.4.4) and one near a bookmark's mark to its row (§19.6.1).
    func testAClickOnAZonesEndsSnapsToThem() throws {
        let (_, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("bios", "BIOS", 0x100..<0x300)]), to: host, window)
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))

        let start = try XCTUnwrap(panel.zoneBracketClick(
            at: NSPoint(x: gutter.minX, y: mapY(0x100, in: panel))))
        XCTAssertEqual(start.mapIndex, 0)
        XCTAssertEqual(start.offset, 0x100, "the start of the zone")

        let end = try XCTUnwrap(panel.zoneBracketClick(
            at: NSPoint(x: gutter.minX, y: mapY(0x300, in: panel))))
        XCTAssertEqual(end.offset, 0x2FF,
                       "and the end is the zone's last byte, not the byte after it")

        XCTAssertNil(panel.zoneBracketClick(
            at: NSPoint(x: gutter.minX, y: mapY(0x200, in: panel))),
            "the middle of a bracket is not an end, so the panel's own click meaning stands")
        XCTAssertNil(panel.zoneBracketClick(
            at: NSPoint(x: gutter.minX, y: mapY(0x380, in: panel))),
            "and neither is a point off every bracket")
    }

    /// A click on a bracket's end reaches the gutter — ahead of the viewport
    /// band, which runs edge to edge and would otherwise swallow it as a drag —
    /// and asks for that end. It moves the pane and nothing else: the minimap
    /// navigates, and where the caret was left is not its to change (§19).
    func testAClickOnABracketNavigatesWithoutTouchingTheCaret() throws {
        let (controller, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("bios", "BIOS", 0x100..<0x300)]), to: host, window)
        let pane = controller.windowModel.pane1
        pane.select(range: 0..<0x10)
        let caret = pane.hexSelection()

        // The controller's own handler, wrapped: what the click asks for is the
        // fact under test, and the pane still gets the navigation it would.
        var asked: [(mapIndex: Int, offset: UInt64)] = []
        let handler = panel.onSelectOffset
        panel.onSelectOffset = { mapIndex, offset in
            asked.append((mapIndex, offset))
            handler?(mapIndex, offset)
        }
        defer { panel.onSelectOffset = handler }

        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        let point = NSPoint(x: gutter.minX, y: mapY(0x100, in: panel))
        panel.mouseDown(with: mouse(.leftMouseDown, at: panel.convert(point, to: nil),
                                    window: window))
        window.layoutIfNeeded()
        XCTAssertEqual(asked.map(\.offset), [0x100],
                       "the click on the zone's start asked for the zone's start")
        let after = pane.hexSelection()
        XCTAssertEqual(after.start..<after.end, caret.start..<caret.end,
                       "the click navigated; it did not move the selection")
    }

    // MARK: - The menu

    /// A right-click on a bracket offers what acts on that zone. One item for
    /// Select — which names the zone, selects its whole range, and tells the
    /// tool-module that published it, because what the zone stands for is only
    /// the tool-module's to know (§19.4.5). What the menu offers beside it is
    /// `ToolZonesTests`' to say; this is about what Select does.
    func testTheMenuSelectsTheZoneAndTellsTheToolModule() throws {
        let (controller, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("bios", "BIOS region", 0x100..<0x300)]), to: host, window)
        let gutter = try XCTUnwrap(panel.zoneGutterRect(forMapAt: 0))
        let point = NSPoint(x: gutter.minX, y: mapY(0x200, in: panel))
        let bracket = try XCTUnwrap(panel.zoneBracket(at: point, onMapAt: 0),
                                    "the pointer is on the bracket")
        XCTAssertEqual(panel.zoneBrackets[0][bracket].id, "bios")

        let menu = try XCTUnwrap(panel.zoneBracketMenu?(0, "bios"),
                                 "a bracket offers a menu")
        let item = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Select Zone") })
        XCTAssertTrue(item.title.contains("BIOS region"),
                      "the item names the zone it will act on: \(item.title)")

        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        let selection = controller.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0x100..<0x300,
                       "Select selects the zone's whole range")
        XCTAssertEqual(StubToolA.log.selectedZones, ["bios"],
                       "and the tool-module that published it is told")
    }

    /// An unnamed zone's item names where it starts, which is all there is to
    /// name it by.
    func testTheMenuNamesAnUnnamedZoneByItsStart() throws {
        let (_, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("x", "", 0x100..<0x180)]), to: host, window)
        let menu = try XCTUnwrap(panel.zoneBracketMenu?(0, "x"))
        XCTAssertTrue(menu.items[0].title.contains("100"),
                      "the item names the zone by its start: \(menu.items[0].title)")
    }

    /// A zone the tool-module has withdrawn since the menu opened is not acted
    /// on: the item carries the zone's id, and the id is looked up again when it
    /// is picked.
    func testTheMenuActsOnNothingOnceTheZoneIsGone() throws {
        let (controller, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("bios", "BIOS", 0x100..<0x300)]), to: host, window)
        let menu = try XCTUnwrap(panel.zoneBracketMenu?(0, "bios"))
        let item = menu.items[0]

        publish(.empty, to: host, window)
        controller.windowModel.pane1.select(range: 0..<0x10)
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        let selection = controller.windowModel.pane1.hexSelection()
        XCTAssertEqual(selection.start..<selection.end, 0..<0x10,
                       "the zone is gone, so the item does nothing")
        XCTAssertEqual(StubToolA.log.selectedZones, [],
                       "and the tool-module hears nothing about it")
    }

    // MARK: - The gutter's lifetime

    /// The gutter goes with the session that authored it: nothing else draws
    /// zones, so a map left behind would be a tool-module's reading of a file
    /// after that tool-module has gone (`ToolController.endSession`).
    func testTheGutterGoesWithTheSession() throws {
        let (controller, window, panel, host) = try makeWindow()
        publish(ZoneMap(zones: [zone("bios", "BIOS", 0x100..<0x300)]), to: host, window)
        XCTAssertTrue(panel.zoneGutterVisible(forMapAt: 0))

        controller.tools.activate(nil, animated: false)
        window.layoutIfNeeded()
        XCTAssertFalse(panel.zoneGutterVisible(forMapAt: 0),
                       "the session ended, so the brackets went with it")
        XCTAssertEqual(panel.zoneBrackets.flatMap { $0 }.count, 0)
    }
}
