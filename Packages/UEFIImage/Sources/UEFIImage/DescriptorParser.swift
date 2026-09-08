import Foundation

/// The Intel flash descriptor: the first `0x1000` bytes of a full SPI dump, and
/// the map of everything else in it (§2).
enum Descriptor {
    static let signature: UInt32 = 0x0FF0_A55A
    static let size: UInt64 = 0x1000
    /// `FLASH_DESCRIPTOR_MAP`, straight after the header.
    static let mapOffset: UInt64 = 0x14
    static let versionOffset: UInt64 = 0x20
    /// Every `*Base` field holds bits [11:4] of a real offset, so the real one
    /// is `base << 4` and anything above this is a broken descriptor.
    static let maxBase: UInt32 = 0xE0
    /// `0xFFFFFFFF` in the version field means the field is reserved, which
    /// means a version 1 descriptor — and those have five regions, not sixteen.
    static let reservedVersion: UInt32 = 0xFFFF_FFFF
    static let version1RegionCount = 5
}

/// The regions a descriptor can describe, in the order their base/limit pairs
/// appear in the region section (§2.2). The order is the format's, not ours.
public enum FlashRegionType: Int, Sendable, CaseIterable {
    case descriptor, bios, me, gbe, pdr, devExp1, bios2, microcode
    case ec, devExp2, ie, tgbe1, tgbe2, reserved1, reserved2, ptt

    public var label: String {
        switch self {
        case .descriptor: return "Descriptor region"
        case .bios: return "BIOS region"
        case .me: return "ME region"
        case .gbe: return "GbE region"
        case .pdr: return "PDR region"
        case .devExp1: return "Device expansion 1 region"
        case .bios2: return "Secondary BIOS region"
        case .microcode: return "Microcode region"
        case .ec: return "EC region"
        case .devExp2: return "Device expansion 2 region"
        case .ie: return "IE region"
        case .tgbe1: return "10GbE 1 region"
        case .tgbe2: return "10GbE 2 region"
        case .reserved1: return "Reserved region 1"
        case .reserved2: return "Reserved region 2"
        case .ptt: return "PTT region"
        }
    }

    /// Which regions are read further. A BIOS region is volumes and padding, a
    /// microcode region is microcode images; ME, GbE and the rest are formats
    /// of their own and are kept whole (§2.2).
    var readsAsRawArea: Bool {
        switch self {
        case .bios, .bios2, .devExp1, .microcode: return true
        default: return false
        }
    }
}

extension Parser {
    func hasDescriptorSignature(at offset: UInt64) -> Bool {
        reader.uint32(at: offset) == Descriptor.signature
            || reader.uint32(at: offset + 0x10) == Descriptor.signature
    }

    /// An Intel image is one node over the whole image — a descriptor and the
    /// regions it maps, laid out in offset order with the gaps kept (§2.2). The
    /// wrapping node is the root UEFITool shows as `Image/Intel` ("Intel image"):
    /// its body is the whole file, and everything a descriptor describes sits
    /// under it rather than beside it.
    func parseIntelImage(_ range: Range<UInt64>, depth: Int) -> [UEFINode] {
        [UEFINode(
            kind: .intelImage,
            subtype: UEFITypes.Sub.intelImage,
            name: "Intel image",
            header: range.lowerBound..<range.lowerBound,
            body: range,
            isFixed: true,
            children: intelImageChildren(range, depth: depth)
        )]
    }

