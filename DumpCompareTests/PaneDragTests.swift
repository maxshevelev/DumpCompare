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
                                        onto: .pane(index: 1, inOriginWindow: true, band: .replace)),
                       .swap)
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 1,
                                        onto: .pane(index: 0, inOriginWindow: true, band: .replace)),
                       .swap)
    }

    /// Dropped back where it was picked up, the gesture was abandoned rather
    /// than performed.
    func testDroppingAPaneOnItselfDoesNothing() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 0, inOriginWindow: true, band: .replace)),
                       .none)
    }

    /// In another window the same landing means something else: the pane moves
    /// into that slot, displacing whatever is there.
    func testDroppingOnAnotherWindowsPaneMovesIntoThatSlot() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 1, inOriginWindow: false, band: .replace)),
                       .move(intoPane: 1))
        // Even the same index, which within one window would have been a no-op.
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 0, inOriginWindow: false, band: .replace)),
                       .move(intoPane: 0))
    }

    /// The strip means a tab of its own, wherever the pane came from.
    func testDroppingOnTheStripTearsOff() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0, onto: .newTabStrip), .tearOff(copying: false))
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 1, onto: .newTabStrip), .tearOff(copying: false))
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

    /// Two windows sharing a registry, the first a comparison and the second
    /// empty.
    private func twoWindows() throws -> (source: MainViewController,
                                         other: MainViewController,
                                         a: URL, b: URL) {
        let registry = OpenDocumentRegistry()
        let (source, a, b) = try comparison()
        let other = MainViewController()
        for controller in [source, other] {
            controller.openDocuments = registry
            registry.register(controller)
        }
        liveRegistry = registry
        return (source, other, a, b)
    }

    /// Landing on another window's pane moves the pane into that slot — the
    /// operation the plan's decision named all along, now wired.
    func testDroppingOnAnotherWindowsPaneMovesThePaneThere() throws {
        let (source, other, a, b) = try twoWindows()
        let moved = source.windowModel.pane1

        XCTAssertEqual(other.paneDropOutcome(draggedPaneID: moved.dragID, onPaneAt: 0),
                       .move(intoPane: 0))
        other.performPaneDrop(draggedPaneID: moved.dragID, onPaneAt: 0)

        XCTAssertIdentical(other.windowModel.pane1, moved,
                           "the pane itself crossed, not a second document over one file")
        XCTAssertEqual(other.windowModel.pane1.status.fileName, a.lastPathComponent)
        XCTAssertEqual(source.windowModel.pane1.status.fileName, b.lastPathComponent,
                       "the pane that stayed is now the first one")
        XCTAssertEqual(source.mode, .singleFile)
    }

    /// The moved pane brings its unsaved edits: it is moved, never re-read.
    func testAPaneDraggedToAnotherWindowKeepsItsEdits() throws {
        let (source, other, _, _) = try twoWindows()
        let moved = source.windowModel.pane1
        try moved.pasteWrite([0xFF, 0xFE])
        XCTAssertTrue(moved.status.isDirty, "the premise")

        other.performPaneDrop(draggedPaneID: moved.dragID, onPaneAt: 0)

        XCTAssertTrue(other.windowModel.pane1.status.isDirty)
    }

    // MARK: - The strip takes a pane too

    /// A pane let go on the strip leaves for a tab of its own — the same
    /// operation `Open in New Tab` performs from the pane's menu.
    func testAPaneDroppedOnTheStripTearsOffIntoANewTab() throws {
        let (source, a, b) = try comparison()
        let tab = MainViewController()
        source.makeSiblingTab = { tab }

        source.tearOffPaneToNewTab(draggedPaneID: source.windowModel.pane2.dragID)

        XCTAssertEqual(tab.windowModel.pane1.status.fileName, b.lastPathComponent)
        XCTAssertEqual(source.mode, .singleFile)
        XCTAssertEqual(source.windowModel.pane1.status.fileName, a.lastPathComponent)
    }

    /// The tab is made beside the window whose strip took the pane, not beside
    /// the one it came from: the gesture was aimed here.
    func testTheTornOffTabIsMadeBesideTheWindowThatTookIt() throws {
        let (source, other, _, b) = try twoWindows()
        let tab = MainViewController()
        var sourceAsked = 0
        source.makeSiblingTab = { sourceAsked += 1; return MainViewController() }
        other.makeSiblingTab = { tab }

        other.tearOffPaneToNewTab(draggedPaneID: source.windowModel.pane2.dragID)

        XCTAssertEqual(sourceAsked, 0, "the window it came from was not asked")
        XCTAssertEqual(tab.windowModel.pane1.status.fileName, b.lastPathComponent)
    }

    /// The marks come from the window the pane was read under, which is the one
    /// it left — not the one that happened to host the new tab.
    func testTheTornOffTabTakesTheSourceWindowsMarks() throws {
        let (source, other, _, _) = try twoWindows()
        let tab = MainViewController()
        other.makeSiblingTab = { tab }
        _ = source.windowModel.bookmarkStore.add(rowContaining: 0, name: "read here")
        _ = other.windowModel.bookmarkStore.add(rowContaining: 16, name: "not this one")

        other.tearOffPaneToNewTab(draggedPaneID: source.windowModel.pane2.dragID)

        XCTAssertEqual(tab.windowModel.bookmarkStore.bookmarks.map(\.name), ["read here"])
    }

    /// A pane whose window is gone tears nothing off.
    func testTearingOffAnUnknownPaneDoesNothing() throws {
        let (source, a, b) = try comparison()
        var asked = 0
        source.makeSiblingTab = { asked += 1; return MainViewController() }

        source.tearOffPaneToNewTab(draggedPaneID: UUID())

        XCTAssertEqual(asked, 0)
        XCTAssertEqual(source.windowModel.pane1.status.fileName, a.lastPathComponent)
        XCTAssertEqual(source.windowModel.pane2.status.fileName, b.lastPathComponent)
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

    // MARK: - Landing on a window that is not a comparison

    /// A pane dropped on a single-file window joins it as the second pane —
    /// which is the comparison the gesture was for. This is the case that did
    /// not work at first: only the comparison-mode overlay was registered for a
    /// pane drag, so a single-file tab had nobody waiting.
    func testAPaneMovesIntoASingleFileWindowsFreePane() throws {
        let registry = OpenDocumentRegistry()
        let (source, a, b) = try comparison()
        let lone = MainViewController()
        let c = try tempFile([UInt8](repeating: 0xC0, count: 64))
        lone.openFiles([c])
        for controller in [source, lone] {
            controller.openDocuments = registry
            registry.register(controller)
        }
        liveRegistry = registry
        XCTAssertEqual(lone.mode, .singleFile, "the premise")

        XCTAssertEqual(lone.paneDropOutcome(draggedPaneID: source.windowModel.pane2.dragID,
                                            onPaneAt: 1),
                       .move(intoPane: 1))
        lone.performPaneDrop(draggedPaneID: source.windowModel.pane2.dragID, onPaneAt: 1)

        XCTAssertEqual(lone.mode, .comparison, "the dropped pane made it a comparison")
        XCTAssertEqual(lone.windowModel.pane1.status.fileName, c.lastPathComponent)
        XCTAssertEqual(lone.windowModel.pane2.status.fileName, b.lastPathComponent)
        XCTAssertEqual(source.mode, .singleFile)
        XCTAssertEqual(source.windowModel.pane1.status.fileName, a.lastPathComponent)
    }

    /// A pane dropped on an empty window fills it.
    func testAPaneMovesIntoAnEmptyWindow() throws {
        let registry = OpenDocumentRegistry()
        let (source, a, b) = try comparison()
        let empty = MainViewController()
        for controller in [source, empty] {
            controller.openDocuments = registry
            registry.register(controller)
        }
        liveRegistry = registry
        XCTAssertEqual(empty.mode, .empty, "the premise")

        empty.performPaneDrop(draggedPaneID: source.windowModel.pane2.dragID, onPaneAt: 0)

        XCTAssertEqual(empty.mode, .singleFile)
        XCTAssertEqual(empty.windowModel.pane1.status.fileName, b.lastPathComponent)
        XCTAssertEqual(source.windowModel.pane1.status.fileName, a.lastPathComponent)
    }

    // MARK: - Joining one pane into another

    /// The ends of a pane's bands mean for a pane what they mean for a file:
    /// join this at the front, join it at the back. A pane holds a dump, so
    /// joining one into another is the two-chip round trip (§22) with the second
    /// chip already open.
    func testTheEndBandsJoinAPaneIntoAnother() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 1, inOriginWindow: true,
                                                    band: .insertAtStart)),
                       .join(intoPane: 1, at: .start))
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 1, inOriginWindow: true,
                                                    band: .appendAtEnd)),
                       .join(intoPane: 1, at: .end))
    }

    /// The middle band keeps its old meanings, which differ by where the pane
    /// came from.
    func testTheMiddleBandSwapsOrMoves() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 1, inOriginWindow: true,
                                                    band: .replace)),
                       .swap)
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 1, inOriginWindow: false,
                                                    band: .replace)),
                       .move(intoPane: 1))
    }

    /// A pane dropped on its own end bands joins itself — the same doubling a
    /// file dropped on the pane it is already open in performs. Only the middle
    /// band is meaningless there: trading a pane with itself is the gesture
    /// abandoned, not performed.
    func testAPaneCanJoinItselfButNotSwapWithItself() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 1,
                                        onto: .pane(index: 1, inOriginWindow: true,
                                                    band: .insertAtStart)),
                       .join(intoPane: 1, at: .start))
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 1,
                                        onto: .pane(index: 1, inOriginWindow: true,
                                                    band: .appendAtEnd)),
                       .join(intoPane: 1, at: .end))
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 1,
                                        onto: .pane(index: 1, inOriginWindow: true,
                                                    band: .replace)),
                       .none)
    }

    /// Joining a pane to itself doubles its content, and asks first — the same
    /// question a file joined to itself asks, in the same words.
    func testJoiningAPaneToItselfDoublesItAfterAsking() throws {
        let controller = MainViewController()
        let a = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let b = try tempFile([UInt8](repeating: 0xBB, count: 16))
        controller.openFiles([a, b])
        var asked: NSAlert?
        MainViewController.modalResponder = { alert in
            asked = alert
            return .alertFirstButtonReturn
        }
        addTeardownBlock { MainViewController.modalResponder = nil }

        controller.performPaneDrop(draggedPaneID: controller.windowModel.pane1.dragID,
                                   onPaneAt: 0, band: .appendAtEnd)

        let alert = try XCTUnwrap(asked, "a pane joined to itself must ask")
        XCTAssertTrue(alert.messageText.contains("to itself"))
        XCTAssertEqual(controller.windowModel.pane1.fileSize, 32, "the dump, twice")
    }

    /// Cancelled, it changes nothing.
    func testCancellingASelfJoinOfAPaneChangesNothing() throws {
        let controller = MainViewController()
        let a = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let b = try tempFile([UInt8](repeating: 0xBB, count: 16))
        controller.openFiles([a, b])
        MainViewController.modalResponder = { _ in .alertSecondButtonReturn }
        addTeardownBlock { MainViewController.modalResponder = nil }

        controller.performPaneDrop(draggedPaneID: controller.windowModel.pane1.dragID,
                                   onPaneAt: 0, band: .insertAtStart)

        XCTAssertEqual(controller.windowModel.pane1.fileSize, 16)
    }

    /// The join runs, and the pane it came from is left exactly as it was: a
    /// join copies. Dropping a file to append it does not consume the file, and
    /// dropping a pane does not consume the pane.
    func testJoiningLeavesTheSourcePaneAlone() throws {
        let (controller, a, b) = try comparison()
        let sizeBefore = controller.windowModel.pane1.fileSize
        let sourceSize = controller.windowModel.pane2.fileSize
        controller.joinConfirm = { _ in .alertFirstButtonReturn }

        controller.performPaneDrop(draggedPaneID: controller.windowModel.pane2.dragID,
                                   onPaneAt: 0, band: .appendAtEnd)

        XCTAssertEqual(controller.windowModel.pane1.fileSize, sizeBefore + sourceSize,
                       "the bytes arrived")
        XCTAssertEqual(controller.windowModel.pane2.fileSize, sourceSize,
                       "the pane they came from is untouched")
        XCTAssertEqual(controller.windowModel.pane2.status.fileName, b.lastPathComponent)
        XCTAssertTrue(controller.windowModel.pane1.isUntitled,
                      "a join detaches the joined pane from its file (§22.2)")
        XCTAssertNotEqual(controller.windowModel.pane1.status.fileName, a.lastPathComponent)
    }

    /// Joining at the start puts the source's bytes first.
    func testJoiningAtTheStartPutsTheSourceFirst() throws {
        let controller = MainViewController()
        let a = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let b = try tempFile([UInt8](repeating: 0xBB, count: 16))
        controller.openFiles([a, b])
        controller.joinConfirm = { _ in .alertFirstButtonReturn }

        controller.performPaneDrop(draggedPaneID: controller.windowModel.pane2.dragID,
                                   onPaneAt: 0, band: .insertAtStart)

        let joined = controller.windowModel.pane1
        XCTAssertEqual(joined.fileSize, 32)
        XCTAssertEqual(joined.hexByteStates(in: 0..<1).first?.byte, 0xBB, "the source leads")
        XCTAssertEqual(joined.hexByteStates(in: 16..<17).first?.byte, 0xAA)
    }

    /// A join needs bytes on both sides; an empty target has nothing to join to,
    /// which is the one thing the pure rule cannot see.
    func testJoiningIntoAnEmptyPaneIsRefused() throws {
        let controller = MainViewController()
        let a = try tempFile([UInt8](repeating: 0xAA, count: 16))
        controller.openFiles([a])

        XCTAssertEqual(controller.paneDropOutcome(draggedPaneID: controller.windowModel.pane1.dragID,
                                                  onPaneAt: 1, band: .appendAtEnd),
                       .none)
    }

    // MARK: - Everything that takes a pane says so

    /// Every view that handles a dropped pane must also be registered for the
    /// type, or AppKit never delivers the drag and the zone simply never
    /// appears. Handling without registering is silent — no error, no warning,
    /// nothing on screen — and it has now happened twice: once in comparison
    /// mode, once in single-file. This is the check that makes the third time
    /// a test failure.
    func testEveryPaneDestinationIsRegisteredForThePaneType() throws {
        let pane = FilePaneView(viewModel: PaneViewModel())

        let destinations: [(String, NSView)] = [
            ("the single-file container", SingleFileDropView(paneView: pane)),
            ("the empty window", EmptyStateView()),
            ("a comparison pane's overlay", PaneDropBandsView(paneView: pane)),
            ("the New Tab strip", NewTabDropStrip()),
        ]

        for (name, view) in destinations {
            XCTAssertTrue(view.registeredDraggedTypes.contains(.pane),
                          "\(name) handles a dropped pane but is not registered for one")
        }
    }

    // MARK: - A single-file window's four zones

    /// A dragged pane gets the same four zones a file gets, and they map onto
    /// the same four meanings: the far half is the free second pane, the three
    /// bands are the pane already open.
    func testTheSingleFileZonesMapToPanesTheSameWayTheyDoToFiles() {
        XCTAssertEqual(MainViewController.singleFilePaneDrop(.addSecond).index, 1)
        XCTAssertEqual(MainViewController.singleFilePaneDrop(.addSecond).band, .addSecond)

        for band: SingleFileDropTarget in [.insertAtStart, .replace, .appendAtEnd] {
            let mapped = MainViewController.singleFilePaneDrop(band)
            XCTAssertEqual(mapped.index, 0, "\(band) acts on the pane that is open")
            XCTAssertEqual(mapped.band, band)
        }
    }

    /// Dropped on the far half, the pane opens as the second one — the
    /// comparison the gesture was for.
    func testTheSecondHalfOpensADraggedPaneBesideTheFirst() throws {
        let registry = OpenDocumentRegistry()
        let (source, _, b) = try comparison()
        let lone = MainViewController()
        let c = try tempFile([UInt8](repeating: 0xC0, count: 64))
        lone.openFiles([c])
        for controller in [source, lone] {
            controller.openDocuments = registry
            registry.register(controller)
        }
        liveRegistry = registry

        let (index, band) = MainViewController.singleFilePaneDrop(.addSecond)
        lone.performPaneDrop(draggedPaneID: source.windowModel.pane2.dragID,
                             onPaneAt: index, band: band)

        XCTAssertEqual(lone.mode, .comparison)
        XCTAssertEqual(lone.windowModel.pane1.status.fileName, c.lastPathComponent)
        XCTAssertEqual(lone.windowModel.pane2.status.fileName, b.lastPathComponent)
    }

    /// Dropped on the end band over the open file, the pane joins it — the same
    /// operation the same band performs for a file.
    func testAnEndBandJoinsADraggedPaneIntoTheOpenFile() throws {
        let registry = OpenDocumentRegistry()
        let (source, _, _) = try comparison()
        let lone = MainViewController()
        let c = try tempFile([UInt8](repeating: 0xC0, count: 16))
        lone.openFiles([c])
        for controller in [source, lone] {
            controller.openDocuments = registry
            registry.register(controller)
        }
        liveRegistry = registry
        lone.joinConfirm = { _ in .alertFirstButtonReturn }
        let sourceSize = source.windowModel.pane2.fileSize

        let (index, band) = MainViewController.singleFilePaneDrop(.appendAtEnd)
        lone.performPaneDrop(draggedPaneID: source.windowModel.pane2.dragID,
                             onPaneAt: index, band: band)

        XCTAssertEqual(lone.windowModel.pane1.fileSize, 16 + sourceSize)
        XCTAssertEqual(lone.mode, .singleFile, "a join does not make a second pane")
        XCTAssertEqual(source.windowModel.pane2.fileSize, sourceSize,
                       "the pane it came from is untouched")
    }

    // MARK: - Crossing a zone with nothing to offer

    /// The overlay must not forget what is in flight when it hides its bands.
    ///
    /// The middle band of a pane's own slot is the one zone with nothing to
    /// offer, so the bands go away there. Clearing the dragged pane at the same
    /// time meant the overlay answered "no" for the rest of the drag: entering
    /// from outside worked, moving out of the middle band did not.
    func testCrossingTheRefusedMiddleBandDoesNotEndTheDrag() throws {
        let bands = PaneDropBandsView(paneView: FilePaneView(viewModel: PaneViewModel()))
        bands.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        bands.layout()
        let dragged = UUID()
        var asked: [SingleFileDropTarget] = []
        bands.paneDropOutcome = { _, band, _ in
            asked.append(band)
            // The shape of a pane over its own slot: the ends join, the middle
            // has nothing.
            switch band {
            case .insertAtStart: return .join(intoPane: 0, at: .start)
            case .appendAtEnd: return .join(intoPane: 0, at: .end)
            default: return .none
            }
        }

        // Enter on the middle band, where there is nothing to offer…
        XCTAssertEqual(bands.paneDragEnteredForTesting(dragged, at: .replace), [])
        // …then move to an end band, which has. This step knows nothing but what
        // the entry remembered, which is the whole point.
        XCTAssertEqual(bands.paneDragMovedForTesting(to: .insertAtStart), .copy)
        // The captions ask for every band's own outcome, so the exact sequence is
        // longer than the two moves; what matters is that asking continued at
        // all after the first no.
        XCTAssertTrue(asked.contains(.insertAtStart),
                      "the overlay kept asking rather than giving up after the first no")
    }

    /// A lone pane can be joined to itself in a single-file window: the same two
    /// bands, the same doubling. The middle band means nothing for a pane
    /// already in this window; the far half copies it instead.
    func testASingleFileWindowsOwnPaneCanJoinItself() throws {
        let controller = MainViewController()
        let a = try tempFile([UInt8](repeating: 0xAA, count: 16))
        controller.openFiles([a])
        let own = controller.windowModel.pane1.dragID

        for (target, expected) in [(SingleFileDropTarget.insertAtStart,
                                    PaneDrop.Outcome.join(intoPane: 0, at: .start)),
                                   (.appendAtEnd, .join(intoPane: 0, at: .end)),
                                   (.replace, .none),
                                   // The far half copies rather than refusing:
                                   // the dump beside itself is `Duplicate`.
                                   (.addSecond, .duplicate(intoPane: 1))] {
            let (index, band) = MainViewController.singleFilePaneDrop(target)
            XCTAssertEqual(controller.paneDropOutcome(draggedPaneID: own,
                                                      onPaneAt: index, band: band),
                           expected, "zone \(target)")
        }
    }

    /// A pane already in a window cannot be *moved* to its free pane — it is
    /// already in that window — but it can be **copied** there, which is what
    /// `File ▸ Duplicate` does: the dump beside itself, so a patch made on the
    /// copy shows every difference it causes.
    func testAWindowsOwnPaneIsDuplicatedIntoItsFreeSlot() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 1, inOriginWindow: true,
                                                    band: .addSecond)),
                       .duplicate(intoPane: 1))
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0,
                                        onto: .pane(index: 1, inOriginWindow: false,
                                                    band: .addSecond)),
                       .move(intoPane: 1), "a pane from elsewhere moves rather than copies")
    }

    /// Dropped on the second-pane zone, a single-file window's own pane leaves a
    /// copy of itself beside it — the same document `File ▸ Duplicate` makes,
    /// untitled and sharing its content until one of them is written.
    func testDroppingAWindowsOwnPaneOnTheSecondZoneDuplicatesIt() throws {
        let controller = MainViewController()
        let a = try tempFile([UInt8](repeating: 0xAA, count: 48))
        controller.openFiles([a])
        let own = controller.windowModel.pane1.dragID

        let (index, band) = MainViewController.singleFilePaneDrop(.addSecond)
        XCTAssertEqual(controller.paneDropOutcome(draggedPaneID: own, onPaneAt: index,
                                                  band: band),
                       .duplicate(intoPane: 1))
        controller.performPaneDrop(draggedPaneID: own, onPaneAt: index, band: band)

        XCTAssertEqual(controller.mode, .comparison)
        XCTAssertEqual(controller.windowModel.pane1.status.fileName, a.lastPathComponent,
                       "the original stays where it was")
        XCTAssertTrue(controller.windowModel.pane2.isUntitled, "the copy is a new document")
        XCTAssertEqual(controller.windowModel.pane2.fileSize, 48)
    }

    /// The `.addSecond` band stands for the free half of a single-file window,
    /// so a copy aimed at it is refused once that pane is taken — the band is
    /// not on screen then. (The middle band is the one that may replace.)
    func testDuplicatingByDropNeedsAFreePaneAndBytes() throws {
        let controller = MainViewController()
        let a = try tempFile([UInt8](repeating: 0xAA, count: 48))
        let b = try tempFile([UInt8](repeating: 0xBB, count: 48))
        controller.openFiles([a, b])
        let (index, band) = MainViewController.singleFilePaneDrop(.addSecond)

        XCTAssertEqual(controller.paneDropOutcome(draggedPaneID: controller.windowModel.pane1.dragID,
                                                  onPaneAt: index, band: band),
                       .none, "both panes are taken; there is nowhere to put a copy")
    }

    /// A copy leaves its source alone, so the cursor says copy rather than move,
    /// and the zone says what it will do rather than where it will put it.
    func testADuplicateIsReportedAsACopy() {
        XCTAssertEqual(PaneDropBandsView.paneBandTitle(for: .duplicate(intoPane: 1)),
                       "Duplicate Here")
        XCTAssertTrue(PaneDrop.Outcome.duplicate(intoPane: 1).isDuplicate)
        XCTAssertFalse(PaneDrop.Outcome.move(intoPane: 1).isDuplicate,
                       "a pane from elsewhere moves; the zone keeps its own name for that")
    }

    // MARK: - What a zone says

    /// Every band is captioned from its own outcome. Asking once for the band
    /// under the pointer and using that answer for all three left the others
    /// saying something they do not do — and the middle band, over a pane's own
    /// slot, saying nothing at all: an empty grey plate.
    func testEachBandIsCaptionedFromItsOwnOutcome() {
        // The same words a file gets, from the same place: it is the same
        // operation, and a second vocabulary for it would only suggest a
        // difference that does not exist.
        XCTAssertEqual(PaneDropBandsView.paneBandTitle(for: .join(intoPane: 0, at: .start)),
                       SingleFileDropTarget.insertAtStart.title)
        XCTAssertEqual(PaneDropBandsView.paneBandTitle(for: .join(intoPane: 0, at: .end)),
                       SingleFileDropTarget.appendAtEnd.title)
        XCTAssertEqual(SingleFileDropTarget.insertAtStart.title, "Insert at Start")
        XCTAssertEqual(SingleFileDropTarget.appendAtEnd.title, "Append at End")
        XCTAssertEqual(PaneDropBandsView.paneBandTitle(for: .swap), "Swap Panes")
        XCTAssertEqual(PaneDropBandsView.paneBandTitle(for: .move(intoPane: 1)), "Move Here")
    }

    /// A band with nothing to offer has no caption to give, and says so with a
    /// symbol rather than with an empty plate.
    func testARefusingBandShowsTheRefusalSymbol() {
        XCTAssertNil(PaneDropBandsView.paneBandTitle(for: .none),
                     "nothing to say means the symbol, not an empty caption")

        let zone = DropTargetView(title: "Swap Panes")
        XCTAssertFalse(zone.isShowingRefusal)

        zone.setRefused()
        XCTAssertTrue(zone.isShowingRefusal)

        zone.setTitle("Move Here")
        XCTAssertFalse(zone.isShowingRefusal, "a caption puts the symbol away again")
    }

    /// Over its own slot a pane can join at either end and nothing else, so the
    /// middle band is the one that shows the refusal.
    func testTheMiddleBandIsTheOneThatRefusesOverAPanesOwnSlot() {
        let own = { (band: SingleFileDropTarget) in
            PaneDrop.outcome(draggingPaneAt: 0,
                             onto: .pane(index: 0, inOriginWindow: true, band: band))
        }

        XCTAssertNotNil(PaneDropBandsView.paneBandTitle(for: own(.insertAtStart)))
        XCTAssertNotNil(PaneDropBandsView.paneBandTitle(for: own(.appendAtEnd)))
        XCTAssertNil(PaneDropBandsView.paneBandTitle(for: own(.replace)))
    }

    /// The captions come from the resolver the caller hands in, not from the
    /// overlay's own provider — which in single-file mode is nil, because the
    /// container owns it. Asking itself there returned "nothing" for every band
    /// and put the refusal symbol on all three, insert and append included.
    func testBandCaptionsComeFromTheResolverTheCallerHandsIn() {
        let bands = PaneDropBandsView(paneView: FilePaneView(viewModel: PaneViewModel()))
        bands.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        bands.layout()
        // Deliberately left nil, the way the single-file container leaves it.
        XCTAssertNil(bands.paneDropOutcome)

        bands.retitleBands(forPane: UUID()) { band in
            switch band {
            case .insertAtStart: return .join(intoPane: 0, at: .start)
            case .appendAtEnd: return .join(intoPane: 0, at: .end)
            default: return .none
            }
        }

        XCTAssertFalse(bands.bandForTesting(.insertAtStart).isShowingRefusal,
                       "the end bands have something to offer and say so")
        XCTAssertFalse(bands.bandForTesting(.appendAtEnd).isShowingRefusal)
        XCTAssertTrue(bands.bandForTesting(.replace).isShowingRefusal,
                      "only the band with nothing to offer shows the symbol")
    }

    // MARK: - The header is chrome, not document

    /// The header the pane is dragged by has a fill of its own and a hairline
    /// under it.
    ///
    /// The dump and the column header above it both draw `textBackgroundColor`,
    /// so a header without one dissolved into them: the pane read as one flat
    /// sheet from the tab bar down, and the strip meant to be grabbed had no
    /// visible edge. `windowBackgroundColor` is the window's own grey — the
    /// relationship a toolbar has to the content beside it.
    func testTheHeaderCarriesItsOwnBackgroundAndEdge() throws {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        header.layoutSubtreeIfNeeded()

        XCTAssertNotNil(header.layer?.backgroundColor,
                        "the header fills itself rather than showing what is behind it")

        // The premise, and the reason the obvious colour was not the one taken.
        // Measured, not assumed: on this OS `windowBackgroundColor` and
        // `textBackgroundColor` are the same colour in both appearances, so a
        // header filled with the first would be exactly as flat as no fill.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                XCTAssertEqual(NSColor.windowBackgroundColor.cgColor,
                               NSColor.textBackgroundColor.cgColor,
                               "\(appearance.rawValue): the window grey is the document white")
                XCTAssertNotEqual(NSColor.tertiarySystemFill.cgColor,
                                  NSColor.textBackgroundColor.cgColor,
                                  "\(appearance.rawValue): the fill actually differs")
            }
        }

        let separator = try XCTUnwrap(header.subviews.first {
            $0.frame.height == 1 && $0.frame.width == header.bounds.width
        }, "a hairline along the bottom edge")
        XCTAssertEqual(separator.frame.minY, 0, "at the bottom, against the dump")
    }

    // MARK: - Where the keys go after a join

    /// The pane that received the bytes becomes the active one.
    ///
    /// The join centres the caret on its seam in *that* pane (§22.5), so the
    /// eyes have already been sent there; leaving the active pane pointed at the
    /// other one splits where you are looking from where you are typing.
    func testAJoinedPaneBecomesActive() throws {
        let controller = MainViewController()
        let a = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let b = try tempFile([UInt8](repeating: 0xBB, count: 16))
        controller.openFiles([a, b])
        controller.windowModel.setActivePane(0)
        controller.joinConfirm = { _ in .alertFirstButtonReturn }

        // Drag pane 1 onto pane 2's end band: the bytes land in pane 2.
        controller.performPaneDrop(draggedPaneID: controller.windowModel.pane1.dragID,
                                   onPaneAt: 1, band: .appendAtEnd)

        XCTAssertEqual(controller.windowModel.pane2.fileSize, 32, "the join happened there")
        XCTAssertEqual(controller.windowModel.activePaneIndex, 1,
                       "the keys follow the bytes")
    }

    /// The same for a file dropped on a pane's end band — it is the same
    /// operation, and the answer to "which pane am I typing into" should not
    /// depend on where the bytes came from.
    func testAPaneJoinedFromAFileBecomesActiveToo() throws {
        let controller = MainViewController()
        let a = try tempFile([UInt8](repeating: 0xAA, count: 16))
        let b = try tempFile([UInt8](repeating: 0xBB, count: 16))
        let donor = try tempFile([UInt8](repeating: 0xCC, count: 8))
        controller.openFiles([a, b])
        controller.windowModel.setActivePane(0)
        controller.joinConfirm = { _ in .alertFirstButtonReturn }

        controller.handleComparisonBandDrop(targetPane: 1, target: .insertAtStart, urls: [donor])

        XCTAssertEqual(controller.windowModel.pane2.fileSize, 24)
        XCTAssertEqual(controller.windowModel.activePaneIndex, 1)
    }

    // MARK: - Option turns a move into a copy

    /// Option is the platform's "copy rather than move", and it changes exactly
    /// the outcomes that move the pane.
    func testOptionTurnsAMoveIntoADuplicate() {
        let toOtherWindow = PaneDrop.Destination.pane(index: 1, inOriginWindow: false,
                                                      band: .replace)

        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0, onto: toOtherWindow),
                       .move(intoPane: 1))
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0, onto: toOtherWindow, copying: true),
                       .duplicate(intoPane: 1))
    }

    /// The strip too: the pane leaves for a tab of its own, or leaves a copy
    /// there and stays where it is.
    func testOptionMakesTheStripCopyRatherThanMove() {
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0, onto: .newTabStrip),
                       .tearOff(copying: false))
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0, onto: .newTabStrip, copying: true),
                       .tearOff(copying: true))
    }

    /// The middle band answers Option wherever it lands. Without it, a drop on
    /// the other pane of one's own window is the swap; with it, the band does
    /// what it does everywhere else and leaves a copy in that pane.
    func testOptionTurnsASwapIntoADuplicate() {
        let ownWindow = PaneDrop.Destination.pane(index: 1, inOriginWindow: true,
                                                  band: .replace)

        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0, onto: ownWindow), .swap)
        XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0, onto: ownWindow, copying: true),
                       .duplicate(intoPane: 1))
    }

    /// The join is the one outcome Option leaves alone: it already copies, since
    /// the pane it reads from is left as it was.
    func testOptionLeavesAJoinAlone() {
        let ownWindow = PaneDrop.Destination.pane(index: 1, inOriginWindow: true,
                                                  band: .insertAtStart)

        for copying in [false, true] {
            XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0, onto: ownWindow,
                                            copying: copying),
                           .join(intoPane: 1, at: .start), "copying: \(copying)")
        }
    }

    /// A pane dropped on itself is the gesture abandoned, Option or not — there
    /// is no copy of a pane into the slot it already occupies.
    func testOptionDoesNotMakeAPaneDroppedOnItselfDoAnything() {
        let itself = PaneDrop.Destination.pane(index: 0, inOriginWindow: true, band: .replace)

        for copying in [false, true] {
            XCTAssertEqual(PaneDrop.outcome(draggingPaneAt: 0, onto: itself, copying: copying),
                           .none, "copying: \(copying)")
        }
    }

    /// The captions follow the modifier, so a zone says which of the two it will
    /// do before the mouse comes up.
    func testTheCaptionFollowsTheModifier() {
        XCTAssertEqual(PaneDropBandsView.paneBandTitle(for: .move(intoPane: 1)), "Move Here")
        XCTAssertEqual(PaneDropBandsView.paneBandTitle(for: .duplicate(intoPane: 1)),
                       "Duplicate Here")
    }

    /// A band re-reads the modifier on every update, so pressing Option under a
    /// stationary pointer re-labels the zone rather than waiting for a move.
    func testABandRelabelsWhenTheModifierChanges() {
        let bands = PaneDropBandsView(paneView: FilePaneView(viewModel: PaneViewModel()))
        bands.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        bands.layout()
        bands.paneDropOutcome = { _, band, copying in
            guard band == .replace else { return .none }
            return copying ? .duplicate(intoPane: 1) : .move(intoPane: 1)
        }
        let dragged = UUID()

        XCTAssertEqual(bands.paneDragEnteredForTesting(dragged, at: .replace), .move)
        XCTAssertEqual(bands.bandForTesting(.replace).titleForTesting, "Move Here")

        XCTAssertEqual(bands.paneDragEnteredForTesting(dragged, at: .replace, copying: true),
                       .copy)
        XCTAssertEqual(bands.bandForTesting(.replace).titleForTesting, "Duplicate Here")
    }

    /// Option-dropping a pane on another window leaves it where it was and puts
    /// a copy in the target.
    func testOptionDroppingOnAnotherWindowCopiesRatherThanMoves() throws {
        let (source, other, a, b) = try twoWindows()
        let moved = source.windowModel.pane1

        other.performPaneDrop(draggedPaneID: moved.dragID, onPaneAt: 0,
                              band: .replace, copying: true)

        XCTAssertIdentical(source.windowModel.pane1, moved, "the pane stayed where it was")
        XCTAssertEqual(source.windowModel.pane1.status.fileName, a.lastPathComponent)
        XCTAssertEqual(source.windowModel.pane2.status.fileName, b.lastPathComponent)
        XCTAssertEqual(source.mode, .comparison, "the comparison it came from is intact")

        XCTAssertTrue(other.windowModel.pane1.isUntitled, "and the other window has a copy")
        XCTAssertEqual(other.windowModel.pane1.fileSize, moved.fileSize)
    }

    // MARK: - Every zone hears the modifier, not just the hovered one

    /// The strip re-captions itself for a modifier change it did not hear
    /// first — the pointer is over a band, and only that band is sent the
    /// update.
    func testTheStripRelabelsForAModifierHeardElsewhere() {
        let strip = NewTabDropStrip()
        strip.setDragActive(true, forPane: true)
        XCTAssertEqual(strip.titleForTesting, "Move to New Tab")

        strip.setPaneDragCopying(true)
        XCTAssertEqual(strip.titleForTesting, "Duplicate to New Tab")

        strip.setPaneDragCopying(false)
        XCTAssertEqual(strip.titleForTesting, "Move to New Tab", "and back again")
    }

    /// A file is opened in a new tab whether or not Option is down, so the
    /// strip's file caption does not answer the modifier at all.
    func testTheStripIgnoresTheModifierForAFileDrag() {
        let strip = NewTabDropStrip()
        strip.setDragActive(true, forPane: false)

        strip.setPaneDragCopying(true)

        XCTAssertEqual(strip.titleForTesting, "Open in New Tab")
    }

    /// The bands do the same in the other direction: the pointer is over the
    /// strip, and the bands take the news second-hand.
    func testTheBandsRelabelForAModifierHeardElsewhere() {
        let bands = PaneDropBandsView(paneView: nil)
        bands.paneDropOutcome = { _, band, copying in
            guard band == .replace else { return .none }
            return copying ? .duplicate(intoPane: 1) : .move(intoPane: 1)
        }
        _ = bands.paneDragEnteredForTesting(UUID(), at: .replace)
        XCTAssertEqual(bands.bandForTesting(.replace).titleForTesting, "Move Here")

        bands.setPaneDragCopying(true)

        XCTAssertEqual(bands.bandForTesting(.replace).titleForTesting, "Duplicate Here")
    }

    /// The whole point, end to end: Option pressed while the pointer is over a
    /// pane's bands re-captions the strip above them too. Two zones describing
    /// one drop must not disagree — whichever the user reads has to be true.
    func testOptionOverAPaneRelabelsTheStripAsWell() throws {
        let (controller, _, _) = try comparison()
        let strip = controller.newTabStripForTesting
        strip.setDragActive(true, forPane: true)
        let bands = try XCTUnwrap(controller.comparisonBandsForTesting).1
        let dragged = controller.windowModel.pane1.dragID

        _ = bands.paneDragEnteredForTesting(dragged, at: .replace)
        XCTAssertEqual(strip.titleForTesting, "Move to New Tab")

        // The same band again with Option down, which is what an update carrying
        // a changed modifier looks like from here.
        _ = bands.paneDragEnteredForTesting(dragged, at: .replace, copying: true)

        XCTAssertEqual(bands.bandForTesting(.replace).titleForTesting, "Duplicate Here")
        XCTAssertEqual(strip.titleForTesting, "Duplicate to New Tab",
                       "the strip cannot go on promising a move")
    }

    /// Option-dropping a pane on the other pane of its own window copies into
    /// that pane instead of swapping: the dump beside itself, in one gesture.
    func testOptionDroppingOnTheOtherPaneCopiesInsteadOfSwapping() throws {
        let (controller, a, _) = try comparison()
        let source = controller.windowModel.pane1

        controller.performPaneDrop(draggedPaneID: source.dragID, onPaneAt: 1,
                                   band: .replace, copying: true)

        XCTAssertEqual(controller.windowModel.pane1.status.fileName, a.lastPathComponent,
                       "the source is untouched — no swap happened")
        XCTAssertTrue(controller.windowModel.pane2.isUntitled, "the other pane holds a copy")
        XCTAssertEqual(controller.windowModel.pane2.fileSize, source.fileSize)
        XCTAssertEqual(controller.windowModel.pane2.status.fileName,
                       DuplicateName.next(after: a.lastPathComponent,
                                          taken: [a.lastPathComponent]),
                       "and it is named after what it was copied from (§23)")
    }

    /// Option-dropping on the strip leaves the pane and opens a copy in the new
    /// tab.
    func testOptionDroppingOnTheStripCopiesIntoTheNewTab() throws {
        let (controller, a, b) = try comparison()
        let tab = MainViewController()
        controller.makeSiblingTab = { tab }

        controller.tearOffPaneToNewTab(draggedPaneID: controller.windowModel.pane2.dragID,
                                       copying: true)

        XCTAssertEqual(controller.mode, .comparison, "nothing left the window")
        XCTAssertEqual(controller.windowModel.pane1.status.fileName, a.lastPathComponent)
        XCTAssertEqual(controller.windowModel.pane2.status.fileName, b.lastPathComponent)
        XCTAssertTrue(tab.windowModel.pane1.isUntitled, "the new tab holds a copy")
        XCTAssertEqual(tab.windowModel.pane1.fileSize, controller.windowModel.pane2.fileSize)
    }
}
