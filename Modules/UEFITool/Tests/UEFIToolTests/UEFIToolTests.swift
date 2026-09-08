import XCTest
@testable import UEFITool
import ToolModuleKit
import UEFIImage

/// What the selected node publishes: the node, and its body inside it — the
/// tree is the parser's, and what crosses the seam is only the ranges of the
/// one node worth drawing.
final class UEFIPresenterTests: XCTestCase {
    func testNothingSelectedPublishesNothing() {
        XCTAssertEqual(UEFIPresenter.zones(for: nil), .empty)
    }

    /// A node with a header of its own publishes two zones, and the body is
    /// the one in focus: it is what the node holds, and where it starts is
    /// where the header ended.
    func testANodeWithAHeaderPublishesItsBodyAndFocusesIt() {
        let node = UEFINode(
            id: NodeID([1, 2, 0]),
            kind: .file,
            name: "VTF",
            header: 0x1000..<0x1018,
            body: 0x1018..<0x1100
        )
        let zones = UEFIPresenter.zones(for: node)

        XCTAssertEqual(zones.zones.map(\.id), ["1.2.0", "1.2.0#body"],
                       "the node first, then what is inside it")
        XCTAssertEqual(zones.zones.map(\.range), [0x1000..<0x1100, 0x1018..<0x1100])
        XCTAssertEqual(zones.zones.map(\.name), ["VTF", "VTF body"])
        XCTAssertEqual(zones.focus, "1.2.0#body")
        XCTAssertFalse(zones.zones.contains { $0.id.hasSuffix("#header") },
                       "the header is not a zone — the body's start is where it ended")
    }

    /// Both survive the map the dump actually draws: nesting is legal, and the
    /// focus still names a zone that is in it.
    func testTheNestedZonesSurviveNormalisation() throws {
        let node = UEFINode(
            id: NodeID([0]),
            kind: .volume,
            name: "FFSv2",
            header: 0x0..<0x48,
            body: 0x48..<0x1000
        )
        let drawable = UEFIPresenter.zones(for: node).normalized(contentSize: 0x1000)

        XCTAssertEqual(drawable.zones.count, 2)
        XCTAssertEqual(drawable.focus, "0#body")
        XCTAssertEqual(drawable.zones(containing: 0x10).map(\.id), ["0"],
                       "a byte in the header is in the node's zone and no other")
        XCTAssertEqual(drawable.zones(containing: 0x48).map(\.id), ["0", "0#body"])
    }

    /// The inner two do not have to add up to the node: an FFSv1 file's tail
    /// is part of the node and belongs to neither.
    func testATailStaysInsideTheNodesOwnZone() {
        let node = UEFINode(
            id: NodeID([0, 1]),
            kind: .file,
            name: "Old file",
            header: 0x200..<0x218,
            body: 0x218..<0x2F8,
            tail: 0x2F8..<0x300
        )
        let zones = UEFIPresenter.zones(for: node)

        XCTAssertEqual(zones.zones[0].range, 0x200..<0x300, "the node covers its tail")
        XCTAssertEqual(zones.zones[1].range, 0x218..<0x2F8, "the body stops before it")
    }

    /// Padding, free space, anything the parser met without a header of its
    /// own: splitting it would draw the same range twice, so the node is the
    /// whole of what is published — and it is the focus.
    func testANodeWithoutAHeaderPublishesOneZone() {
        var node = UEFINode(kind: .freeSpace, name: "Free space", range: 0x2000..<0x4000)
        node.id = NodeID([4])
        let zones = UEFIPresenter.zones(for: node)

        XCTAssertEqual(zones.zones.count, 1)
        XCTAssertEqual(zones.zones[0].range, 0x2000..<0x4000)
        XCTAssertEqual(zones.focus, "4")
    }

    /// A node whose header is the whole of it — nothing to hold — is the same
    /// story the other way round.
    func testANodeWithoutABodyPublishesOneZone() {
        let node = UEFINode(
            id: NodeID([2]),
            kind: .padding,
            name: "",
            header: 0x100..<0x120,
            body: 0x120..<0x120
        )
        let zones = UEFIPresenter.zones(for: node)

        XCTAssertEqual(zones.zones.count, 1)
        XCTAssertEqual(zones.focus, "2")
    }

    /// An unnamed node's body still says what it is — the name is what the
    /// dump's menu and the minimap's legend show.
    func testAnUnnamedNodesBodyIsStillNamed() {
        let node = UEFINode(
            id: NodeID([3]),
            kind: .section,
            name: "",
            header: 0x10..<0x14,
            body: 0x14..<0x40
        )
        XCTAssertEqual(UEFIPresenter.zones(for: node).zones.map(\.name), ["", "Body"])
    }

