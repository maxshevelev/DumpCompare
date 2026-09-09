import Foundation

/// FTPR `pm` / RBEP `rbe` module "Metadata" table scan — a faithful port of
/// upstream `get_rbe_pm_met` (MEA.py 9711) over the module's decompressed body.
///
/// The table is a run of contiguous `RBE_PM_Metadata` entries (structs 5161–
/// 5295), each opening `Unknown0` + `DEV_ID` + `VEN_ID` 0x8086. `get_rbe_pm_met`
/// finds the table by the three consecutive `\x86\x80` VEN_IDs at a fixed
/// spacing and picks the struct by which of the four spacings matches (tried
/// R1 → R2 → R3 → R4):
///
///   R1: gap 70 (stride 0x48) SHA-256 + extended fields
///   R2: gap 46 (stride 0x30) SHA-256, compact
///   R3: gap 86 (stride 0x58) SHA-384 + extended fields
///   R4: gap 62 (stride 0x40) SHA-384, compact
///
/// A table row opens `gap - 4` bytes before its neighbour's `VEN_ID`; the first
/// entry therefore starts 6 bytes before the first matched `\x86\x80`. From
/// there every contiguous entry whose `VEN_ID` is again 0x8086 is chained
/// (upstream's `while … == b'\x86\x80'` walk). Each row's stored hash is
/// formatted exactly as upstream: the little-endian digest read as one integer,
/// uppercased — i.e. the digest bytes byte-reversed as hex. Only the hash list
/// is consumed upstream (for module-without-metadata-hash validation), but the
/// row scalars mirror the structs, so the full row is surfaced.
///
/// Surfaced as `FirmwareAnalysis.rbePmMetadata` (upstream-map rows 54/55).
enum RBEPMMetadataParser {
    private struct Layout {
        let variant: RBE_PMVariant
        let stride: Int
        let gap: Int
        let hashOffset: Int
        let hashLength: Int
        let extended: Bool
    }

    /// Tried in this order, mirroring `get_rbe_pm_met`'s if/elif chain. `stride`
    /// is the struct size; `gap = stride - 2` is the regex `.{n}` between the
    /// `\x80` of one `VEN_ID` and the `\x86` of the next.
    private static let layouts: [Layout] = [
        Layout(variant: .r1, stride: 0x48, gap: 70, hashOffset: 0x28, hashLength: 0x20, extended: true),
        Layout(variant: .r2, stride: 0x30, gap: 46, hashOffset: 0x10, hashLength: 0x20, extended: false),
        Layout(variant: .r3, stride: 0x58, gap: 86, hashOffset: 0x28, hashLength: 0x30, extended: true),
        Layout(variant: .r4, stride: 0x40, gap: 62, hashOffset: 0x10, hashLength: 0x30, extended: false),
    ]

    /// Scan `body` for the spaced-`\x86\x80` metadata table and decode every
    /// contiguous entry. Returns nil when none of the four patterns matches.
    /// (The per-layout `firstEntry` guards the body length, so a short body just
    /// fails every variant rather than erroring.)
    static func decode(in body: Data) -> [RBE_PMMetadata]? {
        for layout in layouts {
            guard let entryBase = firstEntry(of: layout, in: body) else { continue }
            var entries: [RBE_PMMetadata] = []
            var row = entryBase
            var index = 0
            // Chain contiguous entries whose own VEN_ID is 0x8086 (the walked
            // first entry always has one by construction) and that fit fully.
            while row + layout.stride <= body.count,
                  body[row + 6] == 0x86, body[row + 7] == 0x80 {
                entries.append(decodeEntry(index: index, at: row, layout: layout, in: body))
                index += 1
                row += layout.stride
            }
            return entries.isEmpty ? nil : entries
        }
        return nil
    }

    /// First `\x86\x80` `VEN_ID` whose two successors sit `gap + 2` bytes apart,
    /// i.e. three consecutive entries in a single-stride table. The returned
    /// offset is the table's first entry base (`match - 6`, MEA.py 9717). Entry
    /// bases below 0 are impossible here (the scan starts at 6), unlike
    /// upstream's unbounded regex.
    private static func firstEntry(of layout: Layout, in body: Data) -> Int? {
        let patternEnd = 6 + 2 * layout.gap
        guard body.count >= patternEnd else { return nil }
        var i = 6
        while i <= body.count - patternEnd {
            if body[i] == 0x86 && body[i + 1] == 0x80,
               body[i + layout.gap + 2] == 0x86 && body[i + layout.gap + 3] == 0x80,
               body[i + 2 * layout.gap + 4] == 0x86 && body[i + 2 * layout.gap + 5] == 0x80 {
                return i - 6          // entry base is 6 before its VEN_ID
            }
            i += 1
        }
        return nil
    }

    /// Decode the row at `base` for the given struct layout.
    private static func decodeEntry(index: Int, at base: Int, layout: Layout,
                                    in body: Data) -> RBE_PMMetadata {
        var bssSize: Int? = nil, codeSize: Int? = nil, codeBase: Int? = nil
        var mainThread: Int? = nil, unknown1: Int? = nil, unknown2: Int? = nil
        if layout.extended {
            bssSize = u32(body, base + 0x10)
            codeSize = u32(body, base + 0x14)
            codeBase = u32(body, base + 0x18)
            mainThread = u32(body, base + 0x1C)
            unknown1 = u32(body, base + 0x20)
            unknown2 = u32(body, base + 0x24)
        }
        let hashBytes = body.subdata(in: (base + layout.hashOffset)
                                         ..< (base + layout.hashOffset + layout.hashLength))
        return RBE_PMMetadata(
            id: index,
            variant: layout.variant,
            unknown0: u32(body, base + 0x00),
            deviceID: u16(body, base + 0x04),
            vendorID: u16(body, base + 0x06),
            sizeUncompressed: u32(body, base + 0x08),
            sizeCompressed: u32(body, base + 0x0C),
            bssSize: bssSize,
            codeSizeUncompressed: codeSize,
            codeBaseAddress: codeBase,
            mainThreadEntry: mainThread,
            unknown1: unknown1,
            unknown2: unknown2,
            hash: leIntHex(hashBytes))
    }

    // MARK: - Byte / string helpers

    private static func u16(_ data: Data, _ p: Int) -> Int {
        Int(data[p]) | (Int(data[p + 1]) << 8)
    }

    private static func u32(_ data: Data, _ p: Int) -> Int {
        Int(data[p])
            | (Int(data[p + 1]) << 8)
            | (Int(data[p + 2]) << 16)
            | (Int(data[p + 3]) << 24)
    }

    /// Upstream `'%0.*X' % (len*2, int.from_bytes(Hash, 'little'))`: the digest
    /// read as one little-endian integer, uppercased and zero-padded to its full
    /// width. Little-endian integer hex = the digest bytes reversed as hex.
    private static func leIntHex(_ bytes: Data) -> String {
        bytes.reversed().map { String(format: "%02X", $0) }.joined()
    }
}
