import XCTest
import MEFirmware
@testable import MEATool

/// `MEACurator` / `MEAZones` — the pure, hand-curated tree over the engine's
/// `FirmwareAnalysis`. Fixtures are built by decoding JSON so the tests never
/// need `MEFirmware`'s internal memberwise initializers nor any data source:
/// a decoded `FirmwareAnalysis` is exactly what the engine hands the curator.
final class MEACuratorTests: XCTestCase {
    // MARK: - Fixtures

    /// Decode an analysis whose top-level fields are `overrides` merged over
    /// the minimum identity every analysis carries.
    private func analysis(_ overrides: [String: Any]) throws -> FirmwareAnalysis {
        var base: [String: Any] = [
            "family": "csme",
            "variant": "CSME",
            "version": ["major": 15, "minor": 40, "hotfix": 37, "build": 3121],
            "release": "production",
            "type": "region",
            "sku": "",
            "platform": "",
            "sizeBytes": 0x200000,
            "regions": [],
            "issues": [],
        ]
        for (key, value) in overrides { base[key] = value }
        let data = try JSONSerialization.data(withJSONObject: base)
        return try JSONDecoder().decode(FirmwareAnalysis.self, from: data)
    }

    private func field(_ label: String, in node: MEANode) -> String? {
        node.fields.first(where: { $0.label == label })?.value
    }

    private func find(_ title: String, in roots: [MEANode]) -> MEANode? {
        roots.first(where: { $0.title == title })
    }

    private func child(_ title: String, of node: MEANode) -> MEANode? {
        node.children.first(where: { $0.title == title })
    }

    // MARK: - Group presence and order

    func testPresentSkipsAbsentGroupsAndOrdersTheRest() throws {
        // Only identity + FPT regions present → exactly two roots, identity
        // first. No manifest / MFS / issues → their groups must not appear.
        let a = try analysis([
            "regions": [regionJSON(name: "FTPR", offset: 0x1000, size: 0x125000)],
        ])
        let roots = MEACurator.present(a)
        // Checksums is the exception to "absent groups do not appear": it is
        // the row a reader selects to ask for the digests, so it is there
        // before there is anything in it.
        XCTAssertEqual(roots.map(\.title), ["Firmware", "Regions (FPT)", "Checksums"])
    }

    func testStructuralGroupsAppearInFixedOrder() throws {
        let a = try analysis([
            "regions": [regionJSON(name: "rbe", offset: 0x100, size: 0x1000)],
            "cseLayoutTable": ["offset": 0x0, "version": 0x17,
                               "redundancy": true, "checksumValid": true,
                               "partitions": [csePartitionJSON(name: "Data", offset: 0x0)]],
            "bootPartitions": [bpdtJSON()],
        ])
        let roots = MEACurator.present(a)
        XCTAssertEqual(roots.map(\.title),
                       ["Firmware", "Regions (FPT)", "CSE Layout Table",
                        "Boot Partitions (BPDT)", "Checksums"])
    }

    func testCodeAndManifestThenMFSThenFactGroupsOrder() throws {
        let a = try analysis([
            "codePartition": cpdJSON(),
            "manifest": manifestJSON(),
            "mfsVolume": mfsJSON(),
            "checksums": ["sha256": "ABCDEF"],
            "issues": [["id": 1, "severity": "warning", "message": "odd"]],
        ] as [String: Any])
        let roots = MEACurator.present(a)
        XCTAssertEqual(roots.map(\.title),
                       ["Firmware", "Code Partition ($CPD)", "Manifest",
                        "File System (MFS)", "Checksums", "Issues"])
    }

    func testPathsAreStablePerRootAndChild() throws {
        let a = try analysis([
            "regions": [regionJSON(name: "FTPR", offset: 0x1000, size: 0x1000),
                        regionJSON(name: "FTUE", offset: 0x2000, size: 0x800)],
        ])
        let roots = MEACurator.present(a)
        XCTAssertEqual(roots[0].path, [0])          // Firmware
        XCTAssertEqual(roots[1].path, [1])          // Regions (FPT)
        XCTAssertEqual(roots[1].children[0].path, [1, 0])   // FTPR
        XCTAssertEqual(roots[1].children[1].path, [1, 1])   // FTUE
    }

