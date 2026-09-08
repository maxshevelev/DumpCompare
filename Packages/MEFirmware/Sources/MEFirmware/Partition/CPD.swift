import Foundation

/// Code Partition Directory (`$CPD`) decode — Stage 1 only.
///
/// A `$CPD` is the directory Intel places at the start of each engine/IUP
/// partition (FTPR, RBEP, PMCP, …). It lists the partition's modules; the first
/// module of a boot partition is the `$MN2`/`$MAN` manifest whose owning CPD is
/// found by scanning a small window *before* the manifest. Phase 3 needs just
/// the header (`PartitionName` selects the operational copy) and the module
/// names (`ext_anl` `_Stage1` mode); extension blocks and offsets are the future
/// unpack/SKU port.
///
/// Faithful to upstream `MEA.py`:
/// - anchor `cpd_pat` (line 11012): `$CPD` + NumModules low byte + 3 zero bytes
///   + HeaderVersion `[\x01\x02]` + EntryVersion `\x01` + HeaderLength `[\x10\x14]`.
///   The match begins at the header base itself.
/// - `CPD_Header_R1` (line 1161, 0x10) vs `CPD_Header_R2` (line 1188, 0x14),
///   dispatched by `get_cpd` (line 9693) on the version byte at +0x08.
/// - `CPD_Entry` (line 1217, 0x18, identical both revisions): 12-byte `Name`,
///   `OffsetAttrib` u32 (+0x0C; `OffsetCPD` bits 0–24, `IsHuffman` bit 25,
///   per `CPD_Entry_OffsetAttrib` line 1248), `Size` u32 (+0x10).
/// - R1 checksum (line 0x0B) is Checksum-8 over header+entries with the field
///   zeroed (`cpd_chk`, line 9635). R2 carries a CRC-32 at +0x10 — validation
///   is deferred (`mc_chk32` is not ported yet), fields are parsed but not
///   checked.
struct CPDParser {
    static let tag = Data("$CPD".utf8)

    struct Header {
        var base: Int             // header base, region-relative
        var numModules: Int
        var headerVersion: Int    // 1 = R1, 2 = R2
        var entryVersion: Int
        var headerLength: Int     // 0x10 (R1) / 0x14 (R2)
        var partitionName: String
        /// Stored checksum field: R1 the byte at +0x0B, R2 the u32 at +0x10.
        /// Validation only implemented for R1 (R2 CRC-32 deferred).
        var checksumField: UInt32
    }

    struct Entry {
        var name: String          // NUL-padded 12 bytes, stripped
        var offsetAttrib: UInt32  // raw; bits 0–24 offset, bit 25 IsHuffman
        var offset: Int           // 25-bit OffsetCPD, region-relative from the CPD base
        var isHuffman: Bool
        var size: UInt32          // uncompressed size
    }

