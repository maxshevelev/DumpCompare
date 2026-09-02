import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.3: the highlighted pane and the pane the user actually types into must
/// never diverge. Focus is the single source of truth — clicking the hex dump
/// makes its hex view first responder, which fires `onActivate`, which drives
/// the active-pane highlight. Chrome clicks (the header) route through the same
/// path (`focusHexView`), so every way of switching panes agrees.
///
/// Driven through the real `ComparisonView` and real hex views (same harness as
/// `HeaderFitWidthTests`): a synthesized click on a pane's dump or header must
/// produce the right `onPaneActivated` index and leave the window's first
/// responder on that pane's hex view.
@MainActor
final class ActivePaneTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "ComparisonPaneLayoutIsVertical")
        // The contour-padding rules depend on the word size; pin it so the
        // suite isn't at the mercy of whatever the shared defaults hold.
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    private func makeComparisonView(bytes1: [UInt8]? = nil, bytes2: [UInt8]? = nil) throws -> (ComparisonView, NSWindow, URL, URL) {
        let url1 = try tempFile(bytes1 ?? [UInt8](repeating: 0x41, count: 1024))
        let url2 = try tempFile(bytes2 ?? [UInt8](repeating: 0x42, count: 1024))
        let p1 = PaneViewModel()
        let p2 = PaneViewModel()
        try p1.open(url: url1)
        try p2.open(url: url2)
        let coordinator = ComparisonCoordinator { () -> (left: ByteStorage, right: ByteStorage)? in
            guard let l = p1.byteStorage, let r = p2.byteStorage else { return nil }
            return (l, r)
        }
        let cv = ComparisonView(coordinator: coordinator,
                                paneView1: FilePaneView(viewModel: p1),
                                paneView2: FilePaneView(viewModel: p2))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        cv.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(cv)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            cv.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            cv.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.layoutIfNeeded()
        return (cv, window, url1, url2)
    }

    /// The real header view of a pane (its topmost direct subview).
    private func header(of pane: FilePaneView) throws -> PaneHeaderView {
        try XCTUnwrap(pane.subviews.compactMap({ $0 as? PaneHeaderView }).first)
    }

    private func hexView(of pane: FilePaneView) throws -> HexView {
        try XCTUnwrap(pane.scrollView.documentView as? HexView)
    }

    /// Window point of the centre of byte `column` in `row` — a real clickable
    /// spot inside the hex grid.
    private func byteCentre(_ hexView: HexView, row: Int, column: Int) -> NSPoint {
        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.hexByteX(column: column) + layout.charWidth,
                            y: CGFloat(row) * layout.rowHeight)
        return hexView.convert(local, to: nil)
    }

    private func click(_ view: NSView, at p: NSPoint, window: NSWindow) {
        view.mouseDown(with: mouse(.leftMouseDown, at: p, window: window))
    }

    /// Clicking pane 1 after pane 2 has focus must switch activation back.
    func testClickingOtherDumpSwitchesActivation() throws {
        let (cv, window, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        var activated: [Int] = []
        cv.onPaneActivated = { activated.append($0) }

        let hex2 = try hexView(of: cv.paneView2)
        let hex1 = try hexView(of: cv.paneView1)
        click(hex2, at: byteCentre(hex2, row: 0, column: 4), window: window)
        click(hex1, at: byteCentre(hex1, row: 0, column: 4), window: window)

        XCTAssertEqual(activated, [1, 0])
        XCTAssertTrue(window.firstResponder === hex1)
    }

    /// Same guarantee from the other side: just focusing pane 2's dump must be
    /// what activates pane 2 — not a side effect of the header highlight. Then
    /// a header click on pane 1 must move both activation and focus to pane 1.
    func testFocusIsTheSingleSourceOfTruth() throws {
        let (cv, window, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        var activated: [Int] = []
        cv.onPaneActivated = { activated.append($0) }

        let hex2 = try hexView(of: cv.paneView2)
        let hex1 = try hexView(of: cv.paneView1)

        // Focusing a pane's dump alone must activate that pane.
        XCTAssertTrue(window.makeFirstResponder(hex2))
        XCTAssertEqual(activated, [1])
        XCTAssertTrue(window.firstResponder === hex2)

        // A header click then pulls both activation and focus to pane 1.
        let header1 = try header(of: cv.paneView1)
        click(header1, at: header1.convert(NSPoint(x: 20, y: header1.bounds.midY), to: nil), window: window)

        XCTAssertEqual(activated, [1, 0])
        XCTAssertTrue(window.firstResponder === hex1)
    }

    // MARK: - Selection independence & mirror (§3.3)

    /// Selections are independent per pane: moving one pane's selection leaves
    /// the other pane's selection untouched. The opposite pane's selection is
    /// *mirrored* as a single closed contour — one loop of line segments around
    /// the whole selected span in the hex column, one in the ASCII column.
    func testOppositePaneMirrorsSelectionWithContour() throws {
        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        // Pane 2 selects bytes 4…9 (range end exclusive).
        vm2.setSelection(SelectionModel(start: 4, end: 10, fileSize: 1024))

        // Pane 1 mirrors pane 2's selection as one closed loop around the hex
        // span and one around the ASCII span, padded off the glyphs.
        let hex1 = try hexView(of: cv.paneView1)
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 2, "one loop around the hex span, one around the ASCII span")
        let layout = hex1.hexLayout
        let pad = HexView.mirrorContourPadding
        XCTAssertEqual(loops[0], [
            CGPoint(x: layout.hexByteX(column: 4) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 9) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 9) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 4) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
        // The ASCII loop hugs the characters: no word gaps in the ASCII column,
        // so only its outer edges (column 0, column 15) get padding — a
        // mid-column selection sits flush against the neighbor chars.
        XCTAssertEqual(loops[1], [
            CGPoint(x: layout.asciiX(column: 4), y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 9) + layout.charWidth, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 9) + layout.charWidth, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.asciiX(column: 4), y: layout.rowFrame(row: 0).maxY),
        ])

        // The panes' selections are independent: pane 1's own selection is
        // still a caret at 0.
        XCTAssertTrue(vm1.hexSelection().isEmpty)
        XCTAssertEqual(vm1.hexSelection().start, 0)

        // Mirroring is symmetric — pane 2 mirrors pane 1's selection too. Pane
        // 1 is at a bare caret; a caret mirror lands only on the opposite
        // (inactive) pane, and pane 2 is the active one here, so nothing is
        // drawn.
        let hex2 = try hexView(of: cv.paneView2)
        XCTAssertTrue(hex2.mirrorContours().isEmpty)
    }

    /// A span that starts in the right of one row and ends in the left of the
    /// next shares no column between the two rows, so its outline is **two
    /// rectangles** rather than a staircase. Joined, the two parts were linked
    /// by a line running back across the row boundary, which outlined nothing.
    func testMirrorSplitsASpanWhoseRowsShareNoColumn() throws {
        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }
        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        // Columns 14…15 of row 0, then columns 0…1 of row 1.
        vm2.setSelection(SelectionModel(start: 14, end: 18, fileSize: 1024))

        let hex1 = try hexView(of: cv.paneView1)
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 4, "two rectangles per column region, not one staircase")
        let layout = hex1.hexLayout
        let pad = HexView.mirrorContourPadding
        let row0 = layout.rowFrame(row: 0)
        let row1 = layout.rowFrame(row: 1)
        XCTAssertEqual(loops[0], [
            CGPoint(x: layout.hexByteX(column: 14) - pad, y: row0.minY),
            CGPoint(x: layout.hexByteX(column: 15) + layout.hexByteWidth + pad, y: row0.minY),
            CGPoint(x: layout.hexByteX(column: 15) + layout.hexByteWidth + pad, y: row0.maxY),
            CGPoint(x: layout.hexByteX(column: 14) - pad, y: row0.maxY),
        ], "the first row's part, closed on itself")
        XCTAssertEqual(loops[1], [
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: row1.minY),
            CGPoint(x: layout.hexByteX(column: 1) + layout.hexByteWidth + pad, y: row1.minY),
            CGPoint(x: layout.hexByteX(column: 1) + layout.hexByteWidth + pad, y: row1.maxY),
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: row1.maxY),
        ], "and the next row's part, closed on its own")
        // Nothing traces the row boundary between them: the rows are
        // contiguous, so a loop that ran along it would have to reach above and
        // below that y — which is exactly what the staircase did.
        let boundary = row0.maxY
        XCTAssertFalse(loops.contains { loop in
            let ys = loop.map(\.y)
            return ys.min()! < boundary && ys.max()! > boundary
        }, "no loop covers both rows")
    }

    /// Two rows that *do* share a column are still one staircase: the split is
    /// for the case where joining them would outline nothing.
    func testMirrorKeepsTheStaircaseWhenTheRowsOverlap() throws {
        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }
        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        // Columns 2…15 of row 0, then columns 0…9 of row 1: they overlap.
        vm2.setSelection(SelectionModel(start: 2, end: 26, fileSize: 1024))

        let hex1 = try hexView(of: cv.paneView1)
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 2, "one staircase per column region")
        XCTAssertEqual(loops[0].count, 8, "and it is a staircase, not a rectangle")
    }

    /// A mirrored selection is clamped to this pane's file size: the contour
    /// stops at this pane's EOF, never past it (§9: shorter pane clamps to EOF).
    func testMirrorClampsToPaneFileSize() throws {
        let (cv, _, url1, url2) = try makeComparisonView(
            bytes1: [UInt8](repeating: 0x41, count: 8),   // pane 1 is shorter
            bytes2: [UInt8](repeating: 0x42, count: 1024)
        )
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        // Pane 2 selects bytes 0…15; pane 1 has only 8 bytes, so its mirror
        // contour stops at byte 7 (the hex loop covers columns 0…7).
        vm2.setSelection(SelectionModel(start: 0, end: 16, fileSize: 1024))

        let hex1 = try hexView(of: cv.paneView1)
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 2, "hex loop + ASCII loop")
        let layout = hex1.hexLayout
        let pad = HexView.mirrorContourPadding
        XCTAssertEqual(loops[0], [
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 7) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 7) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
        // Left edge at column 0 pads into the gap before the ASCII column; the
        // right edge at column 7 is not the column's outer edge, so it stays
        // flush against column 8's neighbor (nothing selected there).
        XCTAssertEqual(loops[1], [
            CGPoint(x: layout.asciiX(column: 0) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 7) + layout.charWidth, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 7) + layout.charWidth, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.asciiX(column: 0) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
    }

    /// One closed outline, whatever rows the span covers (§3.3). All four shapes
    /// a multi-row span can take go through the same table, because they differ
    /// in nothing but the *topology* of the resulting loop:
    ///
    /// * full rows only — a plain rectangle, no seam at the row boundary;
    /// * partial first and last row — a staircase stepping in on the first row's
    ///   left and the last row's right;
    /// * partial first row, last row ending at column 15 — no right step to make;
    /// * first row starting at column 0, partial last row — no left step.
    ///
    /// The last two are where the beak lived: a step edge of zero length leaves a
    /// pair of coincident vertices, and dropping only those leaves a
    /// straight-through vertex whose 0° "corner" the rounding pass sweeps into a
    /// semicircle bulging out of the outline. Both are asserted here as
    /// structure rather than as coordinates — every edge moves along exactly one
    /// axis (no zero-length edge survives) and consecutive edges alternate
    /// direction (no straight-through vertex survives) — which states the rule
    /// itself instead of one point array that happens to satisfy it.
    ///
    /// What each vertex's x *is* — how far an edge pads outside the glyphs — is
    /// pinned absolutely by `testMirrorContourPadsOnlyAtWordBoundaries`,
    /// `testOppositePaneMirrorsSelectionWithContour` and
    /// `testMirrorClampsToPaneFileSize`. Here an edge only has to sit on the
    /// right column's cell boundary, at most `mirrorContourPadding` outside it —
    /// enough to catch a step landing on the neighbouring byte.
    func testMirrorContourTopologyFollowsTheRowsTheSpanCovers() throws {
        /// A span and the loop shape it must produce. `stepsAtFirstRowBottom` is
        /// "the span starts mid-row, so the left edge steps in"; `stepsAtLastRowTop`
        /// is "the span ends before column 15, so the right edge steps in".
        struct Shape {
            let what: String
            let span: Range<UInt64>
            let vertices: Int
            let stepsAtFirstRowBottom: Bool
            let stepsAtLastRowTop: Bool
        }
        let shapes = [
            Shape(what: "rows 1 and 2 in full", span: 16..<48, vertices: 4,
                  stepsAtFirstRowBottom: false, stepsAtLastRowTop: false),
            Shape(what: "rows 0 (cols 4-15), 1 (all), 2 (cols 0-5)", span: 4..<38, vertices: 8,
                  stepsAtFirstRowBottom: true, stepsAtLastRowTop: true),
            Shape(what: "rows 0 (cols 4-15), 1 and 2 in full", span: 4..<48, vertices: 6,
                  stepsAtFirstRowBottom: true, stepsAtLastRowTop: false),
            Shape(what: "row 0 in full, row 1 (cols 0-5)", span: 0..<22, vertices: 6,
                  stepsAtFirstRowBottom: false, stepsAtLastRowTop: true),
        ]

        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        let hex1 = try hexView(of: cv.paneView1)
        let layout = hex1.hexLayout
        let pad = HexView.mirrorContourPadding
        // Both regions' cells, as x ranges per column: the loop's vertical edges
        // must land on one of these boundaries.
        let cells: [(name: String, minX: (Int) -> CGFloat, maxX: (Int) -> CGFloat)] = [
            ("hex", { layout.hexByteX(column: $0) },
                    { layout.hexByteX(column: $0) + layout.hexByteWidth }),
            ("ASCII", { layout.asciiX(column: $0) },
                      { layout.asciiX(column: $0) + layout.charWidth }),
        ]
        let last = HexLayout.bytesPerRow - 1

        for shape in shapes {
            vm2.setSelection(SelectionModel(start: shape.span.lowerBound,
                                            end: shape.span.upperBound, fileSize: 1024))
            let loops = hex1.mirrorContours()
            XCTAssertEqual(loops.count, 2,
                           "\(shape.what): one loop around the hex span, one around the ASCII span")
            guard loops.count == 2 else { continue }

            let rows = Int(HexLayout.bytesPerRow)
            let firstRow = Int(shape.span.lowerBound) / rows
            let lastRow = (Int(shape.span.upperBound) - 1) / rows
            let firstCol = Int(shape.span.lowerBound) % rows
            let lastCol = (Int(shape.span.upperBound) - 1) % rows
            let top = layout.rowFrame(row: firstRow).minY
            let bottom = layout.rowFrame(row: lastRow).maxY
            let firstRowBottom = layout.rowFrame(row: firstRow).maxY
            let lastRowTop = layout.rowFrame(row: lastRow).minY
            XCTAssertTrue(firstRow < lastRow, "\(shape.what): the fixture must span several rows")

            for (region, (name, cellMinX, cellMaxX)) in zip(loops, cells) {
                let label = "\(shape.what) [\(name)]"
                XCTAssertEqual(region.count, shape.vertices,
                               "\(label): the outline must have exactly \(shape.vertices) corners — "
                                   + "a surviving zero-length step or straight-through vertex adds one")

                // A closed rectilinear loop with no degenerate edge and no
                // straight-through vertex: the anti-beak rule, stated directly.
                let n = region.count
                for i in 0..<n {
                    let a = region[i], b = region[(i + 1) % n], c = region[(i + 2) % n]
                    let horizontal = a.y == b.y && a.x != b.x
                    let vertical = a.x == b.x && a.y != b.y
                    XCTAssertTrue(horizontal || vertical,
                                  "\(label): edge \(i) \(a)->\(b) must move along exactly one axis "
                                      + "— a zero-length or diagonal edge means a vertex was not dropped")
                    let nextHorizontal = b.y == c.y && b.x != c.x
                    XCTAssertNotEqual(horizontal, nextHorizontal,
                                      "\(label): vertex \((i + 1) % n) at \(b) is straight-through — "
                                          + "its 0° turn rounds into a beak")
                }

                // Which row edges the outline touches, and nothing else: a step
                // exists exactly where the span really is partial.
                var levels: [CGFloat: [CGFloat]] = [:]
                for point in region { levels[point.y, default: []].append(point.x) }
                var expected: Set<CGFloat> = [top, bottom]
                if shape.stepsAtFirstRowBottom { expected.insert(firstRowBottom) }
                if shape.stepsAtLastRowTop { expected.insert(lastRowTop) }
                XCTAssertEqual(Set(levels.keys), expected,
                               "\(label): the outline may only turn at the row edges its span is "
                                   + "partial at — a step at any other row edge is a seam")

                /// Asserts that `x` sits on `column`'s left (or right) cell
                /// boundary, flush or at most `pad` outside it.
                func assertLeftEdge(_ x: CGFloat, isLeftOf column: Int, _ message: String) {
                    XCTAssertTrue((cellMinX(column) - pad...cellMinX(column)).contains(x),
                                  "\(label): \(message) — x \(x) is not the left edge of column "
                                      + "\(column) (\(cellMinX(column)))")
                }
                func assertRightEdge(_ x: CGFloat, isRightOf column: Int, _ message: String) {
                    XCTAssertTrue((cellMaxX(column)...cellMaxX(column) + pad).contains(x),
                                  "\(label): \(message) — x \(x) is not the right edge of column "
                                      + "\(column) (\(cellMaxX(column)))")
                }

                // The top edge runs from the first selected byte to the end of
                // its row; the bottom edge from the start of the last row to the
                // last selected byte.
                let topXs = (levels[top] ?? []).sorted()
                XCTAssertEqual(topXs.count, 2, "\(label): the top edge has two ends")
                if topXs.count == 2 {
                    assertLeftEdge(topXs[0], isLeftOf: firstCol, "the outline starts at the first selected byte")
                    assertRightEdge(topXs[1], isRightOf: last, "the first row runs to the end of the row")
                }
                let bottomXs = (levels[bottom] ?? []).sorted()
                XCTAssertEqual(bottomXs.count, 2, "\(label): the bottom edge has two ends")
                if bottomXs.count == 2 {
                    assertLeftEdge(bottomXs[0], isLeftOf: 0, "the last row starts at the row's first byte")
                    assertRightEdge(bottomXs[1], isRightOf: lastCol, "the outline ends at the last selected byte")
                }
                // A step is a pair on one side: the left edge steps out to column
                // 0 below the first row, the right edge steps in to the last
                // selected byte above the last row.
                if shape.stepsAtFirstRowBottom {
                    let stepXs = (levels[firstRowBottom] ?? []).sorted()
                    XCTAssertEqual(stepXs.count, 2, "\(label): the left step has two ends")
                    if stepXs.count == 2 {
                        assertLeftEdge(stepXs[0], isLeftOf: 0, "below the first row the outline reaches column 0")
                        assertLeftEdge(stepXs[1], isLeftOf: firstCol, "the left step starts under the first selected byte")
                    }
                }
                if shape.stepsAtLastRowTop {
                    let stepXs = (levels[lastRowTop] ?? []).sorted()
                    XCTAssertEqual(stepXs.count, 2, "\(label): the right step has two ends")
                    if stepXs.count == 2 {
                        assertRightEdge(stepXs[0], isRightOf: lastCol, "the right step ends over the last selected byte")
                        assertRightEdge(stepXs[1], isRightOf: last, "above the last row the outline reaches column 15")
                    }
                }
            }
        }
    }

    /// With words larger than one byte, the hex contour pads only at word
    /// boundaries (where a spacer already exists): a selection starting or
    /// ending mid-word stays flush there, since padding would push the line
    /// onto the neighbor glyph. The ASCII column pads only at its outer edges.
    func testMirrorContourPadsOnlyAtWordBoundaries() throws {
        let previousWordSize = UserDefaults.standard.integer(forKey: WordSize.userDefaultsKey)
        UserDefaults.standard.set(2, forKey: WordSize.userDefaultsKey)
        defer { UserDefaults.standard.set(previousWordSize, forKey: WordSize.userDefaultsKey) }

        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        let hex1 = try hexView(of: cv.paneView1)
        let layout = hex1.hexLayout
        XCTAssertEqual(layout.wordSize, 2, "test expects 2-byte words")

        // Selection over columns 1…3 (bytes 1…3). Column 1 is mid-word (the
        // word 0–1 runs across it) and column 3 ends a word, so only the right
        // edge pads into the word spacer; the left edge stays flush.
        vm2.setSelection(SelectionModel(start: 1, end: 4, fileSize: 1024))
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 2)
        let pad = HexView.mirrorContourPadding
        XCTAssertEqual(loops[0], [
            CGPoint(x: layout.hexByteX(column: 1), y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 3) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 3) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 1), y: layout.rowFrame(row: 0).maxY),
        ])
        // The ASCII column packs characters with no spacers, so a mid-column
        // selection is flush on both sides.
        XCTAssertEqual(loops[1], [
            CGPoint(x: layout.asciiX(column: 1), y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 3) + layout.charWidth, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 3) + layout.charWidth, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.asciiX(column: 1), y: layout.rowFrame(row: 0).maxY),
        ])

        // Word-aligned edges (columns 0…3, both on word boundaries) pad fully.
        vm2.setSelection(SelectionModel(start: 0, end: 4, fileSize: 1024))
        XCTAssertEqual(hex1.mirrorContours()[0], [
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 3) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 3) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 0) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
    }

    /// A bare caret on the active pane mirrors onto the inactive pane as a
    /// single-byte contour — the same closed-contour treatment a selection
    /// gets, so the byte under the caret stays visible in the other file
    /// (§3.3). The active pane itself draws no caret contour: its own caret
    /// bar and cross-column link already mark the byte.
    func testBareCaretMirrorsOnInactivePane() throws {
        let (cv, _, url1, url2) = try makeComparisonView()
        defer { try? FileManager.default.removeItem(at: url1); try? FileManager.default.removeItem(at: url2) }

        let vm1 = cv.paneView1.viewModel
        let vm2 = cv.paneView2.viewModel
        vm1.companion = vm2
        vm2.companion = vm1

        // Pane 2 becomes active and its caret moves to byte 7; pane 1 mirrors
        // it as one loop around the hex byte and one around the ASCII char.
        cv.setActive(1)
        vm2.moveCaret(to: 7)

        XCTAssertEqual(vm1.caretOffset, 0, "selections are independent")
        let hex1 = try hexView(of: cv.paneView1)
        XCTAssertFalse(hex1.isActive)
        let loops = hex1.mirrorContours()
        XCTAssertEqual(loops.count, 2, "one loop around the hex byte, one around the ASCII char")
        let layout = hex1.hexLayout
        let pad = HexView.mirrorContourPadding
        // Word size 1: both edges of byte 7 are word boundaries, so they pad.
        XCTAssertEqual(loops[0], [
            CGPoint(x: layout.hexByteX(column: 7) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 7) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 7) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 7) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
        // ASCII packs its chars with no spacers: a mid-column byte is flush.
        XCTAssertEqual(loops[1], [
            CGPoint(x: layout.asciiX(column: 7), y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 7) + layout.charWidth, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 7) + layout.charWidth, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.asciiX(column: 7), y: layout.rowFrame(row: 0).maxY),
        ])

        // The active pane does not mirror the inactive pane's caret: a box on
        // the pane that owns the caret would double up on its own caret bar.
        let hex2 = try hexView(of: cv.paneView2)
        XCTAssertTrue(hex2.isActive)
        XCTAssertTrue(hex2.mirrorContours().isEmpty)
    }
}
