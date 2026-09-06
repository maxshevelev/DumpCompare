import XCTest
@testable import UEFIFormat

/// Walking a volume's body into files (§5).
final class FileParseTests: XCTestCase {
    private func volume(_ files: [[UInt8]], length: UInt64 = 0x400) -> UEFINode {
        UEFIParser.parse(TestImage.volume(length: length, files: files)).roots[0]
    }

    private func parse(_ files: [[UInt8]], length: UInt64 = 0x400) -> UEFIImage {
        UEFIParser.parse(TestImage.volume(length: length, files: files))
    }

    func testFilesAreReadBackToBack() {
        let node = volume([
            TestImage.file(body: [1, 2, 3, 4]),
            TestImage.file(body: [5, 6, 7, 8, 9, 10, 11, 12])
        ])

        XCTAssertEqual(node.children.map(\.kind), [.file, .padding, .file, .freeSpace])
        XCTAssertEqual(
            node.children.map(\.range),
            [0x48..<0x64, 0x64..<0x68, 0x68..<0x88, 0x88..<0x400]
        )
    }

    /// The header is `0x18` bytes and the body is the rest — the split every
    /// consumer of this tree reads a structure out of.
    func testAFileIsAHeaderAndABody() {
        let file = volume([TestImage.file(type: 0x07, body: [1, 2, 3, 4])]).children[0]

        XCTAssertEqual(file.header, 0x48..<0x60)
        XCTAssertEqual(file.body, 0x60..<0x64)
        XCTAssertTrue(file.tail.isEmpty)
        XCTAssertEqual(file.guid, TestImage.driverGUID)
        XCTAssertEqual(file.name, "Driver")
        XCTAssertEqual(file.subtype, 0x07)
    }

    /// A file whose size stops short of the next eight-byte boundary leaves
    /// bytes that belong to no structure, and a byte in no node is a byte that
    /// cannot be written back (§11).
    func testTheAlignmentGapBetweenFilesIsKept() {
        let node = volume([TestImage.file(body: [1, 2, 3, 4]), TestImage.file(body: [5])])
        let gap = node.children[1]

        XCTAssertEqual(gap.kind, .padding)
        XCTAssertEqual(gap.range, 0x64..<0x68)
        XCTAssertTrue(gap.isErased)
    }

    /// A file we know by GUID is called what it is, whatever its type says.
    func testAKnownGuidNamesTheFile() {
        let file = volume([TestImage.file(guid: KnownGUIDs.volumeTopFile, body: [1])]).children[0]

        XCTAssertEqual(file.name, "Volume Top File")
    }

    func testAPadFileIsNamedByItsType() {
        let file = volume([TestImage.file(type: 0xF0, body: [1, 2])]).children[0]

        XCTAssertEqual(file.name, "Pad file")
        XCTAssertTrue(UEFIParser.parse(TestImage.volume(files: [
            TestImage.file(type: 0xF0, body: [1, 2])
        ])).diagnostics.isEmpty)
    }

    /// A file that must not be moved when the image is rebuilt says so in one
    /// bit, and losing it is how a rebuild breaks Boot Guard (§11).
    func testTheFixedAttributeReachesTheNode() {
        let file = volume([TestImage.file(attributes: FFS.fixed, body: [1])]).children[0]

        XCTAssertTrue(file.isFixed)
    }