    // MARK: - Identity detail

    func testIdentityFieldsAndSubtitle() throws {
        let a = try analysis([
            "variant": "CSME", "securityVersion": "3", "platform": "CNL",
            "sizeBytes": 0x200000,
            "version": ["major": 15, "minor": 40, "hotfix": 37, "build": 3121,
                        "meMajor": 15, "meMinor": 40, "meHotfix": 37,
                        "meBuild": 3121],
        ])
        let roots = MEACurator.present(a)
        let firmware = roots[0]
        XCTAssertEqual(firmware.title, "Firmware")
        XCTAssertEqual(firmware.subtitle, "CSME · 15.40.37.3121")
        XCTAssertEqual(field("Family", in: firmware), "CSME")
        XCTAssertEqual(field("Version", in: firmware), "15.40.37.3121")
        XCTAssertEqual(field("MEU Version", in: firmware), "15.40.37.3121")
        XCTAssertEqual(field("Release", in: firmware), "Production")
        XCTAssertEqual(field("Size", in: firmware), "0x200000 (2097152 bytes)")
        // Empty sku/platform/… rows are dropped.
        XCTAssertNil(field("SKU", in: firmware))
        XCTAssertNil(field("RSA Signature Valid", in: firmware))
    }

    // MARK: - Regions (FPT)

    func testRegionRowSubtitleRangeAndDetail() throws {
        let a = try analysis([
            "regions": [regionJSON(name: "FTPR", offset: 0x1000, size: 0x125000)],
        ])
        let roots = MEACurator.present(a)
        let regions = roots[1]
        XCTAssertEqual(regions.subtitle, "1 region")
        let ftpr = try XCTUnwrap(child("FTPR", of: regions))
        XCTAssertEqual(ftpr.subtitle, "0x1000 · 0x125000")
        XCTAssertEqual(ftpr.range, 0x1000..<0x126000)
        XCTAssertEqual(field("Offset", in: ftpr), "0x1000")
        XCTAssertEqual(field("Size", in: ftpr), "0x125000 (1200128 bytes)")
        XCTAssertEqual(field("Flags", in: ftpr), "0x00008000")
    }

    /// A section that holds nothing says so where a size would go — in the
    /// row's own value and in its detail — and is marked as empty so the panel
    /// can draw that value grey.
    func testAnEmptySectionSaysEmptyAndIsMarkedAsOne() throws {
        let a = try analysis([
            "regions": [regionJSON(name: "FTPR", offset: 0x1000, size: 0x125000),
                        regionJSON(name: "FTUP", offset: 0x5000, size: 0)],
            "cseLayoutTable": ["offset": 0x0, "version": 0x17, "redundancy": false,
                               "checksumValid": true,
                               "partitions": [["id": 0, "name": "Boot 2",
                                               "offset": 0x1000, "size": 0x400,
                                               "empty": true]]],
        ])
        let roots = MEACurator.present(a)

        let regions = try XCTUnwrap(roots.first { $0.title == "Regions (FPT)" })
        let empty = try XCTUnwrap(child("FTUP", of: regions))
        XCTAssertEqual(empty.subtitle, "0x5000 · Empty")
        XCTAssertEqual(field("Size", in: empty), "Empty")
        XCTAssertTrue(empty.isEmptySection)
        XCTAssertNil(empty.range, "there are no bytes to reveal")

        // A region with a size is untouched by any of that.
        let real = try XCTUnwrap(child("FTPR", of: regions))
        XCTAssertEqual(real.subtitle, "0x1000 · 0x125000")
        XCTAssertFalse(real.isEmptySection)

        // A layout slot the table itself marks erased is empty too, whatever
        // size it claims.
        let cse = try XCTUnwrap(roots.first { $0.title == "CSE Layout Table" })
        let slot = try XCTUnwrap(child("Boot 2", of: cse))
        XCTAssertTrue(slot.isEmptySection)
        XCTAssertEqual(field("Size", in: slot), "0x400 (1024 bytes)",
                       "its claimed size is still what the row says")
    }

