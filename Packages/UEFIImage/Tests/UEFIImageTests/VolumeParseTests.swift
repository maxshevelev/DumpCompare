import XCTest
@testable import UEFIImage

/// Finding volumes in an image and reading their headers (§3, §4).
final class VolumeParseTests: XCTestCase {
    private func parse(_ bytes: [UInt8]) -> UEFIImage {
        UEFIParser.parse(bytes)
    }

    func testAVolumeIsFoundBetweenPadding() {
        let image = TestImage.image(
            padding: 0x100,
            TestImage.volume(length: 0x400),
            after: 0x100
        )

        let parsed = parse(image)

        XCTAssertEqual(parsed.roots[0].children.map(\.kind), [.padding, .volume, .padding])
        XCTAssertEqual(parsed.roots[0].children.map(\.range), [0..<0x100, 0x100..<0x500, 0x500..<0x600])
    }

    /// Erased padding and padding with something in it are not the same thing
    /// to anyone rebuilding an image.
    func testPaddingKnowsWhetherItIsErased() {
        var image = TestImage.image(padding: 0x100, TestImage.volume(length: 0x400))
        image[0x40] = 0x5A

        let parsed = parse(image)

        XCTAssertEqual(parsed.roots[0].children.first?.isErased, false)
        XCTAssertEqual(parsed.roots[0].children.first?.name, "Padding")
    }

    /// The body starts after the header, and the header is where the file walk
    /// must not begin — off by `HeaderLength` and every file in the volume is
    /// misread.
    func testTheHeaderAndBodyAreSplitAtTheHeaderLength() {
        let parsed = parse(TestImage.volume(length: 0x400))
        let volume = parsed.roots[0].children[0]

        XCTAssertEqual(volume.header, 0..<0x48)
        XCTAssertEqual(volume.body, 0x48..<0x400)
        XCTAssertEqual(volume.guid, KnownGUIDs.ffsV2)
        XCTAssertEqual(volume.name, "FFSv2")
        XCTAssertEqual(volume.subtype, 2)
    }

