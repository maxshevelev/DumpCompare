import XCTest
@testable import UEFIImage

/// Reading the NVRAM volume body stores of Apple and Phoenix firmware (§9):
/// Apple SysF/Diag, the Phoenix SCT flash map, EVSA, CMDB, and the Microsoft
/// SLIC records. Each is its own recognizer, tried in the fixed order the
/// reference parser uses. Where a VSS store is *cut* at the body's end when it
/// claims too much, these stores have fixed-size bodies in the reference, so a
/// store that claims more of the body than there is is *refused* and the bytes
/// become padding.
final class NvramOtherStoreTests: XCTestCase {
    private func parse(_ bytes: [UInt8]) -> UEFIImage {
        UEFIParser.parse(bytes)
    }

    private func guid(_ string: String) -> EFIGUID {
        // Every string here is a well-formed GUID; a failure is a test bug.
        EFIGUID(string)!
    }

    // MARK: - Apple SysF / Diag

    /// A SysF store is led by an `Fsys`/`Gaid` signature and a 16-bit size,
    /// and its variables are an ASCII name, a data length and the data.
    func testASysfStoreExpandsToItsVariablesAndFreeSpace() {
        let store = TestNVRAM.sysfStore(variables: [
            TestNVRAM.sysfVariable(name: "BootOrder", data: [0x01, 0x02]),
        ])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let volume = parsed.roots[0]

        XCTAssertEqual(volume.children.map(\.kind), [.sysFStore])
        let sysf = volume.children[0]
        XCTAssertEqual(sysf.name, "Apple SysF store")
        XCTAssertEqual(sysf.header, 0x48..<0x53)
        XCTAssertEqual(sysf.body, 0x53..<0x79)

        XCTAssertEqual(sysf.children.map(\.kind), [.sysFEntry, .sysFEntry, .freeSpace])
        let variable = sysf.children[0]
        XCTAssertEqual(variable.subtype, UEFITypes.Sub.normalSysFEntry)
        XCTAssertEqual(variable.name, "BootOrder")
        XCTAssertEqual(variable.header, 0x53..<0x5F)
        XCTAssertEqual(variable.body, 0x5F..<0x61)

        // A chunk named "EOF" ends the store: four bytes of header and no data.
        let eof = sysf.children[1]
        XCTAssertEqual(eof.subtype, UEFITypes.Sub.normalSysFEntry)
        XCTAssertEqual(eof.name, "EOF")
        XCTAssertEqual(eof.header, 0x61..<0x65)
        XCTAssertEqual(eof.body, 0x65..<0x65)

        // The zeroes before the CRC32 are free space the store can grow into.
        XCTAssertEqual(sysf.children[2].range, 0x65..<0x79)
    }

    /// The signature that names an Apple Diag store, not an Apple store, and
    /// a variable whose invalid flag is set are invalid entries.
    func testADiagStoreAndAnInvalidVariableAreRead() {
        let store = TestNVRAM.sysfStore(
            variables: [TestNVRAM.sysfVariable(name: "BootOrder", invalid: true)],
            signature: NVRAM.appleDiagSignature
        )
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let sysf = parsed.roots[0].children[0]

        XCTAssertEqual(sysf.name, "Apple Diag store")
        let variable = sysf.children[0]
        XCTAssertEqual(variable.subtype, UEFITypes.Sub.invalidSysFEntry)
        XCTAssertEqual(variable.name, "Invalid")
    }