    // MARK: - CSE Layout / BPDT

    func testCseLayoutRowsAndBootPartitionNesting() throws {
        let a = try analysis([
            "cseLayoutTable": ["offset": 0x0, "version": 0x17, "redundancy": true,
                               "checksumValid": true,
                               "partitions": [csePartitionJSON(name: "Data",
                                                               offset: 0x1000)]],
            "bootPartitions": [bpdtJSON()],
        ])
        let roots = MEACurator.present(a)
        let cse = roots[1]
        XCTAssertEqual(field("Checksum Valid", in: cse), "Yes")
        let data = try XCTUnwrap(child("Data", of: cse))
        XCTAssertEqual(data.range, 0x1000..<0x1400)
        XCTAssertEqual(field("Empty", in: data), "No")

        let boot = try XCTUnwrap(roots.first(where: { $0.title == "Boot Partitions (BPDT)" }))
        let bp1 = try XCTUnwrap(child("Boot 1", of: boot))
        XCTAssertEqual(field("Version", in: bp1), "IFWI 1.7")
        let ftpr = try XCTUnwrap(child("FTPR", of: bp1))
        XCTAssertEqual(field("Type", in: ftpr), "0x0002")
        XCTAssertEqual(ftpr.range, 0x59000..<0x17E000)
    }

    // MARK: - Code partition + manifest

    func testCodePartitionModulesAndExtensions() throws {
        let a = try analysis(["codePartition": cpdJSON()])
        let roots = MEACurator.present(a)
        let cpd = roots[1]
        XCTAssertEqual(cpd.subtitle, "FTPR · R1")
        XCTAssertEqual(field("Header", in: cpd), "R1")

        let modules = try XCTUnwrap(child("Modules", of: cpd))
        XCTAssertEqual(modules.subtitle, "1 module")
        let man = try XCTUnwrap(child("$MN2", of: modules))
        // Module offsets are relative to the $CPD base; the subtitle and range
        // are the absolute bytes (cp.offset + module.offset) the panel reveals.
        XCTAssertEqual(man.subtitle, "0x1010 · 0x284")
        XCTAssertEqual(man.range, 0x1010..<0x1294)

        let extensions = try XCTUnwrap(child("Extensions", of: cpd))
        let sys = try XCTUnwrap(child("Init Script", of: extensions))
        XCTAssertEqual(field("Tag", in: sys), "0x01")
        XCTAssertEqual(sys.range, 0x1040..<0x1048)
    }

    func testExtensionPayloadIsDumpedFieldByField() throws {
        let a = try analysis(["codePartition": cpdJSON(ext: 0x0F)])
        let roots = MEACurator.present(a)
        let cpd = roots[1]
        let extensions = try XCTUnwrap(child("Extensions", of: cpd))
        let sp = try XCTUnwrap(child("Signed Package", of: extensions))
        XCTAssertEqual(field("Tag", in: sp), "0x0F")
        // Payload fields surface under their own labels (reflect dump).
        XCTAssertEqual(field("partitionName", in: sp), "NVM0")
        XCTAssertEqual(field("arbSvn", in: sp), "6")
    }

    func testHuffmanModuleGetsNoRange() throws {
        var json = cpdJSON()
        var mods = json["modules"] as! [[String: Any]]
        mods[0]["isHuffman"] = true
        json["modules"] = mods
        let a = try analysis(["codePartition": json])
        let roots = MEACurator.present(a)
        let cpd = roots[1]
        let modules = try XCTUnwrap(child("Modules", of: cpd))
        let man = try XCTUnwrap(child("$MN2", of: modules))
        XCTAssertNil(man.range)
        XCTAssertEqual(man.subtitle, "0x284 (644 bytes)")
    }