    /// The trip back: a zone id is a node path, and the panel has to read it
    /// to know which row to bring to the front.
    func testZoneIdsRoundTripToNodePaths() {
        let id = NodeID([1, 2, 0])
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: UEFIPresenter.zoneID(for: id)), id)
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "0"), NodeID([0]))
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "3.1"), NodeID([3, 1]))
    }

    /// A part's zone leads to the node it is part of: the reader picked
    /// "VTF body" in the dump and the row they want is VTF. Any part, not only
    /// the one published today — the suffix is not what identifies the node.
    func testAPartsZoneIdLeadsToItsNode() {
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "1.2.0#body"), NodeID([1, 2, 0]))
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "1.2.0#header"), NodeID([1, 2, 0]))
        XCTAssertEqual(UEFIPresenter.nodeID(ofZone: "0#body"), NodeID([0]))
    }

    func testAZoneIdThatIsNotAPathIsRejected() {
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: ""))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "root"))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "1.x"))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "1..2"))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "#body"))
        XCTAssertNil(UEFIPresenter.nodeID(ofZone: "1.x#body"))
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

    // MARK: - The Intel image root

    /// The root of a whole SPI dump reads its counters off the descriptor's
    /// map — the block the reference parser prints under "Intel image". The
    /// default builder bytes are the map of a real Coffee Lake board.
    func testAnIntelImageReadsItsDescriptorCounters() {
        let built = TestUEFI.intelImage()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "Intel image")
        XCTAssertEqual(field(detail, "Kind"), "Intel image")
        XCTAssertEqual(field(detail, "Type"), "Intel")
        XCTAssertEqual(field(detail, "Header"), "—")
        XCTAssertEqual(field(detail, "Body"), "0x0 · 0x1000 bytes")
        XCTAssertEqual(field(detail, "Address"), "0xFFFF0000")
        XCTAssertEqual(field(detail, "Flash chips"), "1")
        XCTAssertEqual(field(detail, "Regions"), "1")
        XCTAssertEqual(field(detail, "Masters"), "3")
        XCTAssertEqual(field(detail, "PCH straps"), "90")
        XCTAssertEqual(field(detail, "PROC straps"), "3")
    }

    /// The three zero-based counters are stored minus one and the two strap
    /// counts are not, so a map holding raw values reads the counts back one
    /// higher than the chips/regions/masters fields and exactly equal to the
    /// strap fields.
    func testAnIntelImageReadsZeroBasedCountersBackPlusOne() {
        let built = TestUEFI.intelImage(
            flashMap0: 0x0204_0003,          // chips 0 → 1, regions 2 → 3
            flashMap1: 0x0700_0108,          // masters 1 → 2, PCH straps 7
            flashMap2: 0x8000                // PROC straps 0x80
        )
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Flash chips"), "1")
        XCTAssertEqual(field(detail, "Regions"), "3")
        XCTAssertEqual(field(detail, "Masters"), "2")
        XCTAssertEqual(field(detail, "PCH straps"), "7")
        XCTAssertEqual(field(detail, "PROC straps"), "128")
    }

    // MARK: - NVRAM stores and entries

    func testAVssStoreReadsItsFormatAndState() {
        let built = TestUEFI.nvramVssStore()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "VSS store")
        XCTAssertEqual(field(detail, "Format"), "0x5A")
        XCTAssertEqual(field(detail, "State"), "0x1")
        XCTAssertEqual(field(detail, "Reserved"), "0x0")
        XCTAssertEqual(field(detail, "Reserved1"), "0x0")
    }

    /// A VSS2 store keeps the same four fields a VSS store does, after its
    /// 16-byte store GUID — the detail reads them at the pushed-out offsets.
    func testAVss2StoreReadsItsFormatAndState() {
        let built = TestUEFI.nvramVss2Store()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "VSS2 store")
        XCTAssertEqual(field(detail, "Format"), "0x5A")
        XCTAssertEqual(field(detail, "State"), "0x1")
        XCTAssertEqual(field(detail, "Reserved"), "0x0")
        XCTAssertEqual(field(detail, "Reserved1"), "0x0")
    }

    /// The tree names a variable by its decoded name and leaves the vendor GUID
    /// off the node, so the detail has to read the GUID back — and the attribute
    /// bits read as their words, not just a number.
    func testAVssVariableNamesItsGuidAndAttributeWords() {
        let guid = EFIGUID(low: 0x1111_1111, high: 0x2222_2222)
        let built = TestUEFI.nvramVssVariable(attributes: 0x0000_0007, vendorGuid: guid)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "BootOrder")
        XCTAssertEqual(field(detail, "Kind"), "VSS entry")
        XCTAssertEqual(field(detail, "Type"), "Standard")
        XCTAssertEqual(field(detail, "Variable GUID"), guid.description)
        XCTAssertEqual(field(detail, "State"), "0x7F")
        XCTAssertEqual(field(detail, "Reserved"), "0x0")
        XCTAssertEqual(field(detail, "Attributes"), "0x7 (NonVolatile, BootService, Runtime)")
    }

    /// An FTW block's header CRC is not re-verified here — the parser needs the
    /// erase byte to blank the CRC and state fields, and it already reports a
    /// mismatch when it reads the block — so the value is shown without a
    /// validity claim the panel cannot back up.
    func testAFtwStoreShowsItsStateAndHeaderCrc() {
        let built = TestUEFI.nvramFtwStore(crc: 0xDEAD_BEEF)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "FTW store")
        XCTAssertEqual(field(detail, "State"), "0x1")
        XCTAssertEqual(field(detail, "Header CRC32"), "0xDEADBEEF")
    }

    /// A SysF store checks itself with a CRC32 over everything before its final
    /// four bytes, so the detail can vouch for it the same way.
    func testASysfStoreChecksItsCrc() {
        let built = TestUEFI.nvramSysfStore()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "SysF store")
        let stored = Checksums.crc32(Array(built.bytes.dropLast(4)))
        XCTAssertEqual(field(detail, "CRC32"), Checksums.text(stored, valid: true, digits: 8))
    }

    func testASysfStoreFlagsABadCrc() {
        let built = TestUEFI.nvramSysfStore(crc: 0xDEAD_BEEF)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "CRC32"), "0xDEADBEEF (Invalid)")
    }

    /// An EVSA store is an entry of its own whose checksum covers its 20-byte
    /// header, and the detail can recompute it from what is in the panel.
    func testAnEvsaStoreChecksItsHeaderChecksum() {
        let built = TestUEFI.nvramEvsaStore(attributes: 0x0000_0007)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "EVSA store")
        XCTAssertEqual(field(detail, "Attributes"), "0x7")
        XCTAssertEqual(field(detail, "Reserved"), "0x0")
        XCTAssertEqual(field(detail, "Checksum"), Checksums.text(built.bytes[1], valid: true))
    }

    /// A data variable's header carries the two id words its guid and name
    /// entries own, and an attributes word whose extended-header bit has a word
    /// of its own.
    func testAnEvsaDataVariableReadsItsIdsAttributesAndChecksum() {
        let built = TestUEFI.nvramEvsaDataEntry(attributes: 0x1000_0007, data: [0x01])
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(detail.title, "Lang")
        XCTAssertEqual(field(detail, "Kind"), "EVSA entry")
        XCTAssertEqual(field(detail, "VarId"), "0x2")
        XCTAssertEqual(field(detail, "GuidId"), "0x1")
        XCTAssertEqual(field(detail, "Attributes"), "0x10000007 (NonVolatile, BootService, Runtime, ExtendedHeader)")
        XCTAssertEqual(field(detail, "Checksum"), Checksums.text(built.bytes[1], valid: true))
    }

    /// A SLIC marker's OEM id and table id are stored ASCII, and the windows
    /// flag is the fixed word the parser accepts — shown as that word, never as
    /// the byte soup its little-endian layout would spell.
    func testAMarkerShowsItsOemAndWindowsFlag() {
        let built = TestUEFI.nvramSlicMarker()
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "SLIC data")
        XCTAssertEqual(field(detail, "Version"), "0x1")
        XCTAssertEqual(field(detail, "OEM ID"), "TESTCO")
        XCTAssertEqual(field(detail, "OEM table ID"), "TABLID01")
        XCTAssertEqual(field(detail, "Windows flag"), "WINDOWS")
        XCTAssertEqual(field(detail, "SLIC version"), "0x1")
    }

    func testAFirehoseFlashMapReadsItsCountAndReserved() {
        let built = TestUEFI.nvramFlashMapStore(numEntries: 3)
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "FlashMap store")
        XCTAssertEqual(field(detail, "Entries"), "3")
        XCTAssertEqual(field(detail, "Reserved"), "0x0")
    }

    /// A flash map entry carries its region's physical layout: the data and
    /// entry types first, then where the region lies.
    func testAFlashMapEntryReadsItsRegionLayout() {
        let built = TestUEFI.nvramFlashMapEntry(
            dataType: 0x0000,
            entryType: 0x0001,
            address: 0xFFF0_0000,
            size: 0x1000,
            offset: 0x40
        )
        let detail = UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)

        XCTAssertEqual(field(detail, "Kind"), "FlashMap entry")
        XCTAssertEqual(field(detail, "Data type"), "0x0")
        XCTAssertEqual(field(detail, "Entry type"), "0x1")
        XCTAssertEqual(field(detail, "Size"), "0x1000")
        XCTAssertEqual(field(detail, "Offset"), "0x40")
        XCTAssertEqual(field(detail, "Physical address"), "0xFFF00000")
    }
}
