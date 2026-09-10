import Foundation

/// Row-14 "OEM Configuration" detector — a faithful port of upstream's single
/// bool `oem_signed or oemp_found or utok_found` (MEA.py 13725). Three
/// independent facts, each read from a different corner of the image, are
/// folded into one answer:
///
/// - `oem_signed` (MEA.py 6015–6016, in `cse_unpack`): the operational code
///   partition's `$CPD` carries an `oem.key` module whose body is a *real*
///   OEM RSA key — non-empty and not an Intel "OEM" placeholder. Upstream reads
///   the raw stored bytes here (no Huffman decompression precedes the check)
///   because Intel ships the stock placeholder key uncompressed, so the
///   placeholder's VEN_ID 0xBCCB is visible in the raw body. A Huffman-packed
///   `oem.key` would therefore be detected exactly as upstream detects it —
///   nothing is deferred to a dictionary.
/// - `oemp_found` / `utok_found`: a non-empty `OEMP` / `UTOK`|`STKN` partition
///   whose leading 0x10 bytes are not erased (11786–11790 on the region's own
///   `$FPT` inventory, 12129–12133 on the IFWI boot-slot BPDT inventories). An
///   `OEMP` additionally must not open with the BCCB placeholder.
///
/// The detector is always decidable from bytes — it returns false (stock) when
/// none of the three facts has positive evidence, matching upstream's default
/// `False` on a plain Intel image. It needs no database and no Huffman
/// dictionary. `bccb_pat` (MEA.py 11009) is the Intel placeholder key's
/// signature: VEN_ID 0xBCCB little-endian, nine wildcard bytes, a NUL, then the
/// key's `$MN2` recovery-manifest trailer.
enum OEMDetector {
    /// One non-empty `OEMP`/`UTOK`/`STKN` partition candidate. `offset` is
    /// region-relative (how the region buffer is read); the FPT inventory is
    /// already region-relative, the BPDT inventory stores absolute offsets that
    /// the caller normalises by subtracting `baseOffset`.
    private struct PartitionRef {
        let name: String
        let empty: Bool
        let offset: Int
        let size: Int
    }

    /// The row-14 answer: true when any OEM signature / populated partition
    /// gives positive evidence, false otherwise. `fpt` covers extracted/region
    /// images whose `$FPT` lists the OEM partitions directly; `bootPartitions`
    /// covers whole-flash images where they sit inside the IFWI boot-slot
    /// BPDT tables; `codePartition` supplies the `oem.key` module.
    static func oemCustomized(fpt: FPTParser.Result?,
                              bootPartitions: [BPDT]?,
                              codePartition: CodePartition?,
                              in region: Data, baseOffset: Int) -> Bool {
        oemKeySigned(codePartition, in: region, baseOffset: baseOffset)
            || oemOrUnlockPartition(
                fpt: fpt, bootPartitions: bootPartitions,
                in: region, baseOffset: baseOffset)
    }

    /// Upstream `oem_config` (MEA.py 6014): the operational `$CPD` carries a
    /// non-empty `fitc.cfg` module — the configuration the Flash Image Tool
    /// writes. It is *not* part of row 14's answer, which folds only
    /// `oem_signed or oemp_found or utok_found`; it is one of the four things
    /// that raise the File System State to Configured (13051).
    static func fitConfiguration(_ codePartition: CodePartition?,
                                 in region: Data, baseOffset: Int) -> Bool {
        guard let cp = codePartition else { return false }
        return cp.modules.contains { module in
            module.name == "fitc.cfg"
                && populatedBody(of: module, in: cp, region: region,
                                 baseOffset: baseOffset) != nil
        }
    }

    /// The region range of a `$CPD` module's stored body, or nil when the
    /// module is upstream's `entry_empty` (5981): a zero size, an offset past
    /// the end of the image, or an entirely erased full-size body. A body
    /// truncated at EOF is not erased — Python's short-slice comparison never
    /// equals the `FF * size` fill either.
    private static func populatedBody(of module: CPDModule, in cp: CodePartition,
                                      region: Data, baseOffset: Int) -> Range<Int>? {
        guard module.size > 0 else { return nil }
        let base = cp.offset - baseOffset + module.offset
        guard base >= 0, base < region.count else { return nil }
        let end = min(base + module.size, region.count)
        if end - base == module.size, allErased(region, base..<end) { return nil }
        return base..<end
    }

    // MARK: - oem_signed (the oem.key module)

