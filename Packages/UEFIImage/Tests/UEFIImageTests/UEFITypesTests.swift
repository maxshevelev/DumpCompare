import XCTest
@testable import UEFIImage

/// The words the tree shows for a type and a subtype are UEFITool's, read from
/// the generated tables. These pin the transcription: a code that stops mapping
/// to the word UEFITool uses is a table that drifted from `common/types.cpp`.
final class UEFITypesLookupsTests: XCTestCase {
    func testTypeNameReadsTheItemTypesTable() {
        XCTAssertEqual(UEFITypes.typeName(60), "Root")
        XCTAssertEqual(UEFITypes.typeName(61), "Capsule")
        XCTAssertEqual(UEFITypes.typeName(63), "Region")
        XCTAssertEqual(UEFITypes.typeName(65), "Volume")
        XCTAssertEqual(UEFITypes.typeName(87), "Intel microcode")
    }

    /// A code the table does not know keeps its number — the honest answer for a
    /// vendor type nobody has named.
    func testAnUnknownTypeNameKeepsItsNumber() {
        XCTAssertEqual(UEFITypes.typeName(59), "Unknown 3Bh")
    }

    func testRegionNameReadsTheFlashDescriptorTable() {
        XCTAssertEqual(UEFITypes.regionName(0), "Descriptor")
        XCTAssertEqual(UEFITypes.regionName(1), "BIOS")
        XCTAssertEqual(UEFITypes.regionName(7), "Microcode")
        XCTAssertEqual(UEFITypes.regionName(18), "PSP file")
    }

    func testAnUnknownRegionNameKeepsItsNumber() {
        XCTAssertEqual(UEFITypes.regionName(99), "Unknown 63h")
    }

    func testSubtypeNameAnswersPerType() {
        XCTAssertEqual(UEFITypes.subtypeName(type: 61, 100), "Aptio signed")
        XCTAssertEqual(UEFITypes.subtypeName(type: 61, 102), "UEFI 2.0")
        XCTAssertEqual(UEFITypes.subtypeName(type: 62, 90), "Intel")
        XCTAssertEqual(UEFITypes.subtypeName(type: 65, 111), "FFSv2")
        XCTAssertEqual(UEFITypes.subtypeName(type: 65, 113), "NVRAM")
        XCTAssertEqual(UEFITypes.subtypeName(type: 64, 120), "Empty (00h)")
        XCTAssertEqual(UEFITypes.subtypeName(type: 64, 122), "Non-empty")
    }

    /// A region's subtype is answered by the region table, folded in under the
    /// `Region` item type — the same delegation the C++ makes.
    func testARegionSubtypeReadsTheRegionTable() {
        XCTAssertEqual(UEFITypes.subtypeName(type: 63, 1), "BIOS")
        XCTAssertEqual(UEFITypes.subtypeName(type: 63, 7), "Microcode")
    }

    /// `File` and `Section` delegate to the FFS and section type tables, which
    /// live in other files and are named at run time — so the generated table
    /// has no answer for them, and the caller supplies one.
    func testFileAndSectionSubtypesHaveNoGeneratedAnswer() {
        XCTAssertNil(UEFITypes.subtypeName(type: 66, 7))
        XCTAssertNil(UEFITypes.subtypeName(type: 67, 0x19))
    }

    func testAnUnknownTypeHasNoSubtype() {
        XCTAssertNil(UEFITypes.subtypeName(type: 99, 0))
    }
}

/// The bridge from a node in this tree to UEFITool's classification. The mapping
/// reads what the parser stored, so a node classifies the same way on every
/// parse — these pin that mapping.
final class UEFIItemClassificationTests: XCTestCase {
    private func node(
        _ kind: UEFINodeKind,
        subtype: UInt8? = nil,
        name: String = "",
        guid: EFIGUID? = nil,
        isErased: Bool = false
    ) -> UEFINode {
        UEFINode(
            kind: kind,
            subtype: subtype,
            name: name,
            guid: guid,
            header: 0..<0,
            body: 0..<0x100,
            isErased: isErased
        )
    }