    /// Decode the `$CPD` header whose base sits at `offset` (region-relative).
    /// Mirrors `cpd_pat` + `get_cpd`: returns nil unless the tag, version,
    /// entry-version and header-length bytes all look like a real CPD.
    static func decodeHeader(in data: Data, at offset: Int) -> Header? {
        let p = data.startIndex + offset
        guard offset >= 0, p + 0x10 <= data.endIndex else { return nil }
        guard data.subdata(in: p..<(p + 4)) == tag else { return nil }

        let numModules = Int(u32le(data, p + 0x04))
        guard numModules >= 0, numModules < 0x0100_0000 else { return nil }  // high 3 bytes zero

        let headerVersion = Int(data[p + 0x08])
        guard (1...2).contains(headerVersion) else { return nil }

        let entryVersion = Int(data[p + 0x09])
        guard entryVersion == 1 else { return nil }

        let headerLength = Int(data[p + 0x0A])
        guard headerLength == 0x10 || headerLength == 0x14 else { return nil }

        // R2 stores a u32 checksum at +0x10; needing +0x14 of header data.
        if headerVersion == 2 {
            guard p + 0x14 <= data.endIndex else { return nil }
        }

        let nameBytes = data.subdata(in: (p + 0x0C)..<(p + 0x10))
        let partitionName = String(data: nameBytes, encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""

        let checksumField: UInt32 = headerVersion == 2
            ? u32le(data, p + 0x10)
            : UInt32(data[p + 0x0B])

        return Header(base: offset, numModules: numModules,
                      headerVersion: headerVersion, entryVersion: entryVersion,
                      headerLength: headerLength, partitionName: partitionName,
                      checksumField: checksumField)
    }

    /// Read the CPD entry table of `header` (whose base is `cpdBase`). Reads are
    /// bounded by the buffer — a truncated tail simply shortens the list (no
    /// `cpd_entry_num_fix` repair yet).
    static func entries(of header: Header, in data: Data, cpdBase: Int) -> [Entry] {
        guard header.numModules > 0 else { return [] }
        var out: [Entry] = []
        out.reserveCapacity(header.numModules)
        let table = data.startIndex + cpdBase + header.headerLength
        for index in 0..<header.numModules {
            let e = table + index * 0x18
            guard e + 0x18 <= data.endIndex else { break }
            let nameBytes = data.subdata(in: e..<(e + 12))
            let name = String(data: nameBytes, encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            let offsetAttrib = u32le(data, e + 0x0C)
            out.append(Entry(
                name: name,
                offsetAttrib: offsetAttrib,
                offset: Int(offsetAttrib & 0x01FF_FFFF),   // OffsetCPD: 25 bits
                isHuffman: offsetAttrib & 0x0200_0000 != 0, // IsHuffman: bit 25
                size: u32le(data, e + 0x10)
            ))
        }
        return out
    }

    /// Nearest well-formed `$CPD` header strictly before `base`, within the
    /// upstream backward-scan window (`ext_anl`, line 5896: max CPD size 0x2000,
    /// tag starts at manifest offset 0x1B → window ~0x201D). Returns the header
    /// closest to the manifest, or nil.
    static func findPrecedingCPD(in data: Data, before base: Int) -> (offset: Int, header: Header)? {
        guard base > 0, base <= data.count else { return nil }
        let start = data.startIndex + max(0, base - 0x201D)
        let end = data.startIndex + base
        var best: (offset: Int, header: Header)? = nil
        var scan = start
        while scan <= end - 4 {
            guard let found = data.range(of: tag, in: scan..<end) else { break }
            let offset = found.lowerBound - data.startIndex
            if let header = decodeHeader(in: data, at: offset) {
                best = (offset, header)   // later hit wins → nearest to the manifest
            }
            scan = found.lowerBound + 1
        }
        return best
    }

    /// R1 Checksum-8 validation (`cpd_chk`, line 9635): the stored byte at +0x0B
    /// must equal `(0x100 − sum) & 0xFF` over header+entries with the field
    /// zeroed. Returns nil for R2 (CRC-32 not ported yet).
    static func checksumValid(_ header: Header, in data: Data) -> Bool? {
        guard header.headerVersion == 1 else { return nil }
        let start = data.startIndex + header.base
        let fullEnd = start + header.headerLength + header.numModules * 0x18
        let end = min(fullEnd, data.endIndex)
        var sum = 0
        var idx = start
        while idx < end {
            sum += (idx == start + 0x0B) ? 0 : Int(data[idx])
            idx += 1
        }
        let calculated = (0x100 - (sum & 0xFF)) & 0xFF
        return calculated == Int(header.checksumField)
    }

    private static func u32le(_ data: Data, _ p: Int) -> UInt32 {
        UInt32(data[p])
            | (UInt32(data[p + 1]) << 8)
            | (UInt32(data[p + 2]) << 16)
            | (UInt32(data[p + 3]) << 24)
    }
}
