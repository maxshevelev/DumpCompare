import XCTest
import Foundation
@testable import MEFirmware

/// Composition helpers: a "CPD-headed partition" is one `$CPD` header (the
/// owning directory, whose PartitionName selects it) followed by a `$MN2`
/// manifest. Positions mirror real flashes — each engine partition carries its
/// own `$CPD` + `$MN2`, and a full flash usually has one internal-volume `$FPT`
/// that names none of the CSE boot partitions.
enum SelectionFixtures {
    /// One-module R1 `$CPD` (header + entry row) — the manifest sits right after.
    static func partition(named name: String) -> (data: Data, manifestBase: Int) {
        let cpd = CPDFixture.make(name: name)
        var data = cpd
        data.append(ManifestFixture.manifest())
        return (data, cpd.count)
    }

    /// A `$MN2` with no owning `$CPD` — only an `$FPT` engine partition can
    /// select it (priority 1), never the CPD-name fallback (priority 2).
    static func bareManifest() -> (data: Data, manifestBase: Int) {
        (ManifestFixture.manifest(), 0)
    }
}

final class ManifestSelectionTests: XCTestCase {
    private func select(in region: Data) throws -> ManifestParser.Manifest {
        let fpt = FPTParser.parseFirst(in: region)
        let chosen = try XCTUnwrap(
            ManifestSelection.selectOperational(candidates: ManifestParser.parseCandidates(in: region),
                                                fpt: fpt, in: region))
        return chosen
    }

    func testEngineFPTJumpsToFTPRPartitionEvenWithoutOwningCPD() throws {
        // Priority 1: an $FPT that names the FTPR engine partition must select
        // the manifest inside it, even though that copy has NO owning $CPD (so
        // priority 2 could never find it) and sits AFTER an RBEP CPD partition.
        let fptCount = 1
        let fptLen = 0x20 + fptCount * 0x20
        let rbe = SelectionFixtures.partition(named: "RBEP")
        let ftpr = SelectionFixtures.bareManifest()
        let ftprStart = fptLen + rbe.data.count

        var region = FPTFixture.fptRegion(entries: [
            ("FTPR", UInt32(ftprStart), UInt32(ftpr.data.count + 0x20), 0)
        ])
        region.append(rbe.data)
        region.append(ftpr.data)

        let chosen = try select(in: region)
        XCTAssertEqual(chosen.base, ftprStart, "FTPR $FPT partition must win over the earlier RBEP copy")
    }

    func testWholeFlashInternalFPTFallsBackToCPDOwnerRankingFTPR() throws {
        // Priority 2 (the real-dump case): the region's only $FPT lists internal
        // volumes (PSVN/MFS…) and contains no candidate, and there is both an
        // RBEP (earlier) and an FTPR (later) CPD-headed partition. FTPR must be
        // chosen over the RBEP recovery copy that comes first in file order.
        let internalFPT = FPTFixture.fptRegion(entries: [
            ("PSVN", 0x1000, 0x100, 0),
            ("MFS",  0x2000, 0x64000, 0),
        ])
        let rbe = SelectionFixtures.partition(named: "RBEP")
        let ftpr = SelectionFixtures.partition(named: "FTPR")

        var region = internalFPT
        region.append(rbe.data)
        region.append(ftpr.data)
        let ftprBase = internalFPT.count + rbe.data.count + ftpr.manifestBase

        let chosen = try select(in: region)
        XCTAssertEqual(chosen.base, ftprBase,
                       "CPD-owner fallback must rank the FTPR copy above the earlier RBEP copy")
    }

    func testRBEPOnlyRegionChoosesRBEP() throws {
        // CSME 18: the boot partition is renamed RBEP and no FTPR exists — the
        // RBEP arm of priority 2 must still resolve it.
        let rbe = SelectionFixtures.partition(named: "RBEP")
        let region = rbe.data

        let chosen = try select(in: region)
        XCTAssertEqual(chosen.base, rbe.manifestBase)
    }

    func testUnknownOwnerFallsBackToFirstCandidate() throws {
        // A lone non-engine partition (PMCP) has no FPT/CPD engine context —
        // priority 3 returns the first (only) candidate, preserving parseFirst.
        let pmcp = SelectionFixtures.partition(named: "PMCP")
        let chosen = try select(in: pmcp.data)
        XCTAssertEqual(chosen.base, pmcp.manifestBase)
    }

    func testEmptyRegionSelectsNothing() {
        let region = Data(repeating: 0xFF, count: 0x300)
        XCTAssertNil(ManifestSelection.selectOperational(
            candidates: ManifestParser.parseCandidates(in: region),
            fpt: nil, in: region))
    }

    func testCODEPartitionAcceptedWhenNoRCVYOrCOD1() throws {
        // Upstream accepts CODE only when RCVY/COD1 are absent. An FPT with a
        // CODE partition (covering the later copy) and an earlier RBEP CPD
        // partition: CODE must win (it is not the first candidate).
        let fptCount = 1
        let fptLen = 0x20 + fptCount * 0x20
        let rbe = SelectionFixtures.partition(named: "RBEP")
        let codeMan = SelectionFixtures.bareManifest()
        let codeStart = fptLen + rbe.data.count

        var region = FPTFixture.fptRegion(entries: [
            ("CODE", UInt32(codeStart), UInt32(codeMan.data.count + 0x20), 0)
        ])
        region.append(rbe.data)
        region.append(codeMan.data)

        let chosen = try select(in: region)
        XCTAssertEqual(chosen.base, codeStart, "CODE is accepted when no RCVY/COD1 partition exists")
    }

    func testCODEPartitionRejectedWhenRCVYPresent() throws {
        // Same shape but the FPT also has an RCVY partition (containing no
        // candidate): CODE is rejected, so priority 2's RBEP arm resolves.
        let fptCount = 2
        let fptLen = 0x20 + fptCount * 0x20
        let rbe = SelectionFixtures.partition(named: "RBEP")
        let codeMan = SelectionFixtures.bareManifest()
        let rbeStart = fptLen
        let codeStart = fptLen + rbe.data.count

        var region = FPTFixture.fptRegion(entries: [
            ("RCVY", UInt32(rbeStart), 0x10, 0),                       // empty RCVY
            ("CODE", UInt32(codeStart), UInt32(codeMan.data.count + 0x20), 0),
        ])
        region.append(rbe.data)
        region.append(codeMan.data)

        let chosen = try select(in: region)
        XCTAssertEqual(chosen.base, rbeStart + rbe.manifestBase,
                       "CODE is rejected when an RCVY partition exists")
    }
}
