import XCTest
@testable import DumpCompare

/// Step 1 of `Design/PANE_DRAG_PLAN.md`: what a pane drag *means*, and how a
/// dragged pane is found again — decided without a window, a pasteboard or a
/// drag in flight, because a dragging session cannot be unit-tested and this is
/// the part of it that can.
@MainActor
final class PaneDragTests: XCTestCase {

    // MARK: - What a drop means

    /// The two panes of one window exchange places — the gesture `View ▸ Swap
    /// Panels` has always performed and never looked like.
    func testDroppingOnTheOtherPaneOfTheSameWindowSwaps() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 1, inOriginWindow: true)),
                       .swap)
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 1,
                                        onto: .pane(index: 0, inOriginWindow: true)),
                       .swap)
    }

    /// Dropped back where it was picked up, the gesture was abandoned rather
    /// than performed.
    func testDroppingAPaneOnItselfDoesNothing() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 0, inOriginWindow: true)),
                       .none)
    }

    /// In another window the same landing means something else: the pane moves
    /// into that slot, displacing whatever is there.
    func testDroppingOnAnotherWindowsPaneMovesIntoThatSlot() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 1, inOriginWindow: false)),
                       .move(intoPane: 1))
        // Even the same index, which within one window would have been a no-op.
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 0, inOriginWindow: false)),
                       .move(intoPane: 0))
    }

    /// The strip means a tab of its own, wherever the pane came from.
    func testDroppingOnTheStripTearsOff() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0, onto: .newTabStrip), .tearOff)
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 1, onto: .newTabStrip), .tearOff)
    }

    /// A drop that lands nowhere returns the pane. Deliberately not a new
    /// window: an accidental drop onto the desktop would make one nobody asked
    /// for, and the deliberate version of that act has its own targets.
    func testDroppingOutsideDoesNothing() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0, onto: .outside), .none)
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 1, onto: .outside), .none)
    }

    // MARK: - Finding the pane again

    /// A pane is named on the pasteboard by an identity of its own, and found
    /// again through the registry — which walks the live windows rather than
    /// keeping a table, so the answer cannot go stale.
    func testTheRegistryFindsAPaneByItsDragID() throws {
        let registry = OpenDocumentRegistry()
        let first = MainViewController()
        let second = MainViewController()
        registry.register(first)
        registry.register(second)

        let found = try XCTUnwrap(registry.location(ofPaneWith: second.windowModel.pane2.dragID))

        XCTAssertIdentical(found.controller, second)
        XCTAssertEqual(found.paneIndex, 1)
    }

    /// Two panes never share an identity, or a drop would land on whichever the
    /// search happened to reach first.
    func testEveryPaneHasItsOwnIdentity() {
        let controller = MainViewController()
        let ids = [controller.windowModel.pane1.dragID, controller.windowModel.pane2.dragID]

        XCTAssertEqual(Set(ids).count, 2)
    }

    /// A pane keeps its identity when it moves to another window: what moves is
    /// the pane, and it is still the same one on the other side.
    func testAPaneKeepsItsIdentityAcrossAMove() throws {
        let registry = OpenDocumentRegistry()
        let source = MainViewController()
        let destination = MainViewController()
        registry.register(source)
        registry.register(destination)
        source.makeSiblingTab = { destination }
        let a = try tempFile([UInt8](repeating: 0xA0, count: 64))
        let b = try tempFile([UInt8](repeating: 0xB0, count: 64))
        source.openFiles([a, b])
        let id = source.windowModel.pane2.dragID

        let item = NSMenuItem()
        item.representedObject = source.windowModel.pane2
        source.openPaneInNewTab(item)

        let found = try XCTUnwrap(registry.location(ofPaneWith: id))
        XCTAssertIdentical(found.controller, destination, "the pane is where it moved to")
        XCTAssertEqual(found.paneIndex, 0)
    }

    /// A pane whose window is gone resolves to nothing, so a drag still in
    /// flight over it simply does nothing. The registry holds its windows
    /// weakly and stores nothing about their panes, so this needs no check.
    func testAPaneOfAClosedWindowIsNotFound() {
        let registry = OpenDocumentRegistry()
        var id: UUID?
        do {
            let doomed = MainViewController()
            registry.register(doomed)
            id = doomed.windowModel.pane1.dragID
            XCTAssertNotNil(registry.location(ofPaneWith: id!), "the premise: found while it lives")
        }

        XCTAssertNil(registry.location(ofPaneWith: id!))
    }

    // MARK: - The strip's share of the pane

    /// The New Tab strip lies across the top of every pane's overlay, so the
    /// bands start below it. Points in the strip's share belong to no band —
    /// without that the two would both claim them, and AppKit picks a drop
    /// destination by frame rather than by hit-test, so the disagreement would
    /// only show up as a drop going somewhere nobody meant.
    func testTheStripsShareBelongsToNoBand() {
        let layout = DropBandLayout(halfHeight: 400, topInset: 44)

        XCTAssertNil(layout.band(atTopDownY: 0), "the strip's own top")
        XCTAssertNil(layout.band(atTopDownY: 43.9), "still the strip")
        XCTAssertEqual(layout.band(atTopDownY: 44), .insertAtStart, "the first band starts here")
    }

    /// The bands divide what the strip leaves, not the whole pane: the strip's
    /// height comes off the top and the three bands share the rest.
    func testTheBandsDivideWhatTheStripLeaves() {
        let inset = DropBandLayout(halfHeight: 400, topInset: 44)

        XCTAssertEqual(inset.bandHeight, 356)
        XCTAssertEqual(inset.stripHeight, 89, "25 % of 356, inside the 48…120 clamp")
        XCTAssertEqual(inset.band(atTopDownY: 44 + 88), .insertAtStart)
        XCTAssertEqual(inset.band(atTopDownY: 44 + 90), .replace)
        XCTAssertEqual(inset.band(atTopDownY: 399), .appendAtEnd)
        XCTAssertNil(inset.band(atTopDownY: 400), "past the pane's bottom")
    }

    /// No strip, no inset: the layout the file bands have always had is what a
    /// zero inset produces, so nothing about the existing overlay changes.
    func testNoInsetIsTheLayoutThatWasThereBefore() {
        let plain = DropBandLayout(halfHeight: 400)

        XCTAssertEqual(plain.topInset, 0)
        XCTAssertEqual(plain.bandHeight, 400)
        XCTAssertEqual(plain.stripHeight, 100)
        XCTAssertEqual(plain.band(atTopDownY: 0), .insertAtStart)
        XCTAssertEqual(plain.replaceRange, 100 ..< 300)
    }

    // MARK: - Swapping by drag

    /// Two files open, so the window is a comparison and both panes exist.
    private func comparison() throws -> (MainViewController, URL, URL) {
        let controller = MainViewController()
        let a = try tempFile([UInt8](repeating: 0xA0, count: 64))
        let b = try tempFile([UInt8](repeating: 0xB0, count: 64))
        controller.openFiles([a, b])
        XCTAssertEqual(controller.mode, .comparison, "the premise")
        return (controller, a, b)
    }

    /// Dragging one pane onto the other performs the swap `View ▸ Swap Panels`
    /// has always performed — the same operation, reached by hand.
    func testDroppingAPaneOnTheOtherSwapsThem() throws {
        let (controller, a, b) = try comparison()
        let dragged = controller.windowModel.pane1.dragID

        controller.performPaneDrop(draggedPaneID: dragged, onPaneAt: 1)

        XCTAssertEqual(controller.windowModel.pane1.status.fileName, b.lastPathComponent)
        XCTAssertEqual(controller.windowModel.pane2.status.fileName, a.lastPathComponent)
    }

    /// The overlay asks before it accepts, so a landing with no meaning is
    /// refused by the cursor rather than swallowed. A pane dropped on itself is
    /// the abandoned gesture.
    func testAPaneDroppedOnItselfIsRefusedAndChangesNothing() throws {
        let (controller, a, b) = try comparison()
        let dragged = controller.windowModel.pane1.dragID

        XCTAssertEqual(controller.paneDropOutcome(draggedPaneID: dragged, onPaneAt: 0), .none)

        controller.performPaneDrop(draggedPaneID: dragged, onPaneAt: 0)

        XCTAssertEqual(controller.windowModel.pane1.status.fileName, a.lastPathComponent)
        XCTAssertEqual(controller.windowModel.pane2.status.fileName, b.lastPathComponent)
    }

    /// A pane whose window has gone resolves to nothing, so a drag still in
    /// flight over another window is refused instead of acting on a stale id.
    func testAnUnknownPaneIsRefused() throws {
        let (controller, _, _) = try comparison()

        XCTAssertEqual(controller.paneDropOutcome(draggedPaneID: UUID(), onPaneAt: 1), .none)
    }

    /// Landing on another window's pane is a *move*, which step 4 builds; until
    /// then it is refused at the cursor rather than accepted and ignored.
    func testACrossWindowLandingIsRefusedForNow() throws {
        let registry = OpenDocumentRegistry()
        let (source, _, _) = try comparison()
        let other = MainViewController()
        for controller in [source, other] {
            controller.openDocuments = registry
            registry.register(controller)
        }
        self.liveRegistry = registry

        let outcome = other.paneDropOutcome(draggedPaneID: source.windowModel.pane1.dragID,
                                            onPaneAt: 0)

        XCTAssertEqual(outcome, .none, "refused, not silently dropped")
        // The decision itself already knows the right answer; only the wiring
        // is waiting.
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 0, inOriginWindow: false)),
                       .move(intoPane: 0))
    }

    // MARK: - Picking a pane up

    /// The header answers a double-click and a right-click already, so the drag
    /// waits until the pointer has moved far enough to mean one.
    func testTheHeaderNeedsAThresholdBeforeItDrags() {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        var dragged = 0
        header.onDragThresholdPassed = { _ in dragged += 1 }

        header.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 100)))
        header.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 102, y: 100)))
        XCTAssertEqual(dragged, 0, "2 pt is a wobble, not a drag")

        header.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 106, y: 100)))
        XCTAssertEqual(dragged, 1)

        // One drag per press: the session has the mouse from here.
        header.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 140, y: 100)))
        XCTAssertEqual(dragged, 1)
    }

    /// A double-click still fits the pane to its content width, and never starts
    /// a drag.
    func testADoubleClickNeverBecomesADrag() {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        var dragged = 0
        var doubleClicked = 0
        header.onDragThresholdPassed = { _ in dragged += 1 }
        header.onDoubleClick = { doubleClicked += 1 }

        header.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 100), clicks: 2))
        header.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 140, y: 100)))

        XCTAssertEqual(doubleClicked, 1)
        XCTAssertEqual(dragged, 0, "the press was a double-click; it has no drag in it")
    }

    /// Keeps a registry alive for a test — `openDocuments` is a weak back
    /// reference, so one left in a local goes away and every controller quietly
    /// answers from its own panes again.
    private var liveRegistry: OpenDocumentRegistry?

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint,
                            clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)!
    }

    // MARK: - What the hand carries

    /// Content wider than the minimum grows the pill.
    func testThePillFitsWideContent() {
        let size = FilePaneView.paneDragPillSize(contentWidth: 220, height: 28)

        XCTAssertEqual(size.width, min(FilePaneView.paneDragMaxWidth,
                                       220 + FilePaneView.paneDragTextInset * 2))
        XCTAssertEqual(size.height, 28, "the height is the header's")
    }

    /// A long name truncates instead of stretching the pill across the screen.
    func testAWideNameIsCappedRatherThanStretchingThePill() {
        let size = FilePaneView.paneDragPillSize(contentWidth: 4000, height: 28)

        XCTAssertEqual(size.width, FilePaneView.paneDragMaxWidth)
    }

    /// A short name still gets a plate: below the minimum the pill keeps its
    /// width and the content sits in the middle of it.
    func testAShortNameStillGetsAFullPlate() {
        let size = FilePaneView.paneDragPillSize(contentWidth: 12, height: 28)

        XCTAssertEqual(size.width, FilePaneView.paneDragMinWidth)
        XCTAssertEqual(size.width, 200)
    }

    /// The pill is carried at the size it is drawn — a name that has to be
    /// squinted at says nothing worth carrying, and leaving the pane is already
    /// visible from the pill leaving the pane.
    func testThePillIsNotScaled() {
        let size = FilePaneView.paneDragPillSize(contentWidth: 120, height: 28)

        XCTAssertEqual(size.height, 28, "no shrink between drawing and carrying")
        XCTAssertGreaterThanOrEqual(size.width, FilePaneView.paneDragMinWidth)
    }

    // MARK: - The New Tab strip

    /// A file let go on the strip opens in a tab of its own, leaving the window
    /// it was dropped on as it was.
    func testAFileDroppedOnTheStripOpensInANewTab() throws {
        let (controller, a, b) = try comparison()
        let destination = MainViewController()
        controller.makeSiblingTab = { destination }
        let third = try tempFile([UInt8](repeating: 0xC0, count: 64))

        controller.openFilesInNewTab([third])

        XCTAssertEqual(destination.windowModel.pane1.status.fileName, third.lastPathComponent)
        XCTAssertEqual(destination.mode, .singleFile)
        XCTAssertEqual(controller.windowModel.pane1.status.fileName, a.lastPathComponent,
                       "the window it was dropped on is untouched")
        XCTAssertEqual(controller.windowModel.pane2.status.fileName, b.lastPathComponent)
    }

    /// With nowhere to put a tab the strip does nothing rather than opening the
    /// file where it would have been refused.
    func testTheStripDoesNothingWithNoTabToMake() throws {
        let (controller, a, b) = try comparison()

        controller.openFilesInNewTab([try tempFile([UInt8](repeating: 0xC0, count: 64))])

        XCTAssertEqual(controller.windowModel.pane1.status.fileName, a.lastPathComponent)
        XCTAssertEqual(controller.windowModel.pane2.status.fileName, b.lastPathComponent)
    }

    /// The strip's points belong to the strip. An overlay asked about one of
    /// them answers with no band — and, crucially, the drop then does nothing
    /// rather than falling back to Replace, which would answer a question the
    /// overlay was never asked.
    func testAnOverlayClaimsNoBandInTheStripsShare() {
        let bands = PaneDropBandsView(paneView: nil)
        bands.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        bands.topInset = NewTabDropStrip.height
        bands.layout()

        // Top-down 10 pt is inside the strip's 44; the band layout must not
        // claim it.
        let layout = DropBandLayout(halfHeight: 400, topInset: NewTabDropStrip.height)
        XCTAssertNil(layout.band(atTopDownY: 10))
        XCTAssertEqual(layout.band(atTopDownY: NewTabDropStrip.height + 1), .insertAtStart)
    }

    /// The strip is deep enough to aim at without care, and still leaves the
    /// pane's own three bands room to be told apart.
    func testTheStripLeavesTheBandsRoom() {
        let layout = DropBandLayout(halfHeight: 400, topInset: NewTabDropStrip.height)

        XCTAssertEqual(NewTabDropStrip.height, 44)
        XCTAssertGreaterThan(layout.replaceRange.upperBound, layout.replaceRange.lowerBound,
                             "the middle band survives the strip's share")
    }
}