    func testEachKindReadsAsItsItemTypesCode() {
        XCTAssertEqual(node(.capsule).uefiItemType, UEFITypes.Item.capsule.rawValue)
        XCTAssertEqual(node(.flashDescriptor).uefiItemType, UEFITypes.Item.region.rawValue)
        XCTAssertEqual(node(.region).uefiItemType, UEFITypes.Item.region.rawValue)
        XCTAssertEqual(node(.volume).uefiItemType, UEFITypes.Item.volume.rawValue)
        XCTAssertEqual(node(.file).uefiItemType, UEFITypes.Item.file.rawValue)
        XCTAssertEqual(node(.section).uefiItemType, UEFITypes.Item.section.rawValue)
        XCTAssertEqual(node(.microcode).uefiItemType, UEFITypes.Item.intelMicrocode.rawValue)
        XCTAssertEqual(node(.padding).uefiItemType, UEFITypes.Item.padding.rawValue)
        XCTAssertEqual(node(.freeSpace).uefiItemType, UEFITypes.Item.freeSpace.rawValue)
        // Unclaimed data reads as a file, the way a raw region does.
        XCTAssertEqual(node(.nonUEFIData).uefiItemType, UEFITypes.Item.file.rawValue)
    }

    func testACapsuleIsNamedByItsGuid() {
        let aptioSigned = EFIGUID("4A3CA68B-7723-48FB-803D-578CC1FEC44D")
        let aptioUnsigned = EFIGUID("14EEBB90-890A-43DB-AED1-5D3C4588A418")
        let toshiba = EFIGUID("3BE07062-1D51-45D2-832B-F093257ED461")
        let plain = EFIGUID("DFC08A91-C8CA-4DB9-8F2F-8E6F6A32B65A")

        XCTAssertEqual(node(.capsule, guid: aptioSigned).uefiItemSubtype, UEFITypes.Sub.aptioSignedCapsule)
        XCTAssertEqual(node(.capsule, guid: aptioUnsigned).uefiItemSubtype, UEFITypes.Sub.aptioUnsignedCapsule)
        XCTAssertEqual(node(.capsule, guid: toshiba).uefiItemSubtype, UEFITypes.Sub.toshibaCapsule)
        // Everything else that is a capsule reads as a plain UEFI 2.0 one.
        XCTAssertEqual(node(.capsule, guid: plain).uefiItemSubtype, UEFITypes.Sub.uefiCapsule)
        // No GUID, no capsule to name.
        XCTAssertNil(node(.capsule).uefiItemSubtype)
    }

    func testARegionKeepsTheDescriptorRegionType() {
        XCTAssertEqual(node(.region, subtype: 7).uefiItemSubtype, 7)
        // The descriptor itself is the descriptor region.
        XCTAssertEqual(node(.flashDescriptor).uefiItemSubtype, UEFITypes.Sub.descriptorRegion)
    }