    /// Upstream 6015–6016: an `oem.key` `$CPD` module is a signing key when it
    /// is not empty and its body does not open with the Intel BCCB placeholder.
    /// The body is read raw from the region at the module's offset for its
    /// declared (uncompressed) size — the same slice upstream's `entry_data`
    /// uses, so a compressed body would behave exactly as it does there.
    /// `codePartition.offset` is absolute (baseOffset + header base), so the
    /// region-relative module base is `codePartition.offset - baseOffset +
    /// module.offset`, the same coordinate the RBE/PM reader uses.
    private static func oemKeySigned(_ codePartition: CodePartition?,
                                     in region: Data, baseOffset: Int) -> Bool {
        guard let cp = codePartition else { return false }
        for module in cp.modules where module.name == "oem.key" {
            // entry_empty (5981): a zero size, an all-erased body, or an offset
            // at/past the end of the file → empty, no signing key.
            guard let body = populatedBody(of: module, in: cp, region: region,
                                           baseOffset: baseOffset)
            else { continue }

            // A real key body does not open with the placeholder signature.
            if containsPlaceholder(region,
                                   body.lowerBound..<min(body.lowerBound + 0x50,
                                                         body.upperBound)) {
                continue
            }
            return true
        }
        return false
    }

    // MARK: - oemp_found / utok_found (partition scan)

    /// Upstream 11786–11790 and 12129–12133, over the two partition
    /// inventories: a non-empty `OEMP` / `UTOK`|`STKN` whose leading 0x10 are
    /// not erased, with `OEMP`'s opening 0x50 additionally free of the BCCB
    /// placeholder.
    private static func oemOrUnlockPartition(fpt: FPTParser.Result?,
                                             bootPartitions: [BPDT]?,
                                             in region: Data,
                                             baseOffset: Int) -> Bool {
        var found = false
        func consider(_ ref: PartitionRef) {
            guard !found else { return }
            guard ref.name == "OEMP" || ref.name == "UTOK" || ref.name == "STKN"
            else { return }
            guard !ref.empty, ref.size > 0 else { return }
            guard ref.offset >= 0, ref.offset < region.count else { return }
            // Upstream compares a full 0x10 slice against `FF * 0x10`; only an
            // entirely-erased full window disqualifies the partition, so a
            // truncated (EOF) head stays a candidate.
            guard !headErased(region, from: ref.offset) else { return }
            let end = min(ref.offset + ref.size, region.count)
            if ref.name == "OEMP", containsPlaceholder(region, ref.offset..<min(ref.offset + 0x50, end)) {
                return
            }
            found = true
        }
        fpt?.partitions.forEach { part in
            consider(PartitionRef(name: part.name, empty: part.empty,
                                  offset: part.offset, size: part.size))
        }
        bootPartitions?.forEach { boot in
            boot.entries.forEach { part in
                consider(PartitionRef(name: part.name, empty: part.empty,
                                      offset: part.offset - baseOffset, size: part.size))
            }
        }
        return found
    }

    // MARK: - byte helpers

    /// Upstream's `reading[off:off + 0x10] != b'\xFF' * 0x10` guard: true only
    /// when a *full* 0x10 window at `off` is present and all-erased. A window
    /// truncated by the end of the region never equals the 16-byte fill, so it
    /// reads as *not* erased (the partition stays a candidate).
    private static func headErased(_ data: Data, from off: Int) -> Bool {
        guard off >= 0, off + 0x10 <= data.count else { return false }
        for i in off..<(off + 0x10) where data[data.startIndex + i] != 0xFF {
            return false
        }
        return true
    }

    /// True when every byte of the half-open window is erased to 0xFF. An empty
    /// or out-of-range window reads as *not* erased.
    private static func allErased(_ data: Data, _ range: Range<Int>) -> Bool {
        let s = data.startIndex
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= data.count
        else { return false }
        for i in range where data[s + i] != 0xFF { return false }
        return true
    }

    /// `bccb_pat` (MEA.py 11009), `\xCB\xBC.{9}\x00\$MN2` DOTALL: true when the
    /// window holds a byte run whose first two bytes are the 0xBCCB VEN_ID
    /// little-endian, the 12th is a NUL, and the last four are `$MN2`. The nine
    /// bytes between are wildcard (any byte), as `.` matches any byte incl. NUL.
    private static func containsPlaceholder(_ data: Data, _ window: Range<Int>) -> Bool {
        let s = data.startIndex
        let lo = max(window.lowerBound, 0)
        let hi = min(window.upperBound, data.count)
        guard hi - lo >= 16 else { return false }
        for i in lo...(hi - 16) {
            if data[s + i] == 0xCB, data[s + i + 1] == 0xBC,
               data[s + i + 11] == 0x00,
               data[s + i + 12] == 0x24, data[s + i + 13] == 0x4D,
               data[s + i + 14] == 0x4E, data[s + i + 15] == 0x32 {
                return true
            }
        }
        return false
    }
}
