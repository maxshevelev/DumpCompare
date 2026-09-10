import XCTest
import UEFIImage
@testable import DumpCompare

/// Collapsing a node with hundreds of children does not stall the main thread.
///
/// `NSOutlineView` keys its item map by each item's `hash` and `isEqual:`, and
/// an item has to be an object. Hand it a Swift *value* and every one is
/// bridged into a fresh box: without a cheap, stable hash two boxes over the
/// same thing land in different buckets and every lookup degrades into a
/// linear scan — invisible while expanding, which only inserts, and a stall
/// while collapsing, which has to find and drop every descendant. Measured on
/// a 400-child NVRAM store: 1.28 seconds of frozen UI to fold up.
///
/// The panel's answer is one row *object* per path (`UEFITreeRow`), which is
/// what this drives: identity is the hash, so the map behaves. It buys the
/// second half too — an object does not change under the outline when the node
/// behind it does, which is what keeps a row the reader opened open once its
/// branch arrives (`UEFIToolFlowTests`).
///
/// A bare outline view rather than the panel: what is under test is the item,
/// and the panel's own wiring is covered by `UEFIToolFlowTests`. The budget is
/// far above the fixed cost (milliseconds) and far below the stall, so a busy
/// machine does not turn this into a failure.
@MainActor
final class UEFITreeCollapseTests: XCTestCase {
    /// The shape that showed it: one store, `count` leaf entries under it.
    private func store(count: Int) -> UEFINode {
        let children = (0..<count).map { index -> UEFINode in
            let start = UInt64(0x1000 + index * 0x40)
            return UEFINode(
                id: NodeID([0, index]),
                kind: .vssEntry,
                subtype: 0,
                name: "SomeVariableName\(index)",
                guid: EFIGUID(low: 0x1234_5678_9ABC_DEF0, high: UInt64(index)),
                header: start..<(start + 0x20),
                body: (start + 0x20)..<(start + 0x40)
            )
        }
        return UEFINode(
            id: NodeID([0]),
            kind: .vssStore,
            name: "VSS store",
            header: 0..<0x1000,
            body: 0x1000..<UInt64(0x1000 + count * 0x40),
            children: children
        )
    }

    /// One row of the outline, by the place in the tree it stands for — the
    /// shape `UEFITreeRow` gives the panel, in a form this file can build.
    private final class Row {
        let id: NodeID
        init(_ id: NodeID) { self.id = id }
    }

    /// A data source shaped exactly like the panel's: a row object per path,
    /// handed out once and reused, with the node looked up behind it.
    private final class Source: NSObject, NSOutlineViewDataSource {
        let root: UEFINode
        private var rows: [NodeID: Row] = [:]
        init(root: UEFINode) { self.root = root }

        func row(_ id: NodeID) -> Row {
            if let row = rows[id] { return row }
            let row = Row(id)
            rows[id] = row
            return row
        }

        func node(_ id: NodeID) -> UEFINode? {
            var nodes = [root]
            var found: UEFINode?
            for index in id.path {
                guard index >= 0, index < nodes.count else { return nil }
                found = nodes[index]
                nodes = found!.children
            }
            return found
        }

        func outlineView(_ view: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item else { return 1 }
            guard let row = item as? Row, let node = node(row.id) else { return 0 }
            return node.children.count
        }

        func outlineView(_ view: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let item, let parent = item as? Row else { return row(NodeID([0])) }
            return row(parent.id.child(index))
        }

        func outlineView(_ view: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let row = item as? Row, let node = node(row.id) else { return false }
            return !node.children.isEmpty
        }
    }

    func testAStoreWithFourHundredEntriesCollapsesAtOnce() throws {
        let source = Source(root: store(count: 400))
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 300
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = source

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scroll.documentView = outline
        let window = makeTestWindow(width: 420, height: 620)
        window.contentView?.addSubview(scroll)
        outline.reloadData()

        let rootRow = try XCTUnwrap(outline.item(atRow: 0))
        outline.expandItem(rootRow)
        window.layoutIfNeeded()
        XCTAssertEqual(outline.numberOfRows, 401, "the store and its entries")

        let started = Date()
        outline.collapseItem(rootRow)
        window.layoutIfNeeded()
        let spent = Date().timeIntervalSince(started)

        XCTAssertEqual(outline.numberOfRows, 1, "the store alone again")
        XCTAssertLessThan(spent, 0.3,
                          "collapsing 400 entries took \(spent)s — the node's hash "
                          + "is back to the bridge's identity one")
    }

    /// The row for a path is one object, handed out again rather than rebuilt.
    /// That is the whole property the outline stands on: it recognises an item
    /// it is already holding, and nothing else.
    func testTheRowForAPathIsAlwaysTheSameObject() {
        let source = Source(root: store(count: 3))

        let first = source.row(NodeID([0, 1]))
        let again = source.row(NodeID([0, 1]))

        XCTAssertTrue(first === again, "the same place in the tree is the same row")
        XCTAssertFalse(first === source.row(NodeID([0, 2])), "a different place is not")
    }
}
