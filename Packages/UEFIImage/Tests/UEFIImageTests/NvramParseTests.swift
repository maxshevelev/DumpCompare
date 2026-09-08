import XCTest
@testable import UEFIImage

/// Reading an NVRAM volume body as a run of stores (§9), starting with the VSS
/// store: the store node, its variables, and the free space after them.
final class NvramParseTests: XCTestCase {
    private func parse(_ bytes: [UInt8]) -> UEFIImage {
        UEFIParser.parse(bytes)
    }

    func testAnNvramVolumeExpandsToItsStores() {
        let store = TestNVRAM.vssStore(variables: [TestNVRAM.vssVariable(name: "BootOrder")])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let volume = parsed.roots[0].children[0]

        XCTAssertEqual(volume.kind, .volume)
        XCTAssertEqual(volume.children.map(\.kind), [.vssStore])
        let vss = volume.children[0]
        XCTAssertEqual(vss.name, "VSS store")
        XCTAssertEqual(vss.header, 0x48..<0x58)
        XCTAssertEqual(vss.body, 0x58..<0x9E)
        XCTAssertEqual(vss.range, 0x48..<0x9E)
    }

    func testAVssVariableIsNamedByItsDecodedName() {
        let store = TestNVRAM.vssStore(variables: [TestNVRAM.vssVariable(name: "BootOrder")])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let entry = parsed.roots[0].children[0].children[0].children[0]

        XCTAssertEqual(entry.kind, .vssEntry)
        XCTAssertEqual(entry.subtype, UEFITypes.Sub.standardVssEntry)
        XCTAssertEqual(entry.name, "BootOrder")
        XCTAssertEqual(entry.header, 0x58..<0x78)
        XCTAssertEqual(entry.body, 0x78..<0x8E)
    }

    func testTheFreeSpaceAfterTheVariablesIsFound() {
        let store = TestNVRAM.vssStore(variables: [TestNVRAM.vssVariable(name: "BootOrder")])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let children = parsed.roots[0].children[0].children[0].children

        XCTAssertEqual(children.map(\.kind), [.vssEntry, .freeSpace])
        XCTAssertEqual(children[1].range, 0x8E..<0x9E)
        XCTAssertTrue(children[1].isErased)
    }

    func testADeletedVariableIsInvalid() {
        let deleted = TestNVRAM.vssVariable(name: "BootOrder", state: 0xFD)
        let store = TestNVRAM.vssStore(variables: [deleted])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let entry = parsed.roots[0].children[0].children[0].children[0]

        XCTAssertEqual(entry.subtype, UEFITypes.Sub.invalidVssEntry)
        XCTAssertEqual(entry.name, "Invalid")
    }

    func testTwoVariablesAreBothFound() {
        let store = TestNVRAM.vssStore(variables: [
            TestNVRAM.vssVariable(name: "BootOrder"),
            TestNVRAM.vssVariable(name: "SetupMode"),
        ])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let entries = parsed.roots[0].children[0].children[0].children

        XCTAssertEqual(entries.map(\.kind), [.vssEntry, .vssEntry, .freeSpace])
        XCTAssertEqual(entries[0].name, "BootOrder")
        XCTAssertEqual(entries[1].name, "SetupMode")
    }

    /// A store whose size field is the "no size" marker (0xFFFFFFFF) is not a
    /// store at all: the reference parser refuses it, so the body is padding.
    func testANoSizeMarkerIsNotAStore() {
        let store = TestNVRAM.vssStore(
            variables: [TestNVRAM.vssVariable(name: "BootOrder")],
            size: 0xFFFF_FFFF
        )
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        XCTAssertEqual(parsed.roots[0].children[0].children.map(\.kind), [.padding])
    }

    /// A store whose size field overruns the body is cut at the body's end, not
    /// believed past it.
    func testAStoreSizeThatOverrunsTheBodyIsCut() {
        // The store claims 0x100 bytes, but the volume body is only as long as
        // the store's real content: the store is cut at the body's end.
        let store = TestNVRAM.vssStore(
            variables: [TestNVRAM.vssVariable(name: "BootOrder")],
            size: 0x100
        )
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let vss = parsed.roots[0].children[0].children[0]

        XCTAssertEqual(vss.kind, .vssStore)
        // Cut at the body's end, not believed to 0x100.
        XCTAssertEqual(vss.range, 0x48..<0x9E)
    }

