import XCTest
@testable import UEFIFormat

/// The tree a parse produces, and the three questions everything downstream
/// asks of it: what is here, what is at this offset, and where does this
/// address land.
final class UEFIImageTests: XCTestCase {
    private func node(
        _ name: String,
        _ range: Range<UInt64>,
        _ children: [UEFINode] = []
    ) -> UEFINode {
        UEFINode(
            kind: .volume,
            name: name,
            header: range.lowerBound..<(range.lowerBound + 8),
            body: (range.lowerBound + 8)..<range.upperBound,
            children: children
        )
    }

    private var image: UEFIImage {
        UEFIImage(size: 0x1000, roots: [
            node("volume", 0..<0x800, [
                node("file", 0x100..<0x200, [node("section", 0x118..<0x180)]),
                node("free", 0x200..<0x800)
            ]),
            node("padding", 0x900..<0x1000)
        ])
    }

    func testANodeSpansItsHeaderAndBody() {
        let file = UEFINode(kind: .file, name: "f", header: 0x10..<0x28, body: 0x28..<0x100)

        XCTAssertEqual(file.range, 0x10..<0x100)
    }

    /// Padding and free space have no header of their own, and a node that
    /// reported one would put a byte of the file inside a structure that is not
    /// there.
    func testAHeaderlessNodeIsAllBody() {
        let padding = UEFINode(kind: .padding, name: "p", range: 0x40..<0x80)

        XCTAssertEqual(padding.header, 0x40..<0x40)
        XCTAssertEqual(padding.body, 0x40..<0x80)
        XCTAssertEqual(padding.range, 0x40..<0x80)
    }

    /// FFSv1 files with a tail are the only ones that have one, and the node
    /// still has to cover it.
    func testATailIsPartOfTheNode() {
        let file = UEFINode(
            kind: .file, name: "f",
            header: 0..<0x18, body: 0x18..<0x30, tail: 0x30..<0x32
        )

        XCTAssertEqual(file.range, 0..<0x32)
    }

    func testFlatteningIsOutermostFirst() {
        XCTAssertEqual(
            image.allNodes.map(\.name),
            ["volume", "file", "section", "free", "padding"]
        )
    }

    /// A node's place in the tree is its identity, and it is stamped once the
    /// tree is finished rather than carried through the parse.
    func testIdsAreTheRouteFromTheRoot() {
        XCTAssertEqual(image.allNodes.map { "\($0.id)" }, ["0", "0.0", "0.0.0", "0.1", "1"])
        XCTAssertEqual(image.node(NodeID([0, 0, 0]))?.name, "section")
        XCTAssertEqual(image.node(NodeID([1]))?.name, "padding")
    }

    func testAnIdThatIsNotInTheTreeFindsNothing() {
        XCTAssertNil(image.node(NodeID([0, 5])))
        XCTAssertNil(image.node(NodeID([2])))
        XCTAssertNil(image.node(NodeID([-1])))
    }

    /// What a click in the dump means: the volume, then the file in it, then
    /// the section in that.
    func testTheChainAtAnOffsetIsOutermostFirst() {
        XCTAssertEqual(image.nodes(containing: 0x120).map(\.name), ["volume", "file", "section"])
        XCTAssertEqual(image.innermostNode(containing: 0x120)?.name, "section")
        XCTAssertEqual(image.innermostNode(containing: 0x108)?.name, "file")
    }

    func testAnOffsetNothingClaimsHasNoChain() {
        XCTAssertTrue(image.nodes(containing: 0x850).isEmpty)
        XCTAssertNil(image.innermostNode(containing: 0x2000))
    }

    /// Without a Volume Top File there are no addresses at all — not zero, not
    /// a guess (§5.7).
    func testAddressesAreUnknownWithoutTheAddressDiff() {
        XCTAssertNil(image.address(forOffset: 0x100))
        XCTAssertNil(image.offset(forAddress: 0xFFFF_F100))
    }

    func testAddressesMapBothWays() {
        let mapped = UEFIImage(size: 0x1000, roots: [], addressDiff: 0xFFFF_F000)

        XCTAssertEqual(mapped.address(forOffset: 0x100), 0xFFFF_F100)
        XCTAssertEqual(mapped.offset(forAddress: 0xFFFF_F100), 0x100)
    }

    /// A FIT entry pointing outside the image is the post-mortem of §11 in
    /// `FIT_TABLE_FORMAT.md`, and the answer has to be "nowhere", not a
    /// wrapped-around offset.
    func testAnAddressOutsideTheImageLandsNowhere() {
        let mapped = UEFIImage(size: 0x1000, roots: [], addressDiff: 0xFFFF_F000)

        XCTAssertNil(mapped.offset(forAddress: 0xFFFF_E000))
        XCTAssertNil(mapped.offset(forAddress: 0x1_0000_0000))
        XCTAssertNil(mapped.address(forOffset: 0x1000))
    }

    func testAnAddressThatWouldOverflowIsNil() {
        let mapped = UEFIImage(size: 0x1000, roots: [], addressDiff: .max)

        XCTAssertNil(mapped.address(forOffset: 0x100))
    }
}
