import XCTest
@testable import UEFIImage

/// A file's body read as sections, and the encapsulating ones where the tree
/// stops being a list (§6).
final class SectionParseTests: XCTestCase {
    private func file(_ sections: [[UInt8]], ffs: EFIGUID = KnownGUIDs.ffsV2) -> UEFINode {
        UEFIParser.parse(TestImage.volume(
            fileSystem: ffs,
            files: [TestImage.sectionedFile(sections: sections)]
        )).roots[0].children[0]
    }

    private func diagnostics(_ sections: [[UInt8]]) -> [UEFIDiagnostic.Kind] {
        UEFIParser.parse(TestImage.volume(
            files: [TestImage.sectionedFile(sections: sections)]
        )).diagnostics.map(\.kind)
    }

    func testSectionsAreReadInOrder() {
        let node = file([
            TestImage.section(type: 0x10, body: [UInt8](repeating: 0xAB, count: 8)),
            TestImage.section(type: 0x13, body: [0x08])
        ])

        XCTAssertEqual(node.children.map(\.kind), [.section, .section])
        XCTAssertEqual(node.children.map(\.name), ["PE32 image", "DXE dependency"])
        XCTAssertEqual(node.children.map(\.range), [0x60..<0x6C, 0x6C..<0x71])
        XCTAssertEqual(node.children[0].header, 0x60..<0x64)
        XCTAssertEqual(node.children[0].body, 0x64..<0x6C)
    }

    /// Sections sit on four-byte boundaries where files sit on eight, and the
    /// bytes in between are still bytes.
    func testTheAlignmentGapBetweenSectionsIsKept() {
        let node = file([
            TestImage.section(type: 0x10, body: [1, 2, 3]),
            TestImage.section(type: 0x10, body: [4, 5, 6, 7])
        ])

        XCTAssertEqual(node.children.map(\.kind), [.section, .padding, .section])
        XCTAssertEqual(node.children.map(\.range), [0x60..<0x67, 0x67..<0x68, 0x68..<0x70])
    }

    /// Without this a volume is three hundred rows of GUIDs.
    func testANameSectionNamesTheFile() {
        let node = file([
            TestImage.section(type: 0x10, body: [1, 2, 3, 4]),
            TestImage.nameSection("PciBusDxe")
        ])

        XCTAssertEqual(node.name, "PciBusDxe")
        XCTAssertEqual(node.children.last?.name, "PciBusDxe")
    }

    /// And it is worth looking for one level down: a name section is often
    /// wrapped along with the image it names.
    func testANameSectionInsideAnEncapsulationStillNamesTheFile() {
        let node = file([TestImage.section(
            type: Section.disposable,
            body: TestImage.nameSection("SetupUtility")
        )])

        XCTAssertEqual(node.name, "SetupUtility")
    }

    /// The extended-size marker means an extended size only in an FFSv3
    /// volume. Anywhere else it is a size of `0xFFFFFF`, and reading four extra
    /// bytes of header would eat the start of the body.
    func testTheExtendedSizeMarkerIsOnlyExtendedInFfsV3() {
        let sections = [TestImage.section(type: 0x10, body: [1, 2, 3, 4], extendedSize: true)]
        let node = file(sections)

        XCTAssertEqual(node.children[0].header, 0x60..<0x64)
        XCTAssertEqual(diagnostics(sections), [.truncated(.sectionBody)])
    }

    /// A volume inside a section inside a file inside a volume — the point at
    /// which this format starts over one level down.
    func testAVolumeImageSectionHoldsAVolume() {
        let inner = TestImage.volume(
            length: 0x200,
            files: [TestImage.file(body: [1, 2, 3, 4, 5, 6, 7, 8])]
        )
        let node = file([TestImage.section(type: Section.firmwareVolumeImage, body: inner)])
        let volume = node.children[0].children[0]

        XCTAssertEqual(volume.kind, .volume)
        XCTAssertEqual(volume.range, 0x64..<0x264)
        XCTAssertEqual(volume.children.map(\.kind), [.file, .freeSpace])
        XCTAssertEqual(volume.children[0].range, 0xAC..<0xCC)
    }

    /// A compression section that is not actually compressed still holds
    /// sections, and reading it as opaque would hide half an image (§6.2).
    func testAnUncompressedCompressionSectionIsWalkedThrough() {
        let inner = TestImage.section(type: 0x10, body: [1, 2, 3, 4])
        let node = file([TestImage.compressionSection(algorithm: 0x00, body: inner)])
        let outer = node.children[0]

        XCTAssertEqual(outer.name, "Uncompressed section")
        XCTAssertEqual(outer.header, 0x60..<0x69)      // common header plus five
        XCTAssertEqual(outer.children.map(\.name), ["PE32 image"])
    }

    /// What this parser will not do is decompress. The section says which
    /// algorithm it is and keeps its body whole — no third-party code, and no
    /// pretending the contents are readable.
    func testACompressedSectionIsALeafThatNamesItsAlgorithm() {
        let node = file([TestImage.compressionSection(
            algorithm: 0x86, body: [UInt8](repeating: 0x5A, count: 32)
        )])

        XCTAssertEqual(node.children[0].name, "LZMA with x86 filter section")
        XCTAssertTrue(node.children[0].children.isEmpty)
        XCTAssertEqual(node.children[0].body, 0x69..<0x89)
    }

    func testAGuidDefinedSectionIsNamedByItsGuid() {
        let lzma = KnownGUIDs.guid("EE4E5898-3914-4259-9D6E-DC7BD79403CF")
        let node = file([TestImage.guidedSection(
            guid: lzma, body: [UInt8](repeating: 0x11, count: 16)
        )])

        XCTAssertEqual(node.children[0].name, "LZMA section")
        XCTAssertEqual(node.children[0].guid, lzma)
        XCTAssertTrue(node.children[0].children.isEmpty)
    }