    /// Four bytes reading `_FVH` turn up inside compressed data all the time.
    /// A candidate that fails its header checks is not a volume and — just as
    /// important — not a complaint about the image either.
    func testASignatureWithoutAValidHeaderIsNotAVolume() {
        var image = [UInt8](repeating: 0xFF, count: 0x200)
        image[0x128] = 0x5F; image[0x129] = 0x46; image[0x12A] = 0x56; image[0x12B] = 0x48

        let parsed = parse(image)

        XCTAssertEqual(parsed.roots[0].children.map(\.kind), [.padding])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    func testASignatureTooCloseToTheStartIsNotAVolume() {
        var image = [UInt8](repeating: 0xFF, count: 0x100)
        image[0x10] = 0x5F; image[0x11] = 0x46; image[0x12] = 0x56; image[0x13] = 0x48

        XCTAssertEqual(parse(image).roots[0].children.map(\.kind), [.padding])
    }

    /// A checksum that no longer matches is the ordinary trace of an image
    /// edited by a tool that did not put it back (§3.3).
    func testAStaleHeaderChecksumIsReported() {
        let parsed = parse(TestImage.volume(length: 0x400, checksum: 0x1234))

        XCTAssertEqual(parsed.roots[0].children.map(\.kind), [.volume])
        XCTAssertEqual(
            parsed.diagnostics.map(\.kind),
            [.checksumMismatch(.volumeHeader, stored: 0x1234, computed: 0xE5D1)]
        )
        XCTAssertEqual(parsed.diagnostics.map(\.offset), [0x32])
    }

    /// The block map is a second opinion about the size. When the two disagree
    /// the volume is damaged, but it is still the volume (§3.1).
    func testABlockMapThatDisagreesWithTheLengthIsReported() {
        let parsed = parse(TestImage.volume(length: 0x400, blockMapLength: 0x200))

        XCTAssertEqual(parsed.roots[0].children.map(\.range), [0..<0x400])
        XCTAssertEqual(
            parsed.diagnostics.map(\.kind),
            [.sizeMismatch(.volumeHeader, stored: 0x400, computed: 0x200)]
        )
    }

    /// A volume claiming more bytes than the image has: keep what is there,
    /// and say so.
    func testAVolumeRunningPastTheEndIsCutAndReported() {
        let volume = TestImage.volume(length: 0x400)
        let parsed = parse(Array(volume[0..<0x300]))

        XCTAssertEqual(parsed.roots[0].children.map(\.range), [0..<0x300])
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.truncated(.volumeBody)])
    }

    /// An NVRAM store volume is read as a run of stores, not as files (§9). An
    /// all-erased one has no stores, so its body is one run of free space — and
    /// it is not an unknown file system.
    func testAnErasedNvramVolumeReadsAsFreeSpace() {
        let nvram = KnownGUIDs.guid("FFF12B8D-7696-4C8B-A985-2747075B4F50")
        let parsed = parse(TestImage.volume(fileSystem: nvram, length: 0x400))

        XCTAssertEqual(parsed.roots[0].children.map(\.name), ["NVRAM store"])
        XCTAssertEqual(parsed.roots[0].children[0].children.map(\.kind), [.freeSpace])
        XCTAssertEqual(parsed.roots[0].children[0].children.map(\.range), [0x48..<0x400])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// A volume whose file system is not one we parse keeps its body whole and
    /// says so (§3.4) — the NVRAM store GUIDs no longer land here.
    func testAGenuinelyUnknownFileSystemKeepsItsBodyWhole() {
        let unknown = KnownGUIDs.guid("11111111-2222-3333-4444-555555555555")
        let parsed = parse(TestImage.volume(fileSystem: unknown, length: 0x400))

        XCTAssertTrue(parsed.roots[0].children[0].children.isEmpty)
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.unknownFileSystem(unknown)])
    }

    func testARevisionOutsideOneAndTwoIsNotAVolume() {
        let parsed = parse(TestImage.volume(revision: 3, length: 0x400))

        XCTAssertEqual(parsed.roots[0].children.map(\.kind), [.padding])
    }

    /// The extended header moves the body but stays outside the checksum
    /// (§3.2, §3.3). Summing over it instead of over `HeaderLength` makes every
    /// Revision 2 volume in existence look corrupt.
    func testAnExtendedHeaderMovesTheBodyAndStaysOutOfTheChecksum() {
        let name = KnownGUIDs.guid("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let parsed = parse(TestImage.volume(length: 0x400, extendedHeader: name))
        let volume = parsed.roots[0].children[0]

        XCTAssertEqual(volume.header, 0..<0x60)   // 0x48 + 0x14, aligned up to eight
        XCTAssertEqual(volume.body, 0x60..<0x400)
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    /// A volume pointing at an extended header that is not in the image.
    func testAnExtendedHeaderOffTheEndIsReported() {
        var bytes = TestImage.volume(length: 0x400, extendedHeader: KnownGUIDs.ffsV2)
        bytes[0x34] = 0x00; bytes[0x35] = 0xF0     // ExtHeaderOffset far past the end

        let parsed = UEFIParser.parse(bytes)

        XCTAssertEqual(parsed.roots[0].children.map(\.kind), [.volume])
        XCTAssertTrue(parsed.diagnostics.contains { $0.kind == .truncated(.volumeExtendedHeader) })
    }

    /// Erase polarity decides what free space looks like, and it is the
    /// volume's attribute that says (§3.5).
    func testAVolumeErasedWithZeroesReadsItsFreeSpaceAsFree() {
        let parsed = parse(TestImage.volume(length: 0x400, emptyByte: 0x00))
        let volume = parsed.roots[0].children[0]

        XCTAssertEqual(volume.children.map(\.kind), [.freeSpace])
        XCTAssertEqual(volume.children.map(\.range), [0x48..<0x400])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }
}
