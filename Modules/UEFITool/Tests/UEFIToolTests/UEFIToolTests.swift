import XCTest
@testable import UEFITool
import ToolModuleKit
import UEFIImage

/// The one zone is the node in focus and nothing else — the tree is the
/// parser's, and what crosses the seam is the single range worth drawing.
final class UEFIPresenterTests: XCTestCase {
    func testNothingSelectedPublishesNothing() {
        XCTAssertEqual(UEFIPresenter.zones(for: nil), .empty)
    }

    func testTheZoneIsTheSelectedNodeAndOnlyThat() {
        let node = UEFINode(
            id: NodeID([1, 2, 0]),
            kind: .file,
            name: "VTF",
            header: 0x1000..<0x1018,
            body: 0x1018..<0x1100
        )
        let zones = UEFIPresenter.zones(for: node)

        XCTAssertEqual(zones.zones.count, 1)
        XCTAssertEqual(zones.zones[0].id, "1.2.0")
        XCTAssertEqual(zones.zones[0].name, "VTF")
        XCTAssertEqual(zones.zones[0].range, 0x1000..<0x1100)
        XCTAssertEqual(zones.focus, "1.2.0")
    }

    /// The trip back: a zone id is a node path, and the panel has to read it
    /// to know which row to bring to the front.
    func testZoneIdsRoundTripToNodePaths() {
        let id = NodeID([1, 2, 0])
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: UEFIPresenter.zoneID(for: id)), id)
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "0"), NodeID([0]))
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "3.1"), NodeID([3, 1]))
    }

    func testAZoneIdThatIsNotAPathIsRejected() {
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: ""))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "root"))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "1.x"))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "1..2"))
    }
}

/// What the panel says about a node, by its type. Built in the pure target so
/// the view controller lays out what this decides rather than deciding itself.
final class UEFIDetailTests: XCTestCase {
    private func field(_ detail: UEFINodeDetail, _ label: String) -> String? {
        detail.fields.first { $0.label == label }?.value
    }