    func testManifestFields() throws {
        let a = try analysis(["manifest": manifestJSON()])
        let roots = MEACurator.present(a)
        let m = roots[1]
        XCTAssertEqual(m.title, "Manifest")
        XCTAssertEqual(m.subtitle, "$MN2 · R1")
        XCTAssertEqual(field("Format", in: m), "R1")
        XCTAssertEqual(field("Version", in: m), "15.40.37.3121")
        XCTAssertEqual(field("Date", in: m), "2021-03-24")
        XCTAssertNil(m.range)
    }

    // MARK: - MFS

    func testMFSFilesAreListedWithoutRange() throws {
        let a = try analysis(["mfsVolume": mfsJSON()])
        let roots = MEACurator.present(a)
        let mfs = roots[1]
        XCTAssertEqual(mfs.title, "File System (MFS)")
        XCTAssertEqual(field("Page Size", in: mfs), "0x1000 (4096 bytes)")
        XCTAssertEqual(field("Signature Valid", in: mfs), "Yes")
        let files = try XCTUnwrap(child("Files", of: mfs))
        let f0 = try XCTUnwrap(child("File 0", of: files))
        XCTAssertEqual(field("Index", in: f0), "0")
        XCTAssertNil(f0.range)     // position is the FAT walk, not exposed
        XCTAssertNil(child("File 2", of: files))
    }

    // MARK: - Fact groups

    func testTheChecksumsRowWaitsWithPlaceholdersUntilItIsAskedFor() throws {
        let a = try analysis([:])
        let roots = MEACurator.present(a)
        let group = try XCTUnwrap(find("Checksums", in: roots))
        XCTAssertEqual(group.fields.map(\.label), ["SHA-256", "SHA-384", "CRC-32"])
        XCTAssertEqual(Set(group.fields.map(\.value)), [MEACurator.pendingValue])
        // The session finds the row by this path to know what to ask for.
        XCTAssertEqual(MEACurator.checksumsPath(in: roots), group.path)
    }

    func testTheChecksumsRowShowsTheNumbersOnceTheyArrive() throws {
        let a = try analysis(["checksums": ["sha256": "AA", "sha384": "BB",
                                            "crc32": 0x1234_5678]])
        let roots = MEACurator.present(a)
        let group = try XCTUnwrap(find("Checksums", in: roots))
        XCTAssertEqual(group.fields, [MEAField("SHA-256", "AA"),
                                      MEAField("SHA-384", "BB"),
                                      MEAField("CRC-32", "0x12345678")])
    }

    /// Asked for and unanswerable — an unreadable file — leaves an empty
    /// `Checksums`, and the row goes rather than promising numbers forever.
    func testAnAnsweredButEmptyChecksumsDropsTheRow() throws {
        let a = try analysis(["checksums": [:]])
        let roots = MEACurator.present(a)
        XCTAssertNil(find("Checksums", in: roots))
        XCTAssertNil(MEACurator.checksumsPath(in: roots))
    }

    func testIssuesAndMFSBackupAppearWhenPresent() throws {
        let a = try analysis([
            "issues": [["id": 1, "severity": "error", "message": "checksum mismatch"]],
            "mfsBackup": ["offset": 0x70000, "format": "r1",
                          "headerCRCStored": 0x1234ABCD, "headerCRCValid": true,
                          "reservedAllFF": false,
                          "headerRevision": 1, "headerRevisionValid": true,
                          "entries": [["fileIndex": 6, "blobOffset": 0x20,
                                       "blobSize": 0x100, "revision": 1,
                                       "revisionValid": true,
                                       "headerCRCStored": 0x1111,
                                       "headerCRCValid": true, "dataSize": 0x80,
                                       "dataCRCStored": 0x2222,
                                       "dataCRCValid": true]]],
        ])
        let roots = MEACurator.present(a)
        XCTAssertEqual(roots.map(\.title),
                       ["Firmware", "MFS Backup", "Checksums", "Issues"])

        let issues = try XCTUnwrap(find("Issues", in: roots))
        let issue = try XCTUnwrap(issues.children.first)
        XCTAssertEqual(issue.title, "Error")
        XCTAssertEqual(issue.subtitle, "checksum mismatch")

        let backup = try XCTUnwrap(find("MFS Backup", in: roots))
        XCTAssertEqual(backup.subtitle, "R1")
        let entry = try XCTUnwrap(child("Entry 6", of: backup))
        XCTAssertEqual(field("File", in: entry), "Intel Configuration")
    }