    /// A size of zero would put the walk back on the same offset for ever
    /// (§11). It stops, and says why.
    func testAFileOfZeroSizeStopsTheWalk() {
        let parsed = parse([TestImage.file(body: [1, 2, 3, 4], size: 0), TestImage.file(body: [9])])

        XCTAssertTrue(parsed.roots[0].children.isEmpty)
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.zeroSize(.fileHeader)])
        XCTAssertEqual(parsed.diagnostics.map(\.offset), [0x5C])
    }

    func testAFileSmallerThanItsHeaderStopsTheWalk() {
        let parsed = parse([TestImage.file(body: [1, 2, 3, 4], size: 0x10)])

        XCTAssertTrue(parsed.roots[0].children.isEmpty)
        XCTAssertEqual(
            parsed.diagnostics.map(\.kind),
            [.sizeMismatch(.fileHeader, stored: 0x10, computed: 0x18)]
        )
    }

    /// A file claiming more bytes than the volume has left.
    func testAFileRunningPastTheVolumeIsCutAndReported() {
        let parsed = parse([TestImage.file(body: [1, 2, 3, 4], size: 0x600)])

        XCTAssertEqual(parsed.roots[0].children.map(\.range), [0x48..<0x400])
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.truncated(.fileBody)])
    }

    func testAStaleHeaderChecksumIsReported() {
        let parsed = parse([TestImage.file(body: [1, 2], headerChecksum: 0x11)])

        XCTAssertEqual(parsed.roots[0].children.map(\.kind), [.file, .padding, .freeSpace])
        XCTAssertEqual(parsed.diagnostics.count, 1)
        XCTAssertEqual(parsed.diagnostics[0].offset, 0x58)
        guard case .checksumMismatch(.fileHeader, let stored, _) = parsed.diagnostics[0].kind else {
            return XCTFail("expected a file header checksum diagnostic")
        }
        XCTAssertEqual(stored, 0x11)
    }

    /// A file without the checksum attribute carries a fixed value in the
    /// field, and which fixed value depends on the volume's revision (§5.4).
    func testAWrongFixedBodyChecksumIsReported() {
        let parsed = parse([TestImage.file(body: [1, 2], bodyChecksum: FFS.fixedChecksum)])

        XCTAssertEqual(
            parsed.diagnostics.map(\.kind),
            [.checksumMismatch(.fileBody, stored: 0x5A, computed: 0xAA)]
        )
    }

    /// With the attribute set the field is a real checksum of the body, and a
    /// body edited without recomputing it is exactly what this catches.
    func testAComputedBodyChecksumIsCheckedAgainstTheBody() {
        let good = TestImage.file(attributes: FFS.checksumBit, body: [1, 2, 3, 4])
        XCTAssertTrue(parse([good]).diagnostics.isEmpty)

        var edited = good
        edited[Int(FFS.headerSize)] = 0x99
        XCTAssertEqual(
            parse([edited]).diagnostics.map(\.kind),
            [.checksumMismatch(.fileBody, stored: 0xF6, computed: 0x5E)]
        )
    }

    func testAnUnknownFileTypeIsReportedAndKept() {
        let parsed = parse([TestImage.file(type: 0x42, body: [1])])

        XCTAssertEqual(parsed.roots[0].children.map(\.kind), [.file, .padding, .freeSpace])
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.unknownType(.fileHeader, 0x42)])
        XCTAssertEqual(parsed.roots[0].children[0].name, "File type 0x42")
    }

    /// FFSv3 puts a large file's size in a 64-bit field after the base header,
    /// which makes the header longer — read it as a short file and the body
    /// starts eight bytes early.
    func testAnFfsV3LargeFileHasALongerHeader() {
        let image = TestImage.volume(
            fileSystem: KnownGUIDs.ffsV3,
            files: [TestImage.largeFile(body: [1, 2, 3, 4, 5, 6, 7, 8])]
        )
        let file = UEFIParser.parse(image).roots[0].children[0]

        XCTAssertEqual(file.header, 0x48..<0x68)
        XCTAssertEqual(file.body, 0x68..<0x70)
    }

    /// Only FFSv1 files have a tail, and only in a Revision 1 volume — the same
    /// attribute bit means "large file" everywhere else (§5.3).
    func testAnFfsV1TailIsHeldApartFromTheBody() {
        let image = TestImage.volume(
            fileSystem: KnownGUIDs.ffsV1,
            revision: 1,
            files: [TestImage.file(
                attributes: FFS.tailPresent,
                body: [1, 2, 3, 4, 0xAA, 0xBB],
                volumeRevision: 1
            )]
        )
        let file = UEFIParser.parse(image).roots[0].children[0]

        XCTAssertEqual(file.header, 0x48..<0x60)
        XCTAssertEqual(file.body, 0x60..<0x64)
        XCTAssertEqual(file.tail, 0x64..<0x66)
    }

    /// Free space that turns out to have something at the end of it: the bytes
    /// after the last erased one are data somebody put there (§5.8), and they
    /// are kept as their own node rather than swallowed by the free space.
    func testDataAfterTheFreeSpaceIsHeldApart() {
        let image = TestImage.volume(
            length: 0x400,
            files: [TestImage.file(body: [1, 2, 3, 4, 5, 6, 7, 8])],
            trailing: [UInt8](repeating: 0xFF, count: 0x100) + [0x11, 0x22, 0x33, 0x44]
        )
        let children = UEFIParser.parse(image).roots[0].children

        XCTAssertEqual(children.map(\.kind), [.file, .freeSpace, .nonUEFIData])
        XCTAssertEqual(children[2].range, 0x168..<0x400)
    }

    /// And what is in there gets searched: vendors put runs of microcode and
    /// whole volumes in the space after a volume's files, and leaving it as one
    /// opaque block would hide them (§5.8).
    func testWhatIsInsideNonUefiDataIsFound() {
        let image = TestImage.volume(
            length: 0x1000,
            files: [TestImage.file(body: [1, 2, 3, 4, 5, 6, 7, 8])],
            trailing: [UInt8](repeating: 0xFF, count: 0x100) + TestImage.microcode()
        )
        let children = UEFIParser.parse(image).roots[0].children
        let data = children.last

        XCTAssertEqual(data?.kind, .nonUEFIData)
        XCTAssertEqual(data?.children.map(\.kind), [.microcode, .padding])
        XCTAssertEqual(data?.children.first?.range, 0x168..<0x1D8)
    }

    /// And the boundary between the two goes *back* to the eight-byte mark
    /// (§5.8): whatever the data turns out to be, it starts aligned, so the
    /// erased bytes in front of it belong to it and not to the free space.
    func testTheFreeSpaceBoundaryStepsBackToTheAlignment() {
        let image = TestImage.volume(
            length: 0x400,
            files: [TestImage.file(body: [1, 2, 3, 4, 5, 6, 7, 8])],
            trailing: [UInt8](repeating: 0xFF, count: 0x101) + [0x11, 0x22, 0x33, 0x44]
        )
        let children = UEFIParser.parse(image).roots[0].children

        XCTAssertEqual(children.map(\.range), [0x48..<0x68, 0x68..<0x168, 0x168..<0x400])
    }
}