    /// What an Intel image contains: the descriptor region, the regions the map
    /// names, and the padding that fills the gaps between them.
    private func intelImageChildren(_ range: Range<UInt64>, depth: Int) -> [UEFINode] {
        let base = range.lowerBound
        let regions = readRegions(at: base, limit: range.upperBound)
        guard !regions.isEmpty else {
            note(.truncated(.flashDescriptor), at: base + Descriptor.mapOffset)
            let end = min(base + Descriptor.size, range.upperBound)
            return [descriptorNode(base..<end)]
                + scanRawArea(end..<range.upperBound, emptyByte: Parser.defaultEmptyByte, depth: depth)
        }

        var nodes: [UEFINode] = []
        var claimed = base
        for region in regions.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            // Regions that run into each other mean a descriptor nobody can
            // trust; the first one keeps the bytes and the second is dropped
            // rather than drawn on top of it (§2.2).
            guard region.range.lowerBound >= claimed else {
                note(.overlappingRegions, at: region.range.lowerBound)
                continue
            }
            nodes += padding(
                from: claimed, to: region.range.lowerBound, emptyByte: Parser.defaultEmptyByte
            )
            nodes.append(regionNode(region, depth: depth))
            claimed = region.range.upperBound
        }
        nodes += padding(from: claimed, to: range.upperBound, emptyByte: Parser.defaultEmptyByte)
        return nodes
    }

    private struct Region {
        var type: FlashRegionType
        var range: Range<UInt64>
    }

    /// The region section, at `RegionBase << 4`. Empty when the descriptor's
    /// own map cannot be believed — which the caller turns into a raw scan
    /// rather than into nothing.
    private func readRegions(at base: UInt64, limit: UInt64) -> [Region] {
        guard let map = reader.uint32(at: base + Descriptor.mapOffset),
              let version = reader.uint32(at: base + Descriptor.versionOffset)
        else { return [] }

        let regionBase = (map >> 16) & 0xFF
        guard regionBase > 0, regionBase <= Descriptor.maxBase else { return [] }
        let section = base + UInt64(regionBase) << 4
        let count = version == Descriptor.reservedVersion
            ? Descriptor.version1RegionCount
            : FlashRegionType.allCases.count

        // The descriptor's own region is not read from the table: its base and
        // limit are both zero, which is the table's way of saying "absent". It
        // is the first `0x1000` bytes, always (§2).
        var regions = [Region(type: .descriptor, range: base..<min(base + Descriptor.size, limit))]
        for index in 1..<count {
            let entry = section + UInt64(index) * 4
            guard let type = FlashRegionType(rawValue: index),
                  let first = reader.uint16(at: entry),
                  let last = reader.uint16(at: entry + 2)
            else { break }
            // A region is absent when its limit is zero, and the base and limit
            // hold only the top sixteen bits of a 32-bit address (§2.2).
            guard last != 0, first <= last else { continue }
            let start = base + UInt64(first) << 12
            let end = base + (UInt64(last) << 12 | 0xFFF) + 1
            guard start < limit else {
                note(.truncated(.flashDescriptor), at: entry)
                continue
            }
            if end > limit {
                note(.truncated(.flashDescriptor), at: entry)
            }
            regions.append(Region(type: type, range: start..<min(end, limit)))
        }
        return regions
    }

    private func regionNode(_ region: Region, depth: Int) -> UEFINode {
        if region.type == .descriptor {
            return descriptorNode(region.range)
        }
        let children = region.type.readsAsRawArea
            ? scanRawArea(region.range, emptyByte: Parser.defaultEmptyByte, depth: depth + 1)
            : []
        return UEFINode(
            kind: .region,
            subtype: UInt8(region.type.rawValue),
            name: region.type.label,
            header: region.range.lowerBound..<region.range.lowerBound,
            body: region.range,
            // Regions are laid out by the descriptor, and moving one means
            // rewriting it (§11).
            isFixed: true,
            children: children
        )
    }

    private func descriptorNode(_ range: Range<UInt64>) -> UEFINode {
        UEFINode(
            kind: .flashDescriptor,
            subtype: UInt8(FlashRegionType.descriptor.rawValue),
            name: FlashRegionType.descriptor.label,
            header: range.lowerBound..<min(range.lowerBound + Descriptor.mapOffset, range.upperBound),
            body: min(range.lowerBound + Descriptor.mapOffset, range.upperBound)..<range.upperBound,
            isFixed: true
        )
    }
}