    func testAVolumeSaysWhatItsHeaderSays() {
        let built = TestUEFI.volume()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "FFSv2")
        XCTAssertEqual(field(detail, "Kind"), "Volume")
        XCTAssertEqual(field(detail, "Type"), "Revision 2")
        XCTAssertEqual(field(detail, "GUID"), "\(KnownGUIDs.ffsV2) (FFSv2)")
        XCTAssertEqual(field(detail, "Header"), "0x0 · 0x38 bytes")
        XCTAssertEqual(field(detail, "Body"), "0x38 · 0xFC8 bytes")
        XCTAssertEqual(field(detail, "Total"), "0x0 · 0x1000 bytes")
        XCTAssertEqual(field(detail, "Address"), "0xFFFF0000")
        XCTAssertEqual(field(detail, "Length"), "0x1000")
        XCTAssertEqual(field(detail, "Signature"), "0x56544152")
        XCTAssertEqual(field(detail, "Attributes"), "0x800 (Erase polarity)")
        XCTAssertEqual(field(detail, "Header length"), "0x38")
        XCTAssertEqual(field(detail, "Checksum"), "0x1234")
        XCTAssertEqual(field(detail, "Ext. header"), "0x0")
        XCTAssertEqual(field(detail, "Revision"), "2")
    }

    /// A volume whose file system GUID nobody documented is still shown by its
    /// GUID — the raw form, since there is no name to add.
    func testAnUnknownVolumeGuidShowsRaw() {
        let guid = EFIGUID(low: 0x11, high: 0x22)
        let built = TestUEFI.volume(guid: guid, name: "")
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "GUID"), guid.description)
        XCTAssertEqual(detail.title, "Volume")
    }

    func testAFileNamesItsTypeAndReadsBackItsHeader() {
        let built = TestUEFI.file(type: 0x07, attributes: 0x04, size: 0x100, state: 0x80)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "Volume Top File")
        XCTAssertEqual(field(detail, "Kind"), "FFS file")
        XCTAssertEqual(field(detail, "Type"), "Driver")
        XCTAssertEqual(field(detail, "Attributes"), "0x4 (Fixed)")
        XCTAssertEqual(field(detail, "Size"), "0x100")
        XCTAssertEqual(field(detail, "State"), "0x80 (Erase polarity)")
        XCTAssertEqual(field(detail, "Header checksum"), "0xAA")
        XCTAssertEqual(field(detail, "Body checksum"), "0xBB")
        XCTAssertEqual(field(detail, "Header"), "0x0 · 0x18 bytes")
    }

    /// A large file leaves the three-byte size at zero and keeps the real one
    /// in 64 bits — the detail has to follow the pointer, not show `0x0`.
    func testALargeFileReadsItsSizeFromTheLargeField() {
        var bytes = TestUEFI.file(size: 0).bytes
        let largeSize: UInt64 = 0x1_0000_0000
        let largeBytes = (0..<8).map { UInt8(truncatingIfNeeded: largeSize >> (8 * $0)) }
        for (index, byte) in largeBytes.enumerated() {
            bytes[0x18 + index] = byte
        }
        let node = TestUEFI.file(size: 0).node
        let image = UEFIImage(size: 0x1_0000_0000, roots: [node])
        let detail = UEFIDetail.build(for: node, image: image, reader: ImageReader(bytes))

        XCTAssertEqual(field(detail, "Size"), "0x100000000")
    }

    /// An unknown file type keeps its number in the name — the only thing there
    /// is to say about a vendor type nobody documented.
    func testAnUnknownFileTypeKeepsItsNumber() {
        let built = TestUEFI.file(type: 0x7F)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Type"), "File type 0x7F")
    }

    func testASectionNamesItsTypeAndSize() {
        let built = TestUEFI.section(type: 0x19, size: 0x40)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "Section")
        XCTAssertEqual(field(detail, "Type"), "Raw")
        XCTAssertEqual(field(detail, "Size"), "0x40")
        XCTAssertEqual(field(detail, "Header"), "0x0 · 0x4 bytes")
    }

    /// An extended-size section leaves the three-byte field at the marker and
    /// keeps the real size in 32 bits — the detail reads the 32-bit one.
    func testAnExtendedSectionReadsItsSizeInThirtyTwoBits() {
        let built = TestUEFI.section(type: 0x19, size: 0xFF_FFFF)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Size"), "0x100000")
        XCTAssertEqual(field(detail, "Header"), "0x0 · 0x8 bytes")
    }

    func testAMicrocodeHeaderComesBackValidated() {
        let built = TestUEFI.microcode(revision: 0xF0, signature: 0x0008_06EA, totalSize: 0x100)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "Microcode")
        XCTAssertEqual(field(detail, "Header type"), "0x1")
        XCTAssertEqual(field(detail, "Update revision"), "0xF0")
        XCTAssertEqual(field(detail, "Date"), "2019-07-15")
        XCTAssertEqual(field(detail, "Processor signature"), "0x806EA")
        XCTAssertEqual(field(detail, "Loader revision"), "0x1")
        XCTAssertEqual(field(detail, "Platform IDs"), "0x1")
        XCTAssertEqual(field(detail, "Data size"), "0x40")
        XCTAssertEqual(field(detail, "Total size"), "0x100")
    }

    /// Bytes that are not microcode do not pretend to be: the reader refuses
    /// them, and the detail falls back to what every node has.
    func testBytesThatAreNotMicrocodeShowNoMicrocodeFields() {
        var bytes = TestUEFI.microcode().bytes
        bytes[0] = 0x00  // HeaderType must be 1
        let built = TestUEFI.microcode()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: ImageReader(bytes))

        XCTAssertEqual(field(detail, "Kind"), "Microcode")
        XCTAssertEqual(field(detail, "Header type"), "0x0")
        XCTAssertNil(field(detail, "Update revision"))
        XCTAssertNil(field(detail, "Date"))
    }

    /// Padding has no header of its own: the size the common fields carry is
    /// the whole of what there is to say, and the title is the kind.
    func testPaddingShowsOnlyTheCommonFields() {
        let built = TestUEFI.padding(totalSize: 0x100)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "Padding")
        XCTAssertEqual(field(detail, "Kind"), "Padding")
        XCTAssertEqual(field(detail, "Total"), "0x0 · 0x100 bytes")
        XCTAssertNil(field(detail, "Length"))
        XCTAssertNil(field(detail, "Signature"))
    }

    /// A compressed node's address means nothing, so the one field worth
    /// skipping is skipped — not shown as a guess.
    func testACompressedNodeHasNoAddress() {
        let built = TestUEFI.file()
        var node = built.node
        node.isCompressed = true
        let detail = UEFIDetail.build(for: node, image: built.image, reader: built.reader)

        XCTAssertNil(field(detail, "Address"))
    }

    /// Without a volume top file no address in the image is knowable, so the
    /// field is absent rather than shown as zero.
    func testAnImageWithNoAddressMapHasNoAddress() {
        let built = TestUEFI.file()
        let image = UEFIImage(size: built.image.size, roots: [built.node])
        let detail = UEFIDetail.build(for: built.node, image: image, reader: built.reader)

        XCTAssertNil(field(detail, "Address"))
    }
}