    // MARK: - Zones

    func testZoneForByteRangeAndEmptyOtherwise() throws {
        let a = try analysis([
            "regions": [regionJSON(name: "FTPR", offset: 0x1000, size: 0x1000)],
        ])
        let roots = MEACurator.present(a)
        let ftpr = try XCTUnwrap(child("FTPR", of: roots[1]))

        let map = MEAZones.build(focus: ftpr)
        XCTAssertEqual(map.zones.count, 1)
        XCTAssertEqual(map.focus, "1/0")
        XCTAssertEqual(map.zones[0].name, "FTPR")
        XCTAssertEqual(map.zones[0].range, 0x1000..<0x2000)

        XCTAssertTrue(MEAZones.build(focus: nil).zones.isEmpty)
        // A row without a range (a group, a manifest) never zones.
        XCTAssertTrue(MEAZones.build(focus: roots[0]).zones.isEmpty)
    }

    // MARK: - JSON pieces

    private func regionJSON(name: String, offset: Int, size: Int) -> [String: Any] {
        ["id": 0, "name": name, "offset": offset, "size": size, "flags": 0x8000]
    }

    private func csePartitionJSON(name: String, offset: Int) -> [String: Any] {
        ["id": 0, "name": name, "offset": offset, "size": 0x400, "empty": false]
    }

    private func bpdtJSON() -> [String: Any] {
        ["offset": 0x100, "partitionName": "Boot 1", "version": 2,
         "redundancy": true, "checksumValid": true,
         "entries": [["id": 0, "name": "FTPR", "type": 2, "offset": 0x59000,
                      "size": 0x125000, "empty": false]]]
    }

    private func cpdJSON(ext: Int? = nil) -> [String: Any] {
        // Extension offsets are already absolute in the model, like the module
        // base; 0x1000 is this fixture's $CPD base.
        var extensions: [[String: Any]] = [
            ["id": 0, "tag": 0x01, "size": 0x8, "offset": 0x1040],
        ]
        if ext == 0x0F {
            extensions = [["id": 1, "tag": 0x0F, "size": 0x34, "offset": 0x1048,
                           "signedPackage": ["partitionName": "NVM0", "vcn": 3,
                                             "usageBitmap": "", "arbSvn": 6]]]
        }
        return ["name": "FTPR", "offset": 0x1000, "headerVersion": 1,
                "headerLength": 0x10, "entryCount": 1, "checksumValid": true,
                "modules": [["id": 0, "name": "$MN2", "offset": 0x10,
                             "isHuffman": false, "size": 0x284]],
                "extensions": extensions]
    }

    private func manifestJSON() -> [String: Any] {
        ["offset": 0x1000, "tag": "$MN2", "format": "r1",
         "major": 15, "minor": 40, "hotfix": 37, "build": 3121, "svn": 3,
         "day": 24, "month": 3, "year": 2021,
         "keyHash": "ABCDEF", "signatureHash": "0123456789ABCDEF",
         "productionReady": true]
    }

    private func mfsJSON() -> [String: Any] {
        ["offset": 0x70000, "pageSize": 0x1000, "pageCount": 0x40,
         "systemPageCount": 1, "dataPageCount": 0x3F,
         "signatureValid": true, "volumeSize": 0x40000,
         "computedVolumeSize": 0x3E800, "fileRecordCount": 0x40,
         "usedFileCount": 3, "ftblDictionary": 0, "ftblPlatform": 0,
         "ftblReserved": 0, "usesFTBL": false, "presentFileCount": 1,
         "fileBytes": 0x200,
         "files": [["index": 0, "size": 0x200]],
         "configurations": [], "reservedIntegrity": []]
    }
}
