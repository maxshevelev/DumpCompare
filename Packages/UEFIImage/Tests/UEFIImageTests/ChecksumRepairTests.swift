import XCTest
@testable import UEFIImage

/// Putting back what an edit invalidates (§3.3, §5.4, §7.1).
final class ChecksumRepairTests: XCTestCase {
    private func applying(_ repairs: [ChecksumRepair], to image: [UInt8]) -> [UInt8] {
        var edited = image
        for repair in repairs {
            edited.replaceSubrange(
                Int(repair.offset)..<(Int(repair.offset) + repair.bytes.count),
                with: repair.bytes
            )
        }
        return edited
    }

    /// The test that matters: repair, write, parse again, and the image no
    /// longer complains.
    func testRepairingAFileBodyLeavesNothingToComplainAbout() {
        var image = TestImage.volume(files: [
            TestImage.file(attributes: FFS.checksumBit, body: [1, 2, 3, 4, 5, 6, 7, 8])
        ])
        image[0x64] = 0x99                       // an edit inside the body
        let parsed = UEFIParser.parse(image)
        XCTAssertFalse(parsed.diagnostics.isEmpty)

        let repairs = UEFIChecksums.repairs(
            for: parsed.roots[0].children[0].children[0], volumeRevision: 2, in: ImageReader(image)
        )

        XCTAssertEqual(repairs.map(\.offset), [0x59])
        XCTAssertTrue(UEFIParser.parse(applying(repairs, to: image)).diagnostics.isEmpty)
    }

    func testRepairingAFileHeaderLeavesNothingToComplainAbout() {
        var image = TestImage.volume(files: [TestImage.file(body: [1, 2, 3, 4])])
        image[0x52] = 0x0A                       // the file's type byte
        let parsed = UEFIParser.parse(image)
        XCTAssertFalse(parsed.diagnostics.isEmpty)

        let repairs = UEFIChecksums.repairs(
            for: parsed.roots[0].children[0].children[0], volumeRevision: 2, in: ImageReader(image)
        )

        XCTAssertEqual(repairs.map(\.offset), [0x58])
        XCTAssertTrue(UEFIParser.parse(applying(repairs, to: image)).diagnostics.isEmpty)
    }

    /// A file with nothing wrong with it needs no writes, and an empty list is
    /// how that gets said — a transaction with no writes is refused anyway.
    func testAFileThatIsAlreadyRightNeedsNoRepair() {
        let image = TestImage.volume(files: [TestImage.file(body: [1, 2, 3, 4])])
        let parsed = UEFIParser.parse(image)

        XCTAssertTrue(UEFIChecksums.repairs(
            for: parsed.roots[0].children[0].children[0], volumeRevision: 2, in: ImageReader(image)
        ).isEmpty)
    }

    /// Without the checksum attribute the field holds a fixed value, and which
    /// one depends on the volume's revision (§5.4).
    func testTheFixedBodyChecksumFollowsTheVolumeRevision() {
        let image = TestImage.volume(files: [
            TestImage.file(body: [1, 2], bodyChecksum: 0x00)
        ])
        let file = UEFIParser.parse(image).roots[0].children[0].children[0]

        XCTAssertEqual(
            UEFIChecksums.repairs(for: file, volumeRevision: 2, in: ImageReader(image))
                .first?.bytes,
            [FFS.fixedChecksum2]
        )
        XCTAssertEqual(
            UEFIChecksums.repairs(for: file, volumeRevision: 1, in: ImageReader(image))
                .first?.bytes,
            [FFS.fixedChecksum]
        )
    }

    /// A volume's checksum covers its own header and nothing below it, which is
    /// the one mercy in this format: editing a file does not cascade upwards.
    func testRepairingAVolumeHeaderLeavesNothingToComplainAbout() {
        var image = TestImage.volume(length: 0x400)
        image[0x37] = 0x02                       // Revision, inside the header
        image[0x2C] = 0x0B                       // Attributes, likewise
        let parsed = UEFIParser.parse(image)
        XCTAssertFalse(parsed.diagnostics.isEmpty)

        let repairs = UEFIChecksums.repairs(forVolume: parsed.roots[0].children[0], in: ImageReader(image))

        XCTAssertEqual(repairs.map(\.offset), [0x32])
        XCTAssertTrue(UEFIParser.parse(applying(repairs, to: image)).diagnostics.isEmpty)
    }

    func testAVolumeThatIsAlreadyRightNeedsNoRepair() {
        let image = TestImage.volume(length: 0x400)
        let parsed = UEFIParser.parse(image)

        XCTAssertTrue(
            UEFIChecksums.repairs(forVolume: parsed.roots[0].children[0], in: ImageReader(image)).isEmpty
        )
    }

    /// Microcode checks out when every dword of it sums to zero, so a body edit
    /// moves the field by exactly the amount the sum moved (§7.1).
    func testRepairingMicrocodeLeavesNothingToComplainAbout() {
        var image = TestImage.microcode()
        image[0x40] = 0x77
        let parsed = UEFIParser.parse(image)
        XCTAssertFalse(parsed.diagnostics.isEmpty)

        let repairs = UEFIChecksums.repairs(forMicrocode: parsed.roots[0].children[0], in: ImageReader(image))

        XCTAssertEqual(repairs.map(\.offset), [0x10])
        XCTAssertTrue(UEFIParser.parse(applying(repairs, to: image)).diagnostics.isEmpty)
    }

    /// The helpers answer for the structure they are named for and not for
    /// whatever node is handed to them — checked against nodes that would each
    /// yield a repair if the kind were not looked at.
    func testARepairAsksForTheRightKindOfNode() {
        var image = TestImage.volume(length: 0x400, files: [TestImage.file(body: [1, 2, 3, 4])])
        image[0x00] = 0x11                       // a volume header worth repairing
        image[0x52] = 0x0A                       // a file header worth repairing
        let parsed = UEFIParser.parse(image)
        let reader = ImageReader(image)
        var volume = parsed.roots[0].children[0]
        var file = volume.children[0]

        XCTAssertFalse(UEFIChecksums.repairs(forVolume: volume, in: reader).isEmpty)
        XCTAssertFalse(UEFIChecksums.repairs(for: file, volumeRevision: 2, in: reader).isEmpty)

        volume.kind = .file
        file.kind = .microcode
        XCTAssertTrue(UEFIChecksums.repairs(forVolume: volume, in: reader).isEmpty)
        XCTAssertTrue(UEFIChecksums.repairs(for: file, volumeRevision: 2, in: reader).isEmpty)
        XCTAssertTrue(UEFIChecksums.repairs(forMicrocode: parsed.roots[0].children[0], in: reader).isEmpty)
    }
}