    /// A SysF store that declares more than the body holds is refused, not cut:
    /// the reference parser reads the store's fixed-size body whole.
    func testASysfStoreThatOverrunsItsBodyIsRefused() {
        let store = TestNVRAM.sysfStore(
            variables: [TestNVRAM.sysfVariable(name: "BootOrder")],
            size: 0x200
        )
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))

        XCTAssertEqual(parsed.roots[0].children.map(\.kind), [.padding])
    }

    // MARK: - Phoenix SCT flash map

    /// A flash map is led by the `_FLASH_MAP` signature and holds one 36-byte
    /// entry per region; each entry's data type picks its subtype.
    func testAPhoenixFlashMapStoreExpandsToItsEntries() {
        let entryA = TestNVRAM.flashMapEntry(
            guid: guid("11111111-2222-3333-4444-555555555555"),
            dataType: 0x0000  // volume
        )
        let entryB = TestNVRAM.flashMapEntry(
            guid: guid("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            dataType: 0x0001  // data block
        )
        let entryC = TestNVRAM.flashMapEntry(
            guid: guid("FEDCBA98-7654-3210-AAAA-BBBBBBBBBBBB"),
            dataType: 0x0002  // unknown
        )
        let parsed = parse(TestNVRAM.nvramVolume(stores: [
            TestNVRAM.flashMapStore(entries: [entryA, entryB, entryC]),
        ]))
        let volume = parsed.roots[0]

        XCTAssertEqual(volume.children.map(\.kind), [.flashMapStore])
        let map = volume.children[0]
        XCTAssertEqual(map.name, "Phoenix SCT flash map")
        XCTAssertEqual(map.header, 0x48..<0x58)
        XCTAssertEqual(map.body, 0x58..<0xC4)

        XCTAssertEqual(map.children.map(\.kind), [.flashMapEntry, .flashMapEntry, .flashMapEntry])
        XCTAssertEqual(map.children.map(\.subtype), [
            UEFITypes.Sub.volumeFlashMapEntry,
            UEFITypes.Sub.dataFlashMapEntry,
            UEFITypes.Sub.unknownFlashMapEntry,
        ])

        // An entry carries its region GUID as identity.
        XCTAssertEqual(map.children[0].name, guid("11111111-2222-3333-4444-555555555555").description)
        XCTAssertEqual(map.children[0].guid, guid("11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(map.children[1].guid, guid("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        XCTAssertEqual(map.children[2].guid, guid("FEDCBA98-7654-3210-AAAA-BBBBBBBBBBBB"))
        XCTAssertEqual(map.children[0].header, 0x58..<0x7C)
        XCTAssertEqual(map.children[1].header, 0x7C..<0xA0)
        XCTAssertEqual(map.children[2].header, 0xA0..<0xC4)
        XCTAssertEqual(map.children[0].body, 0x7C..<0x7C)
    }

    /// A flash map whose entry count reaches past the body is refused.
    func testAPhoenixFlashMapStoreThatOverrunsItsBodyIsRefused() {
        let store = TestNVRAM.flashMapStore(
            entries: [TestNVRAM.flashMapEntry(guid: guid("11111111-2222-3333-4444-555555555555"), dataType: 0)],
            entryCount: 4
        )
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))

        XCTAssertEqual(parsed.roots[0].children.map(\.kind), [.padding])
    }

    // MARK: - Phoenix EVSA

    /// An EVSA store pairs variable ids with names and GUIDs through separate
    /// entries, and a data entry that resolves both ids is named by the name
    /// entry.
    func testAnEvsaStoreResolvesItsVariableNames() {
        let g1 = guid("11111111-2222-3333-4444-555555555555")
        let store = TestNVRAM.evsaStore(
            entries: [
                TestNVRAM.evsaGuidEntry(guid: g1, id: 1),
                TestNVRAM.evsaNameEntry(name: "Lang", id: 2),
                TestNVRAM.evsaDataEntry(guidId: 1, varId: 2, data: [0x01, 0x02, 0x03, 0x04]),
            ],
            freeSpace: 0
        )
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let volume = parsed.roots[0]

        XCTAssertEqual(volume.children.map(\.kind), [.evsaStore])
        let evsa = volume.children[0]
        XCTAssertEqual(evsa.name, "Phoenix EVSA store")
        XCTAssertEqual(evsa.header, 0x48..<0x5C)
        XCTAssertEqual(evsa.body, 0x5C..<0x92)

        XCTAssertEqual(evsa.children.map(\.kind), [.evsaEntry, .evsaEntry, .evsaEntry])
        XCTAssertEqual(evsa.children.map(\.subtype), [
            UEFITypes.Sub.guidEvsaEntry,
            UEFITypes.Sub.nameEvsaEntry,
            UEFITypes.Sub.dataEvsaEntry,
        ])

        // A GUID entry carries the GUID under its id.
        let guidEntry = evsa.children[0]
        XCTAssertEqual(guidEntry.name, g1.description)
        XCTAssertEqual(guidEntry.guid, g1)
        XCTAssertEqual(guidEntry.header, 0x5C..<0x62)
        XCTAssertEqual(guidEntry.body, 0x62..<0x72)

        // The name entry and the data variable that resolves it are both named.
        XCTAssertEqual(evsa.children[1].name, "Lang")
        XCTAssertEqual(evsa.children[1].header, 0x72..<0x78)
        XCTAssertEqual(evsa.children[1].body, 0x78..<0x82)
        let variable = evsa.children[2]
        XCTAssertEqual(variable.name, "Lang")
        XCTAssertEqual(variable.header, 0x82..<0x8E)
        XCTAssertEqual(variable.body, 0x8E..<0x92)
        XCTAssertNil(variable.guid)
    }

    /// A data entry whose type marks it invalid, and one whose ids resolve to
    /// nothing, are invalid.
    func testAnEvsaStoreMarksUnresolvedDataVariablesInvalid() {
        let g1 = guid("11111111-2222-3333-4444-555555555555")
        let store = TestNVRAM.evsaStore(
            entries: [
                TestNVRAM.evsaGuidEntry(guid: g1, id: 1),
                TestNVRAM.evsaNameEntry(name: "Lang", id: 2),
                TestNVRAM.evsaDataEntry(type: NVRAM.evsaEntryTypeDataInvalid,
                                        guidId: 1, varId: 2, data: [0x01]),
                TestNVRAM.evsaDataEntry(guidId: 9, varId: 9, data: [0x02]),
            ],
            freeSpace: 0
        )
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let variables = parsed.roots[0].children[0].children

        XCTAssertEqual(variables.count, 4)
        XCTAssertEqual(variables[2].subtype, UEFITypes.Sub.invalidEvsaEntry)
        XCTAssertEqual(variables[2].name, "Invalid")
        XCTAssertEqual(variables[3].subtype, UEFITypes.Sub.invalidEvsaEntry)
        XCTAssertEqual(variables[3].name, "Invalid")
    }

    /// An EVSA store's free space is where its entries end: erased, and so not
    /// padding.
    func testAnEvsaStoresFreeSpaceAfterItsEntriesIsErased() {
        let store = TestNVRAM.evsaStore(entries: [
            TestNVRAM.evsaGuidEntry(
                guid: guid("11111111-2222-3333-4444-555555555555"),
                id: 1
            ),
        ])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let children = parsed.roots[0].children[0].children

        XCTAssertEqual(children.map(\.kind), [.evsaEntry, .freeSpace])
        XCTAssertEqual(children[1].range, 0x72..<0x82)
        XCTAssertTrue(children[1].isErased)
    }

    /// An EVSA store whose declared size overruns the body is refused, not cut:
    /// its body is a fixed size in the reference parser.
    func testAnEvsaStoreThatOverrunsItsBodyIsRefused() {
        let store = TestNVRAM.evsaStore(size: 0x400)
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))

        XCTAssertEqual(parsed.roots[0].children.map(\.kind), [.padding])
    }

    // MARK: - Phoenix CMDB, Microsoft SLIC

    /// A CMDB store is a leaf: the parser reads its header and keeps the rest
    /// whole.
    func testACmdbStoreIsKeptWhole() {
        let parsed = parse(TestNVRAM.nvramVolume(stores: [TestNVRAM.cmdbStore()]))
        let volume = parsed.roots[0]

        XCTAssertEqual(volume.children.map(\.kind), [.cmdbStore])
        let cmdb = volume.children[0]
        XCTAssertEqual(cmdb.name, "Phoenix CMDB store")
        XCTAssertEqual(cmdb.header, 0x48..<0x58)
        XCTAssertEqual(cmdb.body, 0x58..<0x148)
        XCTAssertTrue(cmdb.children.isEmpty)
    }

    /// A SLIC public key is a fixed 0x9C-byte activation record, a whole leaf.
    func testASlicPublicKeyIsKeptWhole() {
        let parsed = parse(TestNVRAM.nvramVolume(stores: [TestNVRAM.slicPubkey()]))
        let volume = parsed.roots[0]

        XCTAssertEqual(volume.children.map(\.kind), [.slicData])
        let pubkey = volume.children[0]
        XCTAssertEqual(pubkey.subtype, UEFITypes.Sub.pubkeySlicData)
        XCTAssertEqual(pubkey.name, "SLIC pubkey")
        XCTAssertEqual(pubkey.range, 0x48..<0xE4)
        XCTAssertEqual(pubkey.body, 0xE4..<0xE4)
    }

    /// A SLIC marker is a fixed 0xB6-byte activation record, a whole leaf.
    func testASlicMarkerIsKeptWhole() {
        let parsed = parse(TestNVRAM.nvramVolume(stores: [TestNVRAM.slicMarker()]))
        let volume = parsed.roots[0]

        XCTAssertEqual(volume.children.map(\.kind), [.slicData])
        let marker = volume.children[0]
        XCTAssertEqual(marker.subtype, UEFITypes.Sub.markerSlicData)
        XCTAssertEqual(marker.name, "SLIC marker")
        XCTAssertEqual(marker.range, 0x48..<0xFE)
    }
}
