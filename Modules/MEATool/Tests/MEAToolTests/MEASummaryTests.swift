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
            "nvmCompatibility": 2,
            "sku": "Consumer H",
            "manufactureDate": referenceInterval(year: 2018, month: 5, day: 6),
            "mfsState": "initialized",
            "mfsVolume": mfsJSON(chipset: "CNP/CMP-H", steppings: "BA"),
            "bootPartitions": bootPartitionsJSON(),
            "firmwareSizeBytes": 0x27C000,
            "version": ["major": 15, "minor": 40, "hotfix": 37, "build": 3121,
                        "meMajor": 1, "meMinor": 4, "meHotfix": 0,
                        "meBuild": 14],
        ])
        let rows = tableRows(a)
        XCTAssertEqual(rows.map(\.label), [
            "Family", "Version", "Release", "Type", "SKU", "Chipset",
            "NVM Compatibility",
            "TCB Security Version Number", "ARB Security Version Number",
            "Version Control Number", "Production Ready", "OEM Configuration",
            "FWUpdate Support", "Date", "File System State", "Size",
            "Flash Image Tool", "Manifest Extension Utility",
        ])
        XCTAssertEqual(value("NVM Compatibility", in: rows), .value("SPI"))
        XCTAssertEqual(value("Manifest Extension Utility", in: rows),
                       .value("1.4.0.0014"))
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
                       .value("0x27C000 (2605056 bytes)"),
                       "the firmware's own end, not the region it sits in")
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

        // No initialisation table, but a recorded stepping: each letter of it
        // is a stepping of its own, as the console reads them.
        let stepped = try analysis([
            "manifest": manifestJSON(),
            "chipsetStepping": "BA",
        ])
        let rows = tableRows(stepped)
        XCTAssertEqual(value("Chipset Stepping", in: rows), .value("B, A"))
        XCTAssertNil(value("Chipset", in: rows))

        // Neither: upstream's own answer for a firmware whose database row
        // says nothing about its chipset.
        let neither = try analysis(["manifest": manifestJSON()])
        XCTAssertEqual(value("Chipset", in: tableRows(neither)), .value("Unknown"))
        XCTAssertNil(value("Chipset Stepping", in: tableRows(neither)))

        // And nothing at all on a file the engine could not name — there is no
        // family to gate the row on.
        let unnamed = try analysis(["chipsetStepping": "B"])
        XCTAssertNil(value("Chipset", in: tableRows(unnamed)))
        XCTAssertNil(value("Chipset Stepping", in: tableRows(unnamed)))

        // A family with no chipset row at all gets neither, promise included:
        // upstream gates the whole pair on a CS/PMC/GSC variant.
        let pchc = try analysis([
            "family": "pchc", "variant": "PCHC",
            "manifest": manifestJSON(),
            "mfsVolume": mfsJSON(chipset: "CNP/CMP-H", steppings: "BA"),
        ])
        XCTAssertNil(value("Chipset", in: tableRows(pchc)))
        XCTAssertNil(value("Chipset Stepping", in: tableRows(pchc)))
    }

    /// Row 18 is the firmware's own size — where it ends inside whatever
    /// carries it — and falls back to the analysed region's length only when
    /// the engine could not work that out.
    func testSizeRowPrefersTheFirmwaresOwnEnd() throws {
        let known = try analysis(["manifest": manifestJSON(),
                                  "firmwareSizeBytes": 0x27C000])
        XCTAssertEqual(value("Size", in: tableRows(known)),
                       .value("0x27C000 (2605056 bytes)"))

        let unknown = try analysis(["manifest": manifestJSON()])
        XCTAssertEqual(value("Size", in: tableRows(unknown)),
                       .value("0x200000 (2097152 bytes)"),
                       "no firmware end to read, so the row says how much was analysed")
    }

    /// Row 7 names the storage medium the firmware is built for, and only
    /// when the R2 signed-package extension named one: Undefined and a chain
    /// with no R2 extension at all leave the row off the table, exactly as the
    /// console's `nvm_db` gate does.
    func testNVMCompatibilityRowOnlyWhenAMediumIsNamed() throws {
        func nvmRow(_ raw: Int?) throws -> MEASummaryValue? {
            var fields: [String: Any] = ["manifest": manifestJSON()]
            if let raw { fields["nvmCompatibility"] = raw }
            return value("NVM Compatibility", in: tableRows(try analysis(fields)))
        }
        XCTAssertEqual(try nvmRow(1), .value("UFS"))
        XCTAssertEqual(try nvmRow(2), .value("SPI"))
        // Reserved: upstream's own wording for a value outside its map, so a
        // future medium reads as unknown rather than as UFS or SPI.
        XCTAssertEqual(try nvmRow(3), .value("Unknown (3)"))
        XCTAssertNil(try nvmRow(0), "Undefined is the state that prints no row")
        XCTAssertNil(try nvmRow(nil), "and so is an R1-only extension chain")
    }

    /// Row 20 appears only for a manifest actually built by MEU: an R0
    /// manifest carries no MEU block (the fields decode as nil) and the
    /// 0 / 0xFFFF majors are the markers upstream skips the row on.
    func testManifestExtensionUtilityRowOnlyForARealMEUStamp() throws {
        func meuRow(_ major: Int?) throws -> MEASummaryValue? {
            var version: [String: Any] = ["major": 15, "minor": 40,
                                          "hotfix": 37, "build": 3121]
            if let major {
                version["meMajor"] = major
                version["meMinor"] = 4
                version["meHotfix"] = 0
                version["meBuild"] = 14
            }
            return value("Manifest Extension Utility",
                         in: tableRows(try analysis(["manifest": manifestJSON(),
                                                     "version": version])))
        }
        XCTAssertEqual(try meuRow(1), .value("1.4.0.0014"))
        XCTAssertNil(try meuRow(0), "a zero major is the no-MEU marker")
        XCTAssertNil(try meuRow(0xFFFF), "and so is an erased one")
        XCTAssertNil(try meuRow(nil), "an R0 manifest has no MEU block")
    }

    /// Rows 13 and 21 are ME 7's: Patsburg support, and the two downgrade
    /// blacklists — where "Empty" is an answer, not a missing value.
    func testTheME7RowsAreME7s() throws {
        let seven = try analysis([
            "family": "me", "variant": "ME",
            "manifest": manifestJSON(),
            "version": ["major": 7, "minor": 1, "hotfix": 40, "build": 1214],
            "patsburgSupport": true,
            "downgradeBlacklist": ["sevenZero": ["minor": 0, "hotfix": 10,
                                                 "build": 1200]],
        ])
        let rows = tableRows(seven)
        XCTAssertEqual(value("Patsburg Support", in: rows), .value("Yes"))
        XCTAssertEqual(value("Downgrade Blacklist 7.0", in: rows),
                       .value("<= 7.0.10.1200"))
        XCTAssertEqual(value("Downgrade Blacklist 7.1", in: rows), .value("Empty"),
                       "nothing blacklisted on that line, which is what Empty says")

        // An ME 7 image the engine read no `$SKU` from promises the row rather
        // than answering "No".
        let unread = try analysis([
            "family": "me", "variant": "ME",
            "manifest": manifestJSON(),
            "version": ["major": 7, "minor": 1, "hotfix": 40, "build": 1214],
        ])
        XCTAssertEqual(value("Patsburg Support", in: tableRows(unread)), .comingSoon)
        XCTAssertEqual(value("Downgrade Blacklist 7.0", in: tableRows(unread)),
                       .value("Empty"))

        // ME 8 prints none of the three.
        let eight = try analysis([
            "family": "me", "variant": "ME",
            "manifest": manifestJSON(),
            "version": ["major": 8, "minor": 1, "hotfix": 40, "build": 1214],
            "patsburgSupport": true,
        ])
        XCTAssertNil(value("Patsburg Support", in: tableRows(eight)))
        XCTAssertNil(value("Downgrade Blacklist 7.0", in: tableRows(eight)))
    }

    /// Row 22 names the platform when the engine could name one, and is
    /// absent otherwise — the row the console prints only for a firmware whose
    /// chipset it did not learn from an initialisation table.
    func testChipsetSupportRowNamesThePlatformWhenThereIsOne() throws {
        let named = try analysis(["manifest": manifestJSON(),
                                  "platform": "ADP/RPP"])
        let rows = tableRows(named)
        XCTAssertEqual(value("Chipset Support", in: rows), .value("ADP/RPP"))
        XCTAssertEqual(rows.last?.label, "Chipset Support",
                       "and it closes the table, as it does in the console")

        XCTAssertNil(value("Chipset Support",
                           in: tableRows(try analysis(["manifest": manifestJSON()]))))
    }

    /// Rows 12a and 12b belong to CSME 11 alone: its Power Down Mitigation as
    /// the database records it, and the Workstation bit of its client
    /// system-information extension. Any other major prints neither.
    func testTheCSME11RowsAreCSME11sAlone() throws {
        let eleven = try analysis([
            "manifest": manifestJSON(),
            "version": ["major": 11, "minor": 8, "hotfix": 92, "build": 4222],
            "powerDownMitigation": "no",
            "workstationSupport": false,
        ])
        let rows = tableRows(eleven)
        XCTAssertEqual(value("Power Down Mitigation", in: rows), .value("No"))
        XCTAssertEqual(value("Workstation Support", in: rows), .value("No"))

        // The database's own "does not know" is printed, not hidden.
        let unsure = try analysis([
            "manifest": manifestJSON(),
            "version": ["major": 11, "minor": 8, "hotfix": 92, "build": 4222],
            "powerDownMitigation": "unknown2",
        ])
        XCTAssertEqual(value("Power Down Mitigation", in: tableRows(unsure)),
                       .value("Unknown 2"))

        // A silent database is a promise: the `bup` scan upstream falls back
        // to is not ported, so the row must not read "No".
        let silent = try analysis([
            "manifest": manifestJSON(),
            "version": ["major": 11, "minor": 8, "hotfix": 92, "build": 4222],
        ])
        XCTAssertEqual(value("Power Down Mitigation", in: tableRows(silent)),
                       .comingSoon)
        XCTAssertEqual(value("Workstation Support", in: tableRows(silent)),
                       .comingSoon)

        // CSME 12 prints neither row, whatever the model happens to carry.
        let twelve = try analysis([
            "manifest": manifestJSON(),
            "version": ["major": 12, "minor": 0, "hotfix": 3, "build": 1091],
            "powerDownMitigation": "no",
            "workstationSupport": true,
        ])
        XCTAssertNil(value("Power Down Mitigation", in: tableRows(twelve)))
        XCTAssertNil(value("Workstation Support", in: tableRows(twelve)))
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
        // A chipset row there is: with neither an initialisation table nor a
        // recorded stepping it reads "Unknown", which is what the console
        // says. The row whose gate the analysis cannot prove — no IFWI, no
        // real FIT — stays off the table entirely.
        XCTAssertEqual(value("Chipset", in: rows), .value("Unknown"))
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

    // MARK: - The independent firmware's own tables

    /// The console prints a table of its own for every independent firmware
    /// stitched into the image. This is the CSME-12 oracle's Power Management
    /// Controller, row for row and value for value as the original script
    /// prints it.
    func testThePMCBlockReadsAsTheConsolePrintsIt() throws {
        let pmc: [String: Any] = [
            "family": "pmc", "variant": "PMCCNP",
            "version": ["major": 300, "minor": 2, "hotfix": 11, "build": 1012],
            "release": "production", "type": "region",
            "sku": "H", "platform": "CNP", "chipsetStepping": "B",
            "securityVersion": "1", "arbSvn": 1, "vcn": 0,
            "manifest": manifestJSON(productionReady: false),
            "manufactureDate": referenceInterval(year: 2018, month: 3, day: 8),
            "sizeBytes": 0x14000,
            "regions": [], "issues": [],
        ]
        let a = try analysis(["manifest": manifestJSON(),
                              "version": ["major": 12, "minor": 0,
                                          "hotfix": 3, "build": 1091],
                              "independentFirmware": [pmc]])
        let blocks = MEASummary.build(a)
        XCTAssertEqual(blocks.count, 2, "the engine's table, then the PMC's")
        let block = blocks[1]
        XCTAssertEqual(block.title, "Power Management Controller")
        XCTAssertEqual(block.rows.map(\.label), [
            "Family", "Version", "Release", "Type", "Chipset SKU",
            "Chipset Stepping", "TCB Security Version Number",
            "ARB Security Version Number", "Version Control Number",
            "Production Ready", "Date", "Size", "Chipset Support",
        ])
        XCTAssertEqual(block.rows.map(\.value), [
            .value("PMC"), .value("300.2.11.1012"), .value("Production"),
            .value("Independent"), .value("H"), .value("B"), .value("1"),
            .value("1"), .value("0"), .value("No"), .value("2018-03-08"),
            .value("0x14000 (81920 bytes)"), .value("CNP"),
        ])
    }

    /// A PCHC has no SKU or stepping row; a PHY's SKU row is labelled just
    /// "SKU"; and both close with their own MEU stamp and chipset.
    func testThePCHCAndPHYBlocksKeepTheirOwnRowSets() throws {
        func firmware(_ family: String, _ variant: String, sku: String,
                      meu: Bool) -> [String: Any] {
            var version: [String: Any] = ["major": 15, "minor": 0,
                                          "hotfix": 0, "build": 1020]
            if meu {
                version["meMajor"] = 15
                version["meMinor"] = 0
                version["meHotfix"] = 30
                version["meBuild"] = 1659
            }
            return [
                "family": family, "variant": variant, "version": version,
                "release": "production", "type": "region",
                "sku": sku, "platform": "TGP",
                "securityVersion": "0", "arbSvn": 0, "vcn": 0,
                "manifest": manifestJSON(),
                "manufactureDate": referenceInterval(year: 2021, month: 3, day: 5),
                "sizeBytes": 0x1000, "regions": [], "issues": [],
            ]
        }
        let a = try analysis([
            "manifest": manifestJSON(),
            "independentFirmware": [
                firmware("pchc", "PCHCTGP", sku: "", meu: true),
                firmware("phy", "PHYNTGP", sku: "N", meu: false),
            ],
        ])
        let blocks = MEASummary.build(a)
        XCTAssertEqual(blocks.count, 3)

        XCTAssertEqual(blocks[1].title, "Platform Controller Hub Configuration")
        XCTAssertEqual(blocks[1].rows.map(\.label), [
            "Family", "Version", "Release", "Type",
            "TCB Security Version Number", "ARB Security Version Number",
            "Version Control Number", "Production Ready", "Date", "Size",
            "Manifest Extension Utility", "Chipset Support",
        ])
        XCTAssertEqual(value("Manifest Extension Utility", in: blocks[1].rows),
                       .value("15.0.30.1659"))

        XCTAssertEqual(blocks[2].title, "USB Type C Physical")
        XCTAssertEqual(value("SKU", in: blocks[2].rows), .value("N"))
        XCTAssertNil(value("Chipset SKU", in: blocks[2].rows))
        XCTAssertNil(value("Chipset Stepping", in: blocks[2].rows),
                     "a PHY has no stepping row")
        XCTAssertNil(value("Manifest Extension Utility", in: blocks[2].rows),
                     "and no MEU stamp on this one")
    }

    /// A discrete-graphics PMC has neither of the chipset rows, and a PMC
    /// whose stepping letter the engine could not read says so rather than
    /// leaving the row out.
    func testTheChipsetRowsOfAPMCFollowItsPlatform() throws {
        func rows(platform: String, stepping: String?,
                  hostMajor: Int = 12) throws -> [MEASummaryRow] {
            var pmc: [String: Any] = [
                "family": "pmc", "variant": "PMCDG2",
                "version": ["major": 4, "minor": 2, "hotfix": 0, "build": 1000],
                "release": "production", "type": "region",
                "sku": "H", "platform": platform,
                "manifest": manifestJSON(),
                "manufactureDate": referenceInterval(year: 2021, month: 3, day: 5),
                "sizeBytes": 0x1000, "regions": [], "issues": [],
            ]
            if let stepping { pmc["chipsetStepping"] = stepping }
            return MEASummary.build(try analysis([
                "manifest": manifestJSON(),
                "version": ["major": hostMajor, "minor": 0,
                            "hotfix": 3, "build": 1091],
                "independentFirmware": [pmc],
            ]))[1].rows
        }

        // A discrete-graphics PMC has no stepping row at all — but a CSME 12
        // or newer host prints the SKU row regardless of the platform, which
        // is upstream's own first leg of that gate.
        let discrete = try rows(platform: "DG2", stepping: "A")
        XCTAssertNil(value("Chipset Stepping", in: discrete))
        XCTAssertEqual(value("Chipset SKU", in: discrete), .value("H"))

        // Under an older host the platform decides, and a DG one has a single
        // chipset to say nothing about.
        let olderHost = try rows(platform: "DG2", stepping: "A", hostMajor: 11)
        XCTAssertNil(value("Chipset SKU", in: olderHost))
        XCTAssertNil(value("Chipset Stepping", in: olderHost))

        let unread = try rows(platform: "TGP", stepping: nil)
        XCTAssertEqual(value("Chipset Stepping", in: unread), .value("Unknown"))
        XCTAssertEqual(value("Chipset SKU", in: unread), .value("H"))
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
