import XCTest
@testable import DumpCompareCore

final class FileIdentityTests: XCTestCase {
    func testSameFileViaHardLinkIsEqual() throws {
        let url = try TestSupport.makeTempFile(contents: Data([0x01, 0x02]))
        let dir = url.deletingLastPathComponent()
        let linkURL = dir.appendingPathComponent("hardlink-\(UUID().uuidString).bin")
        try FileManager.default.linkItem(at: url, to: linkURL)

        XCTAssertEqual(FileIdentity(url: url), FileIdentity(url: linkURL))
    }

    func testDifferentFilesNotEqual() throws {
        let a = try TestSupport.makeTempFile(contents: Data([0x01]))
        let b = try TestSupport.makeTempFile(contents: Data([0x02]))
        XCTAssertNotEqual(FileIdentity(url: a), FileIdentity(url: b))
    }

    func testSymlinkToFileIsEqual() throws {
        let url = try TestSupport.makeTempFile(contents: Data([0x01]))
        let dir = url.deletingLastPathComponent()
        let linkURL = dir.appendingPathComponent("symlink-\(UUID().uuidString).bin")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: url)

        // stat(2) follows symlinks, so identity matches the target's file.
        XCTAssertEqual(FileIdentity(url: linkURL), FileIdentity(url: url))
    }

    func testNonexistentPathsFallBackToResolvedPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dc-missing-\(UUID().uuidString)")
        let a = dir.appendingPathComponent("x.bin")
        let b = dir.appendingPathComponent("x.bin")
        XCTAssertEqual(FileIdentity(url: a), FileIdentity(url: b))

        let c = dir.appendingPathComponent("y.bin")
        XCTAssertNotEqual(FileIdentity(url: a), FileIdentity(url: c))
    }

    func testDescriptionIsInformative() throws {
        let url = try TestSupport.makeTempFile(contents: Data([0x01]))
        let description = FileIdentity(url: url).description
        XCTAssertFalse(description.isEmpty)
        // Either the stat-based form (file … on dev …) or the path fallback.
        XCTAssertTrue(description.contains("file") || description.contains("path"))
    }
}
