import XCTest
import UEFIImage
@testable import DumpCompare

/// Collapsing a node with hundreds of children does not stall the main thread.
///
/// The tree hands `UEFINode` values to `NSOutlineView` as its items. An item
/// has to be an object, so every one is bridged into a fresh box, and the
/// outline keys its item map by the box's `hash` and `isEqual:`. Without a
/// `Hashable` conformance on the node the bridge supplies an identity hash, so
/// two boxes over the same node never meet in the same bucket and every lookup
/// becomes a linear scan. Expanding only inserts and stays fast; collapsing
/// has to find and drop every descendant, and an NVRAM store with 400 entries
/// took 1.28 seconds of frozen UI to fold up.
///
/// This drives a bare outline view rather than the panel: what is under test is
/// the node as an outline item, and the panel's own wiring — what it selects,
/// what it publishes — is covered by `UEFIToolFlowTests`. The budget is far
/// above the fixed cost (milliseconds) and far below the stall, so a busy
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

    /// A data source shaped exactly like the panel's: the nodes themselves are
    /// the items.
    private final class Source: NSObject, NSOutlineViewDataSource {
        let root: UEFINode
        init(root: UEFINode) { self.root = root }

        func outlineView(_ view: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? UEFINode else { return 1 }
            return node.children.count
        }

        func outlineView(_ view: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? UEFINode else { return root }
            return node.children[index]
        }

        func outlineView(_ view: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? UEFINode)?.children.isEmpty == false
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

        let root = try XCTUnwrap(outline.item(atRow: 0))
        outline.expandItem(root)
        window.layoutIfNeeded()
        XCTAssertEqual(outline.numberOfRows, 401, "the store and its entries")

        let started = Date()
        outline.collapseItem(root)
        window.layoutIfNeeded()
        let spent = Date().timeIntervalSince(started)

        XCTAssertEqual(outline.numberOfRows, 1, "the store alone again")
        XCTAssertLessThan(spent, 0.3,
                          "collapsing 400 entries took \(spent)s — the node's hash "
                          + "is back to the bridge's identity one")
    }

    /// The hash is the node's `id` and nothing else: two nodes that agree on
    /// where they sit share a bucket whatever else differs, and — the point —
    /// hashing one never walks its children.
    func testANodeIsHashedByItsPlaceInTheTree() {
        let store = store(count: 3)
        var renamed = store
        renamed.name = "Something else"
        renamed.children = []

        XCTAssertNotEqual(store, renamed, "they are not the same node")
        XCTAssertEqual(store.hashValue, renamed.hashValue,
                       "the hash is the id, so it stays cheap on a big subtree")
    }
}
