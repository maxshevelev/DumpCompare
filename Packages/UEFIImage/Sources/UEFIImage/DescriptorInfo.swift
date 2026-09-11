import Foundation

/// What a flash descriptor says about itself, beyond the regions it maps: the
/// reserved vector it opens with, where each region it declares begins, which
/// master may read and write which region, and the flash chips the board's
/// firmware was built to drive (§2).
///
/// The regions are already the tree — a descriptor's children are its regions —
/// but the rest of this is not anywhere else in the app, and it is what a bench
/// asks a descriptor: *can the BIOS master even write the ME region on this
/// board, and is the chip I am about to solder on one this firmware knows?*
///
/// Read as a value, once, so the detail panel formats rather than parses, and
/// so the reading itself is testable without a window.
public struct DescriptorInfo: Equatable, Sendable {
    /// The sixteen bytes before the signature. Reserved, and reliably not zero:
    /// on many boards they are the first instruction the chip ever executes.
    public var reservedVector: [UInt8]

    /// Where each region the descriptor declares begins, in the file's own
    /// offsets, in the format's region order.
    public var regionOffsets: [(type: FlashRegionType, offset: UInt64)]

    /// One master's read and write masks. Each bit stands for a region — the
    /// `RegionAccess` bits — so a master's word says which regions it may
    /// touch rather than how.
    public struct Master: Equatable, Sendable {
        public var name: String
        public var read: UInt32
        public var write: UInt32
    }

    /// BIOS, ME, GbE — and EC where the descriptor is new enough to have one.
    public var masters: [Master]

    /// How wide a mask is written: two hex digits on a version 1 descriptor,
    /// where a mask is a byte, and three on a version 2, where it is twelve
    /// bits. UEFITool writes them the same way, and the width is the only sign
    /// on screen of which kind of descriptor this is.
    public var maskDigits: Int

    /// What the BIOS master may do to each region — the question behind
    /// "why can't my programmer write this area from inside the OS".
    public struct Access: Equatable, Sendable {
        public var region: String
        public var read: Bool
        public var write: Bool
    }

    public var biosAccess: [Access]

    /// A chip in the VSCC table: the JEDEC id the table lists, and the chip
    /// that id names when it is one the catalogue knows.
    public struct Chip: Equatable, Sendable {
        public var jedecID: UInt32
        public var name: String?
    }

    public var chips: [Chip]

    /// The region bits a master's access mask carries (§2.3).
    enum RegionAccess {
        static let descriptor: UInt32 = 0x01
        static let bios: UInt32 = 0x02
        static let me: UInt32 = 0x04
        static let gbe: UInt32 = 0x08
        static let pdr: UInt32 = 0x10
        static let ec: UInt32 = 0x20
    }

    /// The upper map, at a fixed offset near the end of the descriptor, which
    /// says where the VSCC table is and how long it is.
    enum UpperMap {
        static let offset: UInt64 = 0x0EFC
        /// A VSCC entry is two dwords: the id and its register value. The map's
        /// size field counts dwords, so the entry count is half of it.
        static let entrySize: UInt64 = 8
    }
}

public extension DescriptorInfo {
    /// Reads the descriptor at `base`. Nil when there is no readable map there
    /// — the caller has a node that says it is a descriptor, and this says
    /// whether its own header can be believed.
    static func read(at base: UInt64, in reader: ImageReader) -> DescriptorInfo? {
        guard let map = reader.uint32(at: base + Descriptor.mapOffset),
              let map1 = reader.uint32(at: base + Descriptor.map1Offset),
              let version = reader.uint32(at: base + Descriptor.versionOffset),
              let vector = reader.bytes(at: base, count: 16)
        else { return nil }

        // Version 1 keeps a byte per mask and has no EC master; version 2 —
        // everything from Skylake on — packs twelve bits per mask and adds one.
        let isVersion1 = version == Descriptor.reservedVersion
        // The master section's base is the second map word's low byte, in the
        // 0x10 units every base in this header is written in. Out of range —
        // an erased word says `0xFF` — there is no section to read, and the
        // bytes at whatever that points to are not masters.
        let masterAt = map1 & 0xFF
        let masterBase = (masterAt > 0 && masterAt <= Descriptor.maxBase)
            ? base + UInt64(masterAt) << 4
            : nil

        return DescriptorInfo(
            reservedVector: vector,
            regionOffsets: regionOffsets(at: base, map: map, isVersion1: isVersion1,
                                         reader: reader),
            masters: masters(at: masterBase, isVersion1: isVersion1, reader: reader),
            maskDigits: isVersion1 ? 2 : 3,
            biosAccess: biosAccess(at: masterBase, isVersion1: isVersion1, reader: reader),
            chips: chips(at: base, reader: reader)
        )
    }