    /// CRC32 only checks the data, so what is inside is still there to read —
    /// the one GUID-defined section whose body is a run of sections.
    func testACrc32SectionIsWalkedThrough() {
        let crc32 = KnownGUIDs.guid("FC1BCDB0-7D31-49AA-936A-A4600D9DD083")
        let inner = TestImage.section(type: 0x10, body: [1, 2, 3, 4])
        let node = file([TestImage.guidedSection(guid: crc32, body: inner)])

        XCTAssertEqual(node.children[0].name, "CRC32 section")
        XCTAssertEqual(node.children[0].children.map(\.name), ["PE32 image"])
    }

    /// The body starts where `DataOffset` says, not where the structure ends:
    /// vendors put certificates and their own headers in between (§6.3).
    func testTheDataOffsetDecidesWhereTheBodyStarts() {
        let crc32 = KnownGUIDs.guid("FC1BCDB0-7D31-49AA-936A-A4600D9DD083")
        let inner = TestImage.section(type: 0x10, body: [1, 2, 3, 4])
        let node = file([TestImage.guidedSection(
            guid: crc32, body: inner, vendorHeader: [UInt8](repeating: 0xEE, count: 8)
        )])
        let section = node.children[0]

        XCTAssertEqual(section.header, 0x60..<0x80)    // 4 + 20 + 8
        XCTAssertEqual(section.children.map(\.range), [0x80..<0x88])
    }

    func testADisposableSectionIsWalkedThrough() {
        let inner = TestImage.section(type: 0x10, body: [1, 2, 3, 4])
        let node = file([TestImage.section(type: Section.disposable, body: inner)])

        XCTAssertEqual(node.children[0].children.map(\.name), ["PE32 image"])
    }

    func testAnUnknownSectionTypeIsReportedAndKept() {
        let node = file([TestImage.section(type: 0x77, body: [1, 2, 3, 4])])

        XCTAssertEqual(node.children.map(\.name), ["Section type 0x77"])
        XCTAssertEqual(
            diagnostics([TestImage.section(type: 0x77, body: [1, 2, 3, 4])]),
            [.unknownType(.sectionHeader, 0x77)]
        )
    }

    /// The gap at `0x1A` is the specification's, and a range that papered over
    /// it would wave through a value that means something is wrong.
    func testTheGapInTheSectionTypesIsNotAType() {
        XCTAssertEqual(
            diagnostics([TestImage.section(type: 0x1A, body: [1, 2, 3, 4])]),
            [.unknownType(.sectionHeader, 0x1A)]
        )
        XCTAssertTrue(diagnostics([TestImage.section(type: 0x1B, body: [1, 2, 3, 4])]).isEmpty)
    }

    /// Zero would put the walk back on the same offset for ever (§11).
    func testASectionOfZeroSizeStopsTheWalk() {
        let sections = [
            TestImage.section(type: 0x10, body: [1, 2, 3, 4], size: 0),
            TestImage.section(type: 0x13, body: [8])
        ]

        XCTAssertTrue(file(sections).children.isEmpty)
        XCTAssertEqual(diagnostics(sections), [.zeroSize(.sectionHeader)])
    }

    func testASectionRunningPastTheFileIsReported() {
        let sections = [TestImage.section(type: 0x10, body: [1, 2, 3, 4], size: 0x400)]

        XCTAssertEqual(diagnostics(sections), [.truncated(.sectionBody)])
    }

    /// FFSv3 puts a large section's size in a field of its own, and the header
    /// is four bytes longer for it (§6).
    func testAnExtendedSizeSectionHasALongerHeader() {
        let node = file(
            [TestImage.section(type: 0x10, body: [1, 2, 3, 4], extendedSize: true)],
            ffs: KnownGUIDs.ffsV3
        )

        XCTAssertEqual(node.children[0].header, 0x60..<0x68)
        XCTAssertEqual(node.children[0].body, 0x68..<0x6C)
    }

    /// Volume, file, section, volume again: a real image nests eight or ten
    /// deep and a corrupt one nests for ever, so every level that can recurse
    /// counts the depth (§11).
    private var nestedImage: [UInt8] {
        let inner = TestImage.volume(length: 0x200, files: [TestImage.file(body: [1, 2, 3, 4])])
        return TestImage.volume(
            length: 0x800,
            files: [TestImage.sectionedFile(sections: [
                TestImage.section(type: Section.firmwareVolumeImage, body: inner)
            ])]
        )
    }

    func testSectionsStopAtTheDepthLimit() {
        let parsed = UEFIParser.parse(nestedImage, limits: UEFIParser.Limits(maxDepth: 2))
        let file = parsed.roots[0].children[0]

        XCTAssertEqual(file.kind, .file)
        XCTAssertTrue(file.children.isEmpty)
        XCTAssertTrue(parsed.diagnostics.contains { $0.kind == .recursionLimit })
        XCTAssertEqual(parsed.diagnostics.first { $0.kind == .recursionLimit }?.severity, .error)
    }

    func testANestedVolumeStopsAtTheDepthLimit() {
        let parsed = UEFIParser.parse(nestedImage, limits: UEFIParser.Limits(maxDepth: 3))
        let volume = parsed.roots[0].children[0].children[0].children[0]

        XCTAssertEqual(volume.kind, .volume)
        XCTAssertTrue(volume.children.isEmpty)
        XCTAssertTrue(parsed.diagnostics.contains { $0.kind == .recursionLimit })
    }
}
