import XCTest
import MEFirmware
@testable import MEATool

/// `MEASummary` — the pure builder behind the «Summary» tab: the primary
/// Field/Value table of MEA's console default output, then the analysis's
/// messages. Fixtures are decoded JSON, exactly as in `MEACuratorTests`, so the
/// tests exercise the same path the engine hands the module: a decoded
/// `FirmwareAnalysis`.
final class MEASummaryTests: XCTestCase {
    // MARK: - Fixtures

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

    /// The primary table — always the first block, which carries no title.
    private func tableRows(_ a: FirmwareAnalysis) -> [MEASummaryRow] {
        MEASummary.build(a)[0].rows
    }

    private func value(_ label: String, in rows: [MEASummaryRow]) -> MEASummaryValue? {
        rows.first { $0.label == label }?.value
    }

    private func tone(_ label: String, in rows: [MEASummaryRow]) -> MEASummaryTone? {
        rows.first { $0.label == label }?.tone
    }

    /// Seconds since the Cocoa reference date (the engine's own decode domain)
    /// for a calendar date — what `manufactureDate` carries in a fixture.
    private func referenceInterval(year: Int, month: Int, day: Int) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)!.timeIntervalSinceReferenceDate
    }

    private func manifestJSON(productionReady: Bool? = true) -> [String: Any] {
        var manifest: [String: Any] = [
            "offset": 0x1000, "tag": "$MN2", "format": "r1",
            "major": 15, "minor": 40, "hotfix": 37, "build": 3121, "svn": 3,
            "day": 24, "month": 3, "year": 2021,
            "keyHash": "ABCDEF", "signatureHash": "0123456789ABCDEF",
        ]
        if let productionReady { manifest["productionReady"] = productionReady }
        return manifest
    }

    /// A full MFS volume, with the pch_init aggregation's `chipsets` when the
    /// analysis carried a Chipset Initialization decode.
    private func mfsJSON(chipset: String? = nil, steppings: String = "") -> [String: Any] {
        var volume: [String: Any] = [
            "offset": 0x70000, "pageSize": 0x1000, "pageCount": 0x40,
            "systemPageCount": 1, "dataPageCount": 0x3F,
            "signatureValid": true, "volumeSize": 0x40000,
            "computedVolumeSize": 0x3E800, "fileRecordCount": 0x40,
            "usedFileCount": 3, "ftblDictionary": 0, "ftblPlatform": 0,
            "ftblReserved": 0, "usesFTBL": false, "presentFileCount": 1,
            "fileBytes": 0x200,
            "files": [["index": 0, "size": 0x200]],
            "configurations": [], "reservedIntegrity": [],
        ]
        if let chipset {
            volume["pchInit"] = ["records": [],
                                 "chipsets": [["chipset": chipset,
                                               "steppings": steppings]]]
        }
        return volume
    }

    /// A whole-flash IFWI carries Boot Partitions — the gate for the Flash
    /// Image Tool row. This boot's BPDT header carries a real FIT version
    /// (12.0.3.1091), so the row reads it.
    private func bootPartitionsJSON() -> [[String: Any]] {
        [["offset": 0x100, "partitionName": "Boot 1", "version": 2,
          "redundancy": true, "checksumValid": true,
          "fitMajor": 12, "fitMinor": 0, "fitHotfix": 3, "fitBuild": 1091,
          "entries": []]]
    }

    /// The same whole-flash shape but with a no-FIT BPDT header — a decoded
    /// 0/0xFFFF marker yields a nil quartet, which JSON encodes as *absent* —
    /// so the Flash Image Tool row then reads "N/A".
    private func bootPartitionsNoFITJSON() -> [[String: Any]] {
        [["offset": 0x100, "partitionName": "Boot 1", "version": 2,
          "redundancy": true, "checksumValid": true, "entries": []]]
    }

    // MARK: - The primary table, filled in

    /// An identified CSME-12-style image with every fact the engine has today:
    /// the table reads as MEA's ledger in order — real values where the bridge
    /// reaches, "coming soon" for the rows it does not answer yet.
    func testAnIdentifiedImageReadsInLedgerOrder() throws {
        let a = try analysis([
            "manifest": manifestJSON(),
            "securityVersion": "1",
            "arbSvn": 2,
            "vcn": 7,
            "sku": "Consumer H",
            "manufactureDate": referenceInterval(year: 2018, month: 5, day: 6),
            "mfsState": "initialized",
            "mfsVolume": mfsJSON(chipset: "CNP/CMP-H", steppings: "BA"),
            "bootPartitions": bootPartitionsJSON(),
        ])
        let rows = tableRows(a)
        XCTAssertEqual(rows.map(\.label), [
            "Family", "Version", "Release", "Type", "SKU", "Chipset",
            "TCB Security Version Number", "ARB Security Version Number",
            "Version Control Number", "Production Ready", "OEM Configuration",
            "FWUpdate Support", "Date", "File System State", "Size",
            "Flash Image Tool",
        ])
        XCTAssertEqual(value("Family", in: rows), .value("CSME"))
        XCTAssertEqual(value("Version", in: rows), .value("15.40.37.3121"))
        XCTAssertEqual(value("Release", in: rows), .value("Production"))
        XCTAssertEqual(value("Type", in: rows), .comingSoon)
        XCTAssertEqual(value("SKU", in: rows), .value("Consumer H"))
        // The pch_init aggregation's "BA" is comma-joined, like the console.
        XCTAssertEqual(value("Chipset", in: rows), .value("CNP/CMP-H B,A"))
        XCTAssertEqual(value("TCB Security Version Number", in: rows), .value("1"))
        XCTAssertEqual(value("ARB Security Version Number", in: rows), .value("2"))
        XCTAssertEqual(value("Version Control Number", in: rows), .value("7"))
        XCTAssertEqual(value("Production Ready", in: rows), .value("Yes"))
        XCTAssertEqual(value("OEM Configuration", in: rows), .comingSoon)
        XCTAssertEqual(value("FWUpdate Support", in: rows), .comingSoon)
        XCTAssertEqual(value("Date", in: rows), .value("2018-05-06"))
        XCTAssertEqual(value("File System State", in: rows), .value("Initialized"))
        XCTAssertEqual(value("Size", in: rows),
                       .value("0x200000 (2097152 bytes)"))
        // Row 19 reads the boot BPDT's FIT version (plain CSME format).
        XCTAssertEqual(value("Flash Image Tool", in: rows), .value("12.0.3.1091"))
        // A derived stepping letter was not present, so the row is not there.
        XCTAssertNil(value("Chipset Stepping", in: rows))
    }

    /// Row 4 shows the classifier's Stock / Update / Extracted word when the
    /// type is on that axis; `.region` and `.unknown` keep the row grey.
    func testTypeRowReflectsClassifierAxis() throws {
        func typeRow(_ raw: String) throws -> MEASummaryValue? {
            value("Type", in: tableRows(try analysis([
                "manifest": manifestJSON(),
                "type": raw,
            ])))
        }
        XCTAssertEqual(try typeRow("extracted"), .value("Extracted"))
        XCTAssertEqual(try typeRow("stock"), .value("Stock"))
        XCTAssertEqual(try typeRow("update"), .value("Update"))
        XCTAssertEqual(try typeRow("region"), .comingSoon)
        XCTAssertEqual(try typeRow("unknown"), .comingSoon)
        // An unidentified image gets no Type row at all (the identified gate).
        XCTAssertNil(value("Type", in: tableRows(try analysis(["type": "extracted"]))))
    }

    /// Row 14 answers the OEM detector's Yes/No — but only for the OEM-axis
    /// families; an identified image of another family omits the row entirely.
    func testOEMConfigurationRowSaysYesOrNo() throws {
        let yes = try analysis(["manifest": manifestJSON(), "oemCustomized": true])
        XCTAssertEqual(value("OEM Configuration", in: tableRows(yes)),
                       .value("Yes"))
        let no = try analysis(["manifest": manifestJSON(), "oemCustomized": false])
        XCTAssertEqual(value("OEM Configuration", in: tableRows(no)),
                       .value("No"))
        // A nil detector story (the fixture omits oemCustomized) stays grey.
        let nilCase = try analysis(["manifest": manifestJSON()])
        XCTAssertEqual(value("OEM Configuration", in: tableRows(nilCase)),
                       .comingSoon)
        // ME is not an OEM-axis family: even signed, the row is off the table.
        let me = try analysis([
            "family": "me", "variant": "ME",
            "manifest": manifestJSON(), "oemCustomized": true,
        ])
        XCTAssertNil(value("OEM Configuration", in: tableRows(me)))
    }

    /// Row 19 with a boot BPDT whose header carries no real FIT reads "N/A",
    /// exactly like upstream's BPDT header print.
    func testFlashImageToolRowShowsNAWithoutARealFIT() throws {
        let a = try analysis([
            "manifest": manifestJSON(),
            "bootPartitions": bootPartitionsNoFITJSON(),
        ])
        XCTAssertEqual(value("Flash Image Tool", in: tableRows(a)), .value("N/A"))
    }

    /// Row 19 on a *non-IFWI* image (no boot BPDT) reads the `$FPT` header's
    /// FIT — the value upstream prints from the real-FIT Extracted branch
    /// (`fptHeaderFIT`, MEA.py 12581–12586). The fixture has no
    /// `bootPartitions`, so only the header FIT can feed the row.
    func testFlashImageToolRowReadsNonIFWIFPTHeaderFIT() throws {
        let a = try analysis([
            "manifest": manifestJSON(),
            "fptHeaderFIT": ["major": 11, "minor": 0, "hotfix": 10, "build": 1002],
        ])
        XCTAssertEqual(value("Flash Image Tool", in: tableRows(a)),
                       .value("11.0.10.1002"))
    }

    /// A non-IFWI image without a header FIT — Stock / Update / SPS / ME 2–7,
    /// or a marker-FIT Extracted leg — keeps the row off the table entirely:
    /// upstream never prints row 19 there (no `fitc_ver_found`), unlike the
    /// IFWI "N/A" a decoded-but-FIT-less boot BPDT reads.
    func testFlashImageToolRowAbsentOnNonIFWIWithoutFIT() throws {
        let a = try analysis(["manifest": manifestJSON()])
        XCTAssertNil(value("Flash Image Tool", in: tableRows(a)))
    }

    /// The File System State row's tone is its status: both settled states read
    /// green, an in-progress volume brown, a failed decode red — every other row
    /// stays standard.
    func testFileSystemStateCarriesItsStatusTone() throws {
        func state(_ raw: String) throws -> [MEASummaryRow] {
            tableRows(try analysis([
                "manifest": manifestJSON(),
                "mfsState": raw,
            ]))
        }
        XCTAssertEqual(value("File System State", in: try state("unconfigured")),
                       .value("Unconfigured"))
        XCTAssertEqual(tone("File System State", in: try state("unconfigured")),
                       .good)
        XCTAssertEqual(value("File System State", in: try state("configured")),
                       .value("Configured"))
        XCTAssertEqual(tone("File System State", in: try state("configured")),
                       .good)
        XCTAssertEqual(value("File System State", in: try state("initialized")),
                       .value("Initialized"))
        XCTAssertEqual(tone("File System State", in: try state("initialized")),
                       .caution)
        XCTAssertEqual(value("File System State", in: try state("error")),
                       .value("Error"))
        XCTAssertEqual(tone("File System State", in: try state("error")), .bad)
        // Rows without a status to say stay standard.
        XCTAssertEqual(tone("Family", in: try state("configured")), .standard)
    }

    /// A chipset with no stepping letters is the plain chipset label, and a
    /// derived stepping letter stands on its own row.
    func testChipsetRowsWhenThereAreLettersOrNot() throws {
        let bare = try analysis([
            "manifest": manifestJSON(),
            "mfsVolume": mfsJSON(chipset: "CNP/CMP-H", steppings: ""),
        ])
        XCTAssertEqual(value("Chipset", in: tableRows(bare)),
                       .value("CNP/CMP-H"))

        let stepped = try analysis([
            "chipsetStepping": "B",
        ])
        let rows = tableRows(stepped)
        XCTAssertEqual(value("Chipset Stepping", in: rows), .value("B"))
        XCTAssertNil(value("Chipset", in: rows))
    }

    /// Engineering builds say so on the Release row, like MEA.
    func testEngineeringSuffixOnRelease() throws {
        let a = try analysis([
            "version": ["major": 12, "minor": 0, "hotfix": 3, "build": 7000],
        ])
        XCTAssertEqual(value("Release", in: tableRows(a)),
                       .value("Production, Engineering"))
    }

    // MARK: - What is promised and what is kept off the table

    /// An identified image the engine has few facts for shows the whole road:
    /// every ledger row MEA would print is there, as "coming soon" — never
    /// hidden, and never lied about.
    func testIdentifiedWithoutFactsPromisesEveryPendingRow() throws {
        let a = try analysis([
            "manifest": manifestJSON(productionReady: nil),
        ])
        let rows = tableRows(a)
        let labels = rows.map(\.label)
        XCTAssertTrue(labels.contains("Type"))
        XCTAssertTrue(labels.contains("SKU"))
        XCTAssertTrue(labels.contains("TCB Security Version Number"))
        XCTAssertTrue(labels.contains("ARB Security Version Number"))
        XCTAssertTrue(labels.contains("Version Control Number"))
        XCTAssertTrue(labels.contains("Production Ready"))
        XCTAssertTrue(labels.contains("OEM Configuration"))
        XCTAssertTrue(labels.contains("FWUpdate Support"))
        XCTAssertTrue(labels.contains("Date"))
        XCTAssertTrue(labels.contains("File System State"))
        XCTAssertEqual(value("SKU", in: rows), .comingSoon)
        XCTAssertEqual(value("TCB Security Version Number", in: rows), .comingSoon)
        XCTAssertEqual(value("ARB Security Version Number", in: rows), .comingSoon)
        XCTAssertEqual(value("Version Control Number", in: rows), .comingSoon)
        XCTAssertEqual(value("Production Ready", in: rows), .comingSoon)
        XCTAssertEqual(value("Date", in: rows), .comingSoon)
        XCTAssertEqual(value("File System State", in: rows), .comingSoon)
        // Rows whose gate the analysis cannot prove are off the table entirely:
        // no pch_init, no IFWI → no Chipset / Flash Image Tool row.
        XCTAssertNil(value("Chipset", in: rows))
        XCTAssertNil(value("Flash Image Tool", in: rows))
        XCTAssertEqual(value("Family", in: rows), .value("CSME"))
        XCTAssertEqual(value("Version", in: rows), .value("15.40.37.3121"))
        XCTAssertEqual(value("Release", in: rows), .value("Production"))
        XCTAssertEqual(value("Size", in: rows),
                       .value("0x200000 (2097152 bytes)"))
    }

    /// An unidentified file — a pure FPT region, say — gets no roadmap of
    /// promised rows: only what the engine could honestly say.
    func testUnidentifiedImageShowsOnlyRealRows() throws {
        let a = try analysis([:])
        let rows = tableRows(a)
        XCTAssertEqual(rows.map(\.label), ["Family", "Version", "Release", "Size"])
        for row in rows {
            guard case .value = row.value else {
                return XCTFail("unidentified row \(row.label) is promised: \(row.value)")
            }
        }
    }

    // MARK: - The messages block

    func testIssuesBecomeAMessagesBlockAfterTheTable() throws {
        let a = try analysis([
            "issues": [["id": 1, "severity": "error", "message": "checksum mismatch"],
                       ["id": 2, "severity": "note", "message": "odd padding"]],
        ])
        let blocks = MEASummary.build(a)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertNil(blocks[0].title)
        XCTAssertEqual(blocks[1].title, "Messages")
        XCTAssertEqual(blocks[1].rows.map(\.label), ["Error", "Note"])
        XCTAssertEqual(blocks[1].rows.map(\.value),
                       [.value("checksum mismatch"), .value("odd padding")])
    }

    func testNoIssuesNoMessagesBlock() throws {
        let a = try analysis([:])
        XCTAssertEqual(MEASummary.build(a).count, 1)
    }
}