    /// Every region the table declares, by where it starts. A region with a
    /// zero limit is not there at all, which is the table's way of saying so,
    /// and is left out rather than shown as an area at zero.
    private static func regionOffsets(
        at base: UInt64, map: UInt32, isVersion1: Bool, reader: ImageReader
    ) -> [(type: FlashRegionType, offset: UInt64)] {
        let regionBase = (map >> 16) & 0xFF
        guard regionBase > 0, regionBase <= Descriptor.maxBase else { return [] }
        let section = base + UInt64(regionBase) << 4
        let count = isVersion1 ? Descriptor.version1RegionCount : FlashRegionType.allCases.count

        var offsets: [(type: FlashRegionType, offset: UInt64)] = []
        for index in 0..<count {
            guard let type = FlashRegionType(rawValue: index),
                  let first = reader.uint16(at: section + UInt64(index) * 4),
                  let last = reader.uint16(at: section + UInt64(index) * 4 + 2)
            else { break }
            // The descriptor's own entry is zero/zero on every image — it is
            // the first 0x1000 bytes by definition — so it is stated rather
            // than read, and every other region needs a limit to exist.
            if type == .descriptor {
                offsets.append((type, base))
                continue
            }
            guard last != 0, first <= last else { continue }
            offsets.append((type, base + UInt64(first) << 12))
        }
        return offsets
    }

    /// The master section's read and write masks, one master per row.
    private static func masters(
        at masterBase: UInt64?, isVersion1: Bool, reader: ImageReader
    ) -> [Master] {
        guard let masterBase else { return [] }
        if isVersion1 {
            // Three records of `id, read, write` — two bytes, then one each.
            let names = ["BIOS", "ME", "GbE"]
            return names.enumerated().compactMap { index, name in
                let entry = masterBase + UInt64(index) * 4
                guard let read = reader.uint8(at: entry + 2),
                      let write = reader.uint8(at: entry + 3)
                else { return nil }
                return Master(name: name, read: UInt32(read), write: UInt32(write))
            }
        }
        // One dword per master: eight reserved bits, then twelve of read and
        // twelve of write. EC's sits a dword past a reserved one.
        let names: [(String, UInt64)] = [("BIOS", 0), ("ME", 4), ("GbE", 8), ("EC", 16)]
        return names.compactMap { name, offset in
            guard let word = reader.uint32(at: masterBase + offset) else { return nil }
            return Master(name: name, read: word >> 8 & 0xFFF, write: word >> 20 & 0xFFF)
        }
    }

    /// What the BIOS master may do to each region, read off its own masks —
    /// except to the BIOS region itself, which it owns and which the table
    /// states rather than reads, exactly as the reference parser does.
    private static func biosAccess(
        at masterBase: UInt64?, isVersion1: Bool, reader: ImageReader
    ) -> [Access] {
        guard let masterBase else { return [] }
        let bios: (read: UInt32, write: UInt32)
        if isVersion1 {
            guard let read = reader.uint8(at: masterBase + 2),
                  let write = reader.uint8(at: masterBase + 3)
            else { return [] }
            bios = (UInt32(read), UInt32(write))
        } else {
            guard let word = reader.uint32(at: masterBase) else { return [] }
            bios = (word >> 8 & 0xFFF, word >> 20 & 0xFFF)
        }

        var rows = [
            Access(region: "Desc", read: bios.read & RegionAccess.descriptor != 0,
                   write: bios.write & RegionAccess.descriptor != 0),
            Access(region: "BIOS", read: true, write: true),
            Access(region: "ME", read: bios.read & RegionAccess.me != 0,
                   write: bios.write & RegionAccess.me != 0),
            Access(region: "GbE", read: bios.read & RegionAccess.gbe != 0,
                   write: bios.write & RegionAccess.gbe != 0),
            Access(region: "PDR", read: bios.read & RegionAccess.pdr != 0,
                   write: bios.write & RegionAccess.pdr != 0),
        ]
        if !isVersion1 {
            rows.append(Access(region: "EC", read: bios.read & RegionAccess.ec != 0,
                               write: bios.write & RegionAccess.ec != 0))
        }
        return rows
    }

    /// The VSCC table: the flash chips this firmware was built to drive, by
    /// JEDEC id, named where the catalogue knows them.
    private static func chips(at base: UInt64, reader: ImageReader) -> [Chip] {
        guard let map = reader.uint16(at: base + UpperMap.offset) else { return [] }
        // The same rule as every other base in this header: out of range is no
        // table rather than a table read from wherever it points.
        let tableAt = UInt32(map & 0xFF)
        guard tableAt > 0, tableAt <= Descriptor.maxBase else { return [] }
        let tableBase = base + UInt64(tableAt) << 4
        // The size field counts dwords; an entry is two of them.
        let count = UInt64(map >> 8 & 0xFF) / 2
        guard count > 0 else { return [] }

        var chips: [Chip] = []
        for index in 0..<count {
            let entry = tableBase + index * UpperMap.entrySize
            guard let vendor = reader.uint8(at: entry),
                  let device0 = reader.uint8(at: entry + 1),
                  let device1 = reader.uint8(at: entry + 2)
            else { break }
            let id = UInt32(vendor) << 16 | UInt32(device0) << 8 | UInt32(device1)
            // An erased or empty tail is not a chip.
            guard id != 0, id != 0xFF_FFFF else { continue }
            chips.append(Chip(jedecID: id, name: JedecIDs.name(of: id)))
        }
        return chips
    }
}

extension DescriptorInfo {
    public static func == (lhs: DescriptorInfo, rhs: DescriptorInfo) -> Bool {
        lhs.reservedVector == rhs.reservedVector
            && lhs.regionOffsets.map(\.offset) == rhs.regionOffsets.map(\.offset)
            && lhs.regionOffsets.map(\.type) == rhs.regionOffsets.map(\.type)
            && lhs.masters == rhs.masters
            && lhs.maskDigits == rhs.maskDigits
            && lhs.biosAccess == rhs.biosAccess
            && lhs.chips == rhs.chips
    }
}
