import Foundation

/// GSC "INFO" `$FPT` partition decode — a faithful port of upstream `info_anl`
/// (MEA.py 9134) reading the `GSC_Info_FWI` image header (MEA.py 358) plus the
/// list of `GSC_Info_IUP` partition descriptors (MEA.py 410) that follow it.
///
/// Upstream walks the partitions of a GSC-family image and dispatches one named
/// "INFO" here: it reads a u32 revision at the partition base (anything but 1 is
/// an "Unknown GSC Information Partition Revision" error, but decoding still
/// continues), then treats the following bytes as one `GSC_Info_FWI` (0x20)
/// followed by as many 0x10 `GSC_Info_IUP` rows as fit to the partition end
/// (`iup_count = (len - 0x20) // 0x10`). Only GSC-family images name an FPT
/// partition "INFO", so the name gates the decode.
///
/// Surfaced as `FirmwareAnalysis.gscInfo` (upstream-map row 79). No real GSC
/// dump exists among the engine's oracles — exercised by fixtures only.
enum GSCInfoParser {
    /// Decode the FPT partition at region-relative `offset` spanning `size`.
    /// `baseOffset` shifts the reported absolute partition base. Returns nil
    /// when the partition cannot hold even the revision + `GSC_Info_FWI`
    /// (out of bounds or too short to be a genuine INFO partition).
    static func decode(in region: Data,
                       offset: Int,
                       size: Int,
                       baseOffset: Int = 0) -> GSCInfo? {
        let hi = min(offset + size, region.count)
        // Revision u32 then a full 0x20 image header must be in bounds.
        guard offset >= 0, offset + 4 + 0x20 <= hi else { return nil }

        let revision = Int(u32le(region, offset))
        var body = offset + 4

        let image = decodeImage(in: region, at: body)
        body += 0x20

        var rows: [GSCIUPPartition] = []
        while body + 0x10 <= hi {
            rows.append(decodeIUP(in: region, at: body, id: rows.count))
            body += 0x10
        }

        return GSCInfo(
            offset: baseOffset + offset,
            revision: revision,
            revisionValid: revision == 1,
            image: image,
            iupPartitions: rows)
    }

    /// GSC_Info_FWI (MEA.py 358): Project[4] @0x00 / Hotfix u16 0x04 / Build u16
    /// 0x06 / GSCMajor u16 0x08 / GSCMinor u16 0x0A / GSCHotfix u16 0x0C /
    /// GSCBuild u16 0x0E / Flags u16 0x10 / FWType u8 0x12 / FWSKU u8 0x13 /
    /// ARBSVN u32 0x14 / TCBSVN u32 0x18 / VCN u32 0x1C.
    private static func decodeImage(in region: Data, at p: Int) -> GSCFirmwareImage {
        GSCFirmwareImage(
            project: asciiName(in: region, at: p + 0x00, length: 4),
            hotfix: Int(u16le(region, p + 0x04)),
            build: Int(u16le(region, p + 0x06)),
            gscMajor: Int(u16le(region, p + 0x08)),
            gscMinor: Int(u16le(region, p + 0x0A)),
            gscHotfix: Int(u16le(region, p + 0x0C)),
            gscBuild: Int(u16le(region, p + 0x0E)),
            flags: u16le(region, p + 0x10),
            fwType: region[p + 0x12],
            fwSku: region[p + 0x13],
            arbSvn: u32le(region, p + 0x14),
            tcbSvn: u32le(region, p + 0x18),
            vcn: u32le(region, p + 0x1C))
    }

    /// GSC_Info_IUP (MEA.py 410): Name[4] @0x00 / Flags u16 0x04 / Reserved u16
    /// 0x06 / SVN u32 0x08 / VCN u32 0x0C.
    private static func decodeIUP(in region: Data, at p: Int, id: Int) -> GSCIUPPartition {
        GSCIUPPartition(
            id: id,
            name: asciiName(in: region, at: p + 0x00, length: 4),
            flags: u16le(region, p + 0x04),
            reserved: u16le(region, p + 0x06),
            svn: u32le(region, p + 0x08),
            vcn: u32le(region, p + 0x0C))
    }

    // MARK: - Byte / string helpers

    private static func u16le(_ data: Data, _ p: Int) -> UInt16 {
        UInt16(data[p]) | (UInt16(data[p + 1]) << 8)
    }

    private static func u32le(_ data: Data, _ p: Int) -> UInt32 {
        UInt32(data[p])
            | (UInt32(data[p + 1]) << 8)
            | (UInt32(data[p + 2]) << 16)
            | (UInt32(data[p + 3]) << 24)
    }

    private static func asciiName(in data: Data, at p: Int, length: Int) -> String {
        guard p + length <= data.count else { return "" }
        let trimmed = data.subdata(in: p..<(p + length)).filter { $0 != 0 }
        return String(data: trimmed, encoding: .ascii) ?? ""
    }
}
