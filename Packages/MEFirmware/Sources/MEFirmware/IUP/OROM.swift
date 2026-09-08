import Foundation

/// GSC Option ROM image scan + decode — a faithful port of the OROM/PCIR pass
/// upstream runs when an image is a GSC OROM firmware (MEA.py 12149–12179). It
/// scans the region for `orom_pat` (MEA.py 11021), the OROM/PCIR header
/// signature, then decodes each match as a `GSC_OROM_Header` (MEA.py 433) and —
/// at `match + PCIDataHdrOff` — the `GSC_OROM_PCI_Data` (MEA.py 466), zero-
/// padded when the PCIR's own `PCIDataHdrLen` is shorter than the struct
/// (MEA.py 12162).
///
/// The signature byte pattern is:
///   `55 AA  {22}  1C 00  {2}  PCIR  86 80  {4}  (18|1C) 00`
/// i.e. Signature AA55; `PCIDataHdrOff` = 0x1C (bytes 24/25); the PCIR struct
/// opens at +0x1C with "PCIR" and VEN_ID 0x8086 (bytes 28–33); and the PCIR's
/// own `PCIDataHdrLen` (bytes 38/39, `PCIR+0x0A`) is 0x18 or 0x1C. Each match
/// also computes the payload split `data_off = max(PCIDataHdrOff +
/// PCIR.PCIDataHdrLen, EFIImageOffset, OROMPayloadOff)` and whether that
/// payload opens with `$CPD` (both feed upstream's OROM IUP size math).
///
/// Surfaced as `FirmwareAnalysis.oromImages` (upstream-map rows 30/80), gated on
/// the region identifying as the `.orom` family (upstream `is_orom_img`).
/// Fixture-only: none of the engine's oracles matched `orom_pat`.
enum GSCOROM {
    /// Scan the whole region for OROM/PCIR images and decode each. Returns nil
    /// when no `orom_pat` match is decodable (i.e. not an OROM image).
    static func decode(in region: Data, baseOffset: Int = 0) -> [GSCOROMImage]? {
        var images: [GSCOROMImage] = []
        var i = 0
        while i + 0x28 <= region.count {
            if isOROMSignature(in: region, at: i),
               let image = decodeImage(in: region, at: i, baseOffset: baseOffset,
                                       id: images.count) {
                images.append(image)
            }
            i += 1
        }
        return images.isEmpty ? nil : images
    }

    /// `orom_pat` on the 40 bytes at `i` (all fixed positions of the regex):
    /// Signature AA55 (0/1), `PCIDataHdrOff` 0x1C (24/25), "PCIR" at +0x1C
    /// (28–31), VEN_ID 0x8086 (32/33) and the PCIR `PCIDataHdrLen` (38/39,
    /// PCIR+0x0A) of 0x18 or 0x1C. Bytes 2–23, 26/27 and 34–37 are wildcard.
    private static func isOROMSignature(in region: Data, at i: Int) -> Bool {
        region[i] == 0x55 && region[i + 1] == 0xAA
            && region[i + 24] == 0x1C && region[i + 25] == 0x00   // PCIDataHdrOff == 0x1C
            && region[i + 28] == 0x50 && region[i + 29] == 0x43
            && region[i + 30] == 0x49 && region[i + 31] == 0x52   // "PCIR"
            && region[i + 32] == 0x86 && region[i + 33] == 0x80   // VEN_ID 0x8086
            && ((region[i + 38] == 0x18 && region[i + 39] == 0x00)
                || (region[i + 38] == 0x1C && region[i + 39] == 0x00))  // PCIR PCIDataHdrLen 0x18/0x1C
    }

    /// Decode one OROM image whose header starts at `i`. Requires the header
    /// (0x1C) and its full PCIR struct (0x1C) to be in bounds; otherwise the
    /// match is not a decodable image and nil is returned (skipped).
    private static func decodeImage(in region: Data, at i: Int,
                                    baseOffset: Int, id: Int) -> GSCOROMImage? {
        guard i + 0x1C + 0x1C <= region.count else { return nil }

        let header = GSCOROMHeader(
            signature: u16le(region, i + 0x00),
            imageSize: u16le(region, i + 0x02),
            initFuncEntryPoint: u32le(region, i + 0x04),
            subSystem: u16le(region, i + 0x08),
            machineType: u16le(region, i + 0x0A),
            compressionType: u16le(region, i + 0x0C),
            reserved: u64le(region, i + 0x0E),
            efiImageOffset: u16le(region, i + 0x16),
            pciDataHeaderOffset: u16le(region, i + 0x18),
            oromPayloadOffset: u16le(region, i + 0x1A))

        let p = i + Int(header.pciDataHeaderOffset)
        guard p + 0x1C <= region.count else { return nil }
        let pciData = GSCOROMPCIData(
            signature: ascii(in: region, at: p + 0x00, length: 4),
            vendorID: u16le(region, p + 0x04),
            deviceID: u16le(region, p + 0x06),
            deviceListPointer: u16le(region, p + 0x08),
            pciDataHeaderLength: u16le(region, p + 0x0A),
            pciDataHeaderRevision: region[p + 0x0C],
            classCode: UInt32(region[p + 0x0D])
                | (UInt32(region[p + 0x0E]) << 8)
                | (UInt32(region[p + 0x0F]) << 16),
            imageSize: u16le(region, p + 0x10),
            revisionLevel: u16le(region, p + 0x12),
            codeType: region[p + 0x14],
            lastImage: region[p + 0x15] & 0x80 != 0,
            maxRuntimeImageLength: u16le(region, p + 0x16),
            configUtilityCodeHeaderPointer: u16le(region, p + 0x18),
            dmtfCLPEntryPointPointer: u16le(region, p + 0x1A))

        // data_off = max(PCIDataHdrOff + PCIR.PCIDataHdrLen, EFIImageOffset,
        //                OROMPayloadOff) — MEA.py 12169.
        let payloadOffset = max(Int(header.pciDataHeaderOffset) + Int(pciData.pciDataHeaderLength),
                                max(Int(header.efiImageOffset), Int(header.oromPayloadOffset)))
        let payloadIsCPD = region.count >= i + payloadOffset + 4
            && region[i + payloadOffset] == 0x24 && region[i + payloadOffset + 1] == 0x43
            && region[i + payloadOffset + 2] == 0x50 && region[i + payloadOffset + 3] == 0x44

        return GSCOROMImage(
            id: id,
            offset: baseOffset + i,
            header: header,
            pciData: pciData,
            payloadOffset: payloadOffset,
            payloadIsCPD: payloadIsCPD)
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

    private static func u64le(_ data: Data, _ p: Int) -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            value |= UInt64(data[p + shift / 8]) << UInt64(shift)
        }
        return value
    }

    private static func ascii(in data: Data, at p: Int, length: Int) -> String {
        let trimmed = data.subdata(in: p..<(p + length)).filter { $0 != 0 }
        return String(data: trimmed, encoding: .ascii) ?? ""
    }
}