    func testAVolumeIsNamedByItsFileSystemGuid() {
        XCTAssertEqual(node(.volume, guid: KnownGUIDs.ffsV2).uefiItemSubtype, UEFITypes.Sub.ffs2Volume)
        XCTAssertEqual(node(.volume, guid: KnownGUIDs.ffsV3).uefiItemSubtype, UEFITypes.Sub.ffs3Volume)
        let nvram = EFIGUID("FFF12B8D-7696-4C8B-A985-2747075B4F50")
        XCTAssertEqual(node(.volume, guid: nvram).uefiItemSubtype, UEFITypes.Sub.nvramVolume)
        let apple = EFIGUID("153D2197-29BD-44DC-AC59-887F70E41A6B")
        XCTAssertEqual(node(.volume, guid: apple).uefiItemSubtype, UEFITypes.Sub.appleMicrocodeVolume)
        // A file system nobody documented is an unknown volume.
        let unknown = EFIGUID("11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(node(.volume, guid: unknown).uefiItemSubtype, UEFITypes.Sub.unknownVolume)
        XCTAssertNil(node(.volume).guid)
        XCTAssertEqual(node(.volume).uefiItemSubtype, UEFITypes.Sub.unknownVolume)
    }

    func testAFileAndSectionKeepTheirTypeByte() {
        XCTAssertEqual(node(.file, subtype: 7).uefiItemSubtype, 7)
        XCTAssertEqual(node(.section, subtype: 0x19).uefiItemSubtype, 0x19)
    }

    func testAMicrocodeHasNoSubtype() {
        XCTAssertNil(node(.microcode).uefiItemSubtype)
    }

    /// The parser says only whether a run is all the erase byte; an erased run
    /// reads as the polarity's byte (0xFF, the default) and a live one as data.
    func testPaddingIsNamedByWhetherItIsErased() {
        XCTAssertEqual(node(.padding, isErased: true).uefiItemSubtype, UEFITypes.Sub.onePadding)
        XCTAssertEqual(node(.padding, isErased: false).uefiItemSubtype, UEFITypes.Sub.dataPadding)
    }

    func testFreeSpaceAndUnclaimedDataHaveNoSubtype() {
        XCTAssertNil(node(.freeSpace).uefiItemSubtype)
        XCTAssertNil(node(.nonUEFIData).uefiItemSubtype)
    }
}

/// The catalogue the tree names its GUIDs by: a parsed `common/guids.csv`, and
/// the empty one the tree starts with before a download lands.
final class GuidsCatalogueTests: XCTestCase {
    private let ffsV2 = "8C8CE578-8A3D-4F1C-9935-896185C32DD3"

    func testItParsesUuidNameLines() {
        let data = Data("\(ffsV2),FFSv2\n5473C07A-3DCB-4DCA-BD6F-1E9689E7349A,FFSv3\n".utf8)
        let catalogue = GuidsCatalogue.parse(data)

        XCTAssertEqual(catalogue.name(of: KnownGUIDs.guid(ffsV2)), "FFSv2")
        XCTAssertEqual(catalogue.name(of: KnownGUIDs.guid("5473C07A-3DCB-4DCA-BD6F-1E9689E7349A")), "FFSv3")
        XCTAssertEqual(catalogue.names.count, 2)
    }

    /// A blank line and a line with no name are skipped, not an error — a
    /// trailing blank line is not worth failing a catalogue over.
    func testBlankAndNamelessLinesAreSkipped() {
        let data = Data("\(ffsV2),FFSv2\n\n\(ffsV2),\nnot-a-guid,Name\n".utf8)
        let catalogue = GuidsCatalogue.parse(data)

        XCTAssertEqual(catalogue.names.count, 1)
        XCTAssertEqual(catalogue.name(of: KnownGUIDs.guid(ffsV2)), "FFSv2")
    }

    /// The name is everything after the first comma, so a name that itself
    /// contains a comma survives.
    func testANameWithACommaSurvives() {
        let data = Data("\(ffsV2),FFS, v2\n".utf8)
        let catalogue = GuidsCatalogue.parse(data)

        XCTAssertEqual(catalogue.name(of: KnownGUIDs.guid(ffsV2)), "FFS, v2")
    }

    /// The file is CRLF on Windows, where much of it is edited.
    func testCrlfLineEndingsAreAccepted() {
        let data = Data("\(ffsV2),FFSv2\r\n".utf8)
        let catalogue = GuidsCatalogue.parse(data)

        XCTAssertEqual(catalogue.name(of: KnownGUIDs.guid(ffsV2)), "FFSv2")
    }

    func testAGuidWithNoNameHasNoAnswer() {
        let catalogue = GuidsCatalogue.parse(Data("\(ffsV2),FFSv2\n".utf8))
        let absent = KnownGUIDs.guid("11111111-2222-3333-4444-555555555555")
        XCTAssertNil(catalogue.name(of: absent))
    }

    /// The tree starts with this: no names, so a GUID node shows the GUID itself
    /// until a download fills the catalogue in.
    func testTheEmptyCatalogueHasNoNames() {
        XCTAssertTrue(GuidsCatalogue.empty.names.isEmpty)
        XCTAssertNil(GuidsCatalogue.empty.name(of: KnownGUIDs.guid(ffsV2)))
    }
}
