import Foundation

/// Pre-CSE (classic `ME` 2–10) `$MME` module directory decode — the rows that
/// follow an R0 `$MN2`/`$MAN` manifest and inventory its engine modules
/// (ROMP/BUP/KERNEL/…), plus the trailing `$MCP` where one is present. A
/// faithful port of the module layout upstream reads in its region-size /
/// uncharted-partition math (MEA.py 12256–12369); upstream prints no table for
/// these rows, so this surfaces the directory facts verbatim as
/// `FirmwareAnalysis.mmeDirectory` (upstream-map rows 51/52).
///
/// Layout (verified against the real Lenovo T450 ME10 slice):
/// - list head `mod_start = manifest base + HeaderLength*4 + 0xC`
///   (MEA.py 12256) — the 0xC gap between the manifest struct end and the first
///   `$MME` row.
/// - `$MN2` (ME 6–10) → `MME_Header_New`, stride 0x60; `$MAN` (ME 2–5) →
///   `MME_Header_Old`, stride 0x50 (MEA.py 12259/12274).
/// - rows are decoded until `NumModules` is reached or a row's tag is not
///   `$MME` (upstream's sanity `break`); every row is a self-contained header.
/// - `$MCP` (`MCP_Header`, ME 8–10) sits one 0x60 padding row after the
///   declared directory (`mcp_start = mod_start + NumModules*0x60 + 0x60`,
///   MEA.py 12326) — only after `$MN2`; the `$MAN` path never reads it.
///
/// Field offsets are taken verbatim from the ctypes structs (MEA.py 1107–1159)
/// and the module content offsets (`Offset_MN2`, `ModBase`, `Offset_Code_MN2`)
/// are recorded as stored, never resolved to content — upstream makes no
/// uniqueness promise for them (e.g. ROMP/BUP/KERNEL/POLICY on the T450 all
/// share `Offset_MN2` 0x940).
enum PreCSEModule {
    /// Decode the `$MME` directory (+ trailing `$MCP`) of the R0 pre-CSE
    /// manifest at `manifestBase`. `headerLengthBytes`, `manifestTag` and
    /// `declaredModules` come from the decoded `ManifestParser.Manifest`.
    /// Returns nil when no plausible directory is present (out of bounds, or the
    /// first row is not a `$MME` — i.e. this is not an R0 pre-CSE manifest).
    static func decode(in region: Data,
                       manifestBase: Int,
                       headerLengthBytes: Int,
                       manifestTag: String,
                       declaredModules: Int,
                       baseOffset: Int = 0) -> MMEModuleDirectory? {
        guard declaredModules > 0 else { return nil }
        let isNew = manifestTag == "$MN2"          // ME 6-10 new header; $MAN ME 2-5 old
        let stride = isNew ? 0x60 : 0x50
        let head = manifestBase + headerLengthBytes + 0xC
        // A plausible directory has its first $MME row fully in bounds.
        guard head >= 0, head + stride <= region.count else { return nil }

        var rows: [MMEModule] = []
        var cursor = head
        while rows.count < declaredModules {
            guard cursor + stride <= region.count,
                  asciiTag(in: region, at: cursor) == "$MME" else { break }
            rows.append(isNew ? decodeNewRow(in: region, at: cursor, id: rows.count)
                              : decodeOldRow(in: region, at: cursor, id: rows.count))
            cursor += stride
        }
        guard !rows.isEmpty else { return nil }     // not a pre-CSE directory

        // Trailing $MCP: only after an $MN2 (ME 6-10), one stride past the
        // declared directory (MEA.py 12326). Absent -> nil.
        var mcp: MCPHeader? = nil
        if isNew {
            let mcpBase = head + declaredModules * stride + stride
            if mcpBase + 0x34 <= region.count, asciiTag(in: region, at: mcpBase) == "$MCP" {
                mcp = MCPHeader(
                    offset: baseOffset + mcpBase,
                    headerSize: Int(u32le(region, mcpBase + 0x04)),
                    codeSize: Int(u32le(region, mcpBase + 0x08)),
                    offsetCodeMN2: Int(u32le(region, mcpBase + 0x0C)),
                    offsetPartFPT: Int(u32le(region, mcpBase + 0x10)),
                    hashHex: hex(region, mcpBase + 0x14, 0x20))
            }
        }

        return MMEModuleDirectory(
            offset: baseOffset + head,
            manifestTag: manifestTag,
            declaredModules: declaredModules,
            modules: rows,
            mcp: mcp)
    }

    /// MME_Header_New (MEA.py 1125, stride 0x60): Tag/Name[16]/Hash[32]/
    /// ModBase u32 0x34/Offset_MN2 0x38/SizeUncomp 0x3C/SizeComp 0x40/
    /// MemorySize 0x44/PreUmaSize 0x48/EntryPoint 0x4C/Flags 0x50.
    private static func decodeNewRow(in region: Data, at r: Int, id: Int) -> MMEModule {
        MMEModule(
            id: id,
            name: asciiName(in: region, at: r + 0x04, length: 16),
            hashHex: hex(region, r + 0x14, 0x20),
            modBase: Int(u32le(region, r + 0x34)),
            offsetMN2: Int(u32le(region, r + 0x38)),
            sizeUncompressed: Int(u32le(region, r + 0x3C)),
            sizeCompressed: Int(u32le(region, r + 0x40)),
            memorySize: Int(u32le(region, r + 0x44)),
            preUmaSize: Int(u32le(region, r + 0x48)),
            entryPoint: Int(u32le(region, r + 0x4C)),
            flags: u32le(region, r + 0x50))
    }

    /// MME_Header_Old (MEA.py 1107, stride 0x50): Tag/Guid[16]@0x04/
    /// Major/Minor/Hotfix/Build u16 @0x14-0x1A/Name[16]@0x1C/Hash[20]@0x2C/
    /// Size u32 0x40/Flags u32 0x44.
    private static func decodeOldRow(in region: Data, at r: Int, id: Int) -> MMEModule {
        MMEModule(
            id: id,
            name: asciiName(in: region, at: r + 0x1C, length: 16),
            hashHex: hex(region, r + 0x2C, 0x14),
            guidHex: hex(region, r + 0x04, 0x10),
            flags: u32le(region, r + 0x44),
            majorVersion: Int(u16le(region, r + 0x14)),
            minorVersion: Int(u16le(region, r + 0x16)),
            hotfixVersion: Int(u16le(region, r + 0x18)),
            buildVersion: Int(u16le(region, r + 0x1A)),
            size: Int(u32le(region, r + 0x40)))
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

    private static func hex(_ data: Data, _ p: Int, _ length: Int) -> String {
        data.subdata(in: p..<(p + length))
            .map { String(format: "%02X", $0) }.joined()
    }

    private static func asciiTag(in data: Data, at p: Int) -> String? {
        guard p + 4 <= data.count else { return nil }
        return String(data: data.subdata(in: p..<(p + 4)), encoding: .ascii)
    }

    private static func asciiName(in data: Data, at p: Int, length: Int) -> String {
        let trimmed = data.subdata(in: p..<(p + length)).filter { $0 != 0 }
        return String(data: trimmed, encoding: .ascii) ?? ""
    }
}