    /// An all-erased NVRAM volume has no stores: its body is one run of free
    /// space, and it is not an unknown file system.
    func testAnErasedNvramVolumeIsFreeSpace() {
        let parsed = parse(TestNVRAM.nvramVolume(stores: [], length: 0x400))

        XCTAssertEqual(parsed.roots[0].children[0].children.map(\.kind), [.freeSpace])
        XCTAssertEqual(parsed.roots[0].children[0].children.map(\.range), [0x48..<0x400])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// A store that sits after a long erased run is still found: the walk jumps
    /// the free space whole (a run of the erase byte cannot start a store)
    /// instead of probing its recognisers byte by byte, and lands on the store.
    func testAStoreAfterLongFreeSpaceIsStillFound() {
        let vss = TestNVRAM.vssStore(variables: [TestNVRAM.vssVariable(name: "First")])
        let vss2 = TestNVRAM.vss2Store(variables: [TestNVRAM.vss2Variable(name: "Second")])
        let gap: UInt64 = 0x2000
        var body = BinaryWriter()
        body.raw(vss)
        let vssEnd = 0x48 + UInt64(vss.count)
        body.fill(gap, with: 0xFF)
        body.raw(vss2)
        let volumeBytes = TestImage.volume(
            fileSystem: TestNVRAM.nvramVolumeGUID,
            length: 0x48 + UInt64(body.count),
            files: [],
            trailing: body.bytes
        )

        let parsed = parse(volumeBytes)
        let volume = parsed.roots[0].children[0]
        XCTAssertEqual(volume.children.map(\.kind), [.vssStore, .freeSpace, .vss2Store])
        XCTAssertEqual(volume.children[1].range, vssEnd..<(vssEnd + gap))
        XCTAssertTrue(volume.children[1].isErased)
        XCTAssertEqual(volume.children[2].range.lowerBound, vssEnd + gap)
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// A VSS2 store is led by a 16-byte store GUID and is 28 bytes of header;
    /// its variables are 4-byte aligned, so the padding after one is a node of
    /// its own.
    func testAVss2StoreExpandsToItsVariables() {
        let store = TestNVRAM.vss2Store(variables: [TestNVRAM.vss2Variable(name: "BootOrder")])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let volume = parsed.roots[0].children[0]

        XCTAssertEqual(volume.children.map(\.kind), [.vss2Store])
        let vss2 = volume.children[0]
        XCTAssertEqual(vss2.name, "VSS2 store")
        XCTAssertEqual(vss2.header, 0x48..<0x64)
        XCTAssertEqual(vss2.body, 0x64..<0xAC)
        XCTAssertEqual(vss2.range, 0x48..<0xAC)
    }

    /// A VSS2 variable's header includes its name; the data is the body.
    func testAVss2VariableIsNamedByItsDecodedName() {
        let store = TestNVRAM.vss2Store(variables: [TestNVRAM.vss2Variable(name: "BootOrder")])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let entry = parsed.roots[0].children[0].children[0].children[0]

        XCTAssertEqual(entry.kind, .vssEntry)
        XCTAssertEqual(entry.subtype, UEFITypes.Sub.standardVssEntry)
        XCTAssertEqual(entry.name, "BootOrder")
        XCTAssertEqual(entry.header, 0x64..<0x98)
        XCTAssertEqual(entry.body, 0x98..<0x9A)
    }

    /// The 4-byte alignment padding after a VSS2 variable is a node of its
    /// own, and the free space after it is erased.
    func testAVss2AlignmentPaddingAndFreeSpaceAreFound() {
        let store = TestNVRAM.vss2Store(variables: [TestNVRAM.vss2Variable(name: "BootOrder")])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let children = parsed.roots[0].children[0].children[0].children

        XCTAssertEqual(children.map(\.kind), [.vssEntry, .padding, .freeSpace])
        XCTAssertEqual(children[1].range, 0x9A..<0x9C)
        XCTAssertEqual(children[2].range, 0x9C..<0xAC)
        XCTAssertTrue(children[2].isErased)
    }

    /// A VSS2 variable whose state is not one of the valid ones is invalid.
    func testADeletedVss2VariableIsInvalid() {
        let deleted = TestNVRAM.vss2Variable(name: "BootOrder", state: 0xFD)
        let store = TestNVRAM.vss2Store(variables: [deleted])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let entry = parsed.roots[0].children[0].children[0].children[0]

        XCTAssertEqual(entry.subtype, UEFITypes.Sub.invalidVssEntry)
        XCTAssertEqual(entry.name, "Invalid")
    }

    /// An FTW working block is led by a signature GUID and carries a header
    /// CRC32; a matching CRC is not a complaint.
    func testAnFtwStoreWithAValidCrcIsFound() {
        let store = TestNVRAM.ftwStore(writeQueue: [0x01, 0x02, 0x03, 0x04])
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))
        let ftw = parsed.roots[0].children[0].children[0]

        XCTAssertEqual(ftw.kind, .ftwStore)
        XCTAssertEqual(ftw.name, "FTW store")
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// An FTW working block whose header CRC no longer matches is damaged.
    func testAnFtwStoreWithABadCrcIsReported() {
        let store = TestNVRAM.ftwStore(writeQueue: [0x01, 0x02, 0x03, 0x04], crc: 0xDEAD_BEEF)
        let parsed = parse(TestNVRAM.nvramVolume(stores: [store]))

        XCTAssertEqual(parsed.roots[0].children[0].children.map(\.kind), [.ftwStore])
        guard case .checksumMismatch(.nvramStore, stored: let stored, computed: let computed) = parsed.diagnostics[0].kind else {
            XCTFail("Expected a checksumMismatch diagnostic")
            return
        }
        XCTAssertEqual(stored, 0xDEAD_BEEF)
        XCTAssertNotEqual(stored, computed)
    }

    /// An Insyde FDC store wraps an NVRAM body of its own, and a `$VSS` store
    /// inside it that says "no size" means the whole FDC body — so the store is
    /// cut at the FDC's end, not refused.
    func testAnFdcStoreRecursesIntoItsBodyWithTheSizeOverride() {
        let inner = TestNVRAM.vssStore(
            variables: [TestNVRAM.vssVariable(name: "BootOrder")],
            size: 0xFFFF_FFFF
        )
        let parsed = parse(TestNVRAM.nvramVolume(stores: [TestNVRAM.fdcStore(stores: [inner])]))
        let volume = parsed.roots[0].children[0]

        XCTAssertEqual(volume.children.map(\.kind), [.fdcStore])
        let fdc = volume.children[0]
        XCTAssertEqual(fdc.name, "Insyde FDC store")
        XCTAssertEqual(fdc.header, 0x48..<0x98)
        XCTAssertEqual(fdc.body, 0x98..<volume.body.upperBound)

        XCTAssertEqual(fdc.children.map(\.kind), [.vssStore])
        let vss = fdc.children[0]
        XCTAssertEqual(vss.name, "VSS store")
        // The size marker resolved to the FDC body's length: the store spans it.
        XCTAssertEqual(vss.range, fdc.body)
        XCTAssertEqual(vss.children.map(\.kind), [.vssEntry, .freeSpace])
        XCTAssertEqual(vss.children[0].name, "BootOrder")
    }

    /// A firmware volume nested whole inside an NVRAM body is handed to the
    /// volume parser, which reads it as the volume it is — not as padding.
    func testAFirmwareVolumeNestedInsideNvramIsParsedByTheVolumeParser() {
        let inner = TestImage.volume(length: 0x200)
        let parsed = parse(TestNVRAM.nvramVolume(stores: [inner]))
        let volume = parsed.roots[0].children[0]

        XCTAssertEqual(volume.children.map(\.kind), [.volume])
        let nested = volume.children[0]
        XCTAssertEqual(nested.name, "FFSv2")
        XCTAssertEqual(nested.range, volume.body)
        XCTAssertEqual(nested.children.map(\.kind), [.freeSpace])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// An Intel microcode image sitting in an NVRAM body is handed to the
    /// microcode parser, which names it and keeps its whole image whole.
    func testMicrocodeInsideNvramIsParsedByTheMicrocodeParser() {
        let parsed = parse(TestNVRAM.nvramVolume(stores: [TestImage.microcode()]))
        let volume = parsed.roots[0].children[0]

        XCTAssertEqual(volume.children.map(\.kind), [.microcode])
        XCTAssertEqual(volume.children[0].range, volume.body)
        XCTAssertTrue(volume.children[0].name.hasPrefix("Microcode "))
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// An FDC store nests another NVRAM body, which can hold another FDC store,
    /// so the walk refuses to descend past its depth budget. One level below the
    /// volume is spent by the volume's own body; a second FDC nest is refused.
    func testFdcNestingBeyondTheDepthLimitIsBounded() {
        let middle = TestNVRAM.fdcStore(stores: [
            TestNVRAM.vssStore(variables: [TestNVRAM.vssVariable(name: "BootOrder")]),
        ])
        let outer = TestNVRAM.fdcStore(stores: [middle], freeSpace: 0)
        let parsed = UEFIParser.parse(
            TestNVRAM.nvramVolume(stores: [outer]),
            limits: UEFIParser.Limits(maxDepth: 2)
        )
        let volume = parsed.roots[0].children[0]

        XCTAssertEqual(volume.children.map(\.kind), [.fdcStore])
        XCTAssertEqual(volume.children[0].children.map(\.kind), [.fdcStore])
        XCTAssertTrue(volume.children[0].children[0].children.isEmpty)
        XCTAssertTrue(parsed.diagnostics.contains { $0.kind == .recursionLimit })
    }

    /// The same nesting one level shallower is read to the end: the boundary is
    /// inclusive, not a refusal of the deepest allowed level.
    func testFdcNestingWithinTheDepthLimitIsRead() {
        let middle = TestNVRAM.fdcStore(stores: [
            TestNVRAM.vssStore(variables: [TestNVRAM.vssVariable(name: "BootOrder")]),
        ])
        let outer = TestNVRAM.fdcStore(stores: [middle], freeSpace: 0)
        let parsed = UEFIParser.parse(
            TestNVRAM.nvramVolume(stores: [outer]),
            limits: UEFIParser.Limits(maxDepth: 3)
        )
        let volume = parsed.roots[0].children[0]

        XCTAssertEqual(volume.children.map(\.kind), [.fdcStore])
        XCTAssertEqual(volume.children[0].children.map(\.kind), [.fdcStore])
        XCTAssertEqual(volume.children[0].children[0].children.map(\.kind), [.vssStore, .freeSpace])
        XCTAssertEqual(volume.children[0].children[0].children[0].children.map(\.kind), [.vssEntry, .freeSpace])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }
}
