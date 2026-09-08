import Foundation

/// CSE Huffman decompression — a faithful port of upstream
/// `cse_huffman_decompress` (MEA.py ~9486) and `cse_huffman_dictionary_load`
/// (~9413), "by IllegalArgument". Dictionaries ship in `Huffman.dat` (live-fetched,
/// never snapshotted — `Data/MEADataSource.swift`), keyed by dictionary version
/// (`"11"`/`"12"`); each version maps two canonical codeword tables — `code`
/// (dictionary type `0x20`) and `data` (`0x60`) — of `codeword-bitstring → hex
/// symbol`. Modules are compressed in 0x1000 chunks; each chunk starts with a
/// 4-byte u32 header entry (start offset bits 0–24, dictionary type bits 25–31).
///
/// This is an *enabler* stage: later phases walk decompressed bodies (the RBE/PM
/// metadata of Phase 7's deferral, the CSME-15 `vfs`/`fpf` file systems). Its
/// only use today is validating that a declared-Huffman module body actually
/// decompresses to the size its paired `.met` advertises (`CSE_Ext_0A`
/// SizeUncomp).

/// One entry of the canonical-code shape: codewords of `length` bits occupy the
/// integer range whose smallest value is `threshold >> (32 - length)`
/// (`threshold` is that min shifted to the 32-bit MSB, as upstream compares
/// against a 32-bit `bit_buffer`) and whose largest value is `maxCodeword`.
struct HuffmanShape: Sendable, Equatable {
    let length: Int
    let threshold: UInt32
    let maxCodeword: Int
}

/// Symbols for one dictionary type (`0x20` code / `0x60` data), grouped by
/// codeword length. `symbolsByLength[L]` is indexed by `maxCodeword - codeword`
/// (codewords stored descending), so a codeword resolves to
/// `symbolsByLength[L][maxCodeword - codeword]`. A missing/unknown codeword's
/// symbol is one-or-more `0x7F` placeholder bytes, exactly as upstream.
struct HuffmanSymbolTable: Sendable, Equatable {
    let symbolsByLength: [Int: [[UInt8]]]
    /// Codeword values (per length) whose symbol string was `""`/`??` — the
    /// placeholders upstream reports as *unknown* and flags `huff_error`.
    let unknownCodewords: [Int: Set<Int>]
}

/// One parsed dictionary version (`"11"`/`"12"`): the canonical shape (from the
/// `code` table; upstream warns — and proceeds — if `data` mismatches) and the
/// two symbol tables.
struct HuffmanDictionary: Sendable, Equatable {
    let shape: [HuffmanShape]        // ascending codeword length
    let code: HuffmanSymbolTable     // dictionary type 0x20
    let data: HuffmanSymbolTable     // dictionary type 0x60
}

/// The parsed contents of `Huffman.dat`, keyed by dictionary version. `Huffman.dat`
/// carries no per-CPD module signal of its own — the right table is chosen by
/// (variant, major, minor) exactly like upstream `cse_huffman_dictionary_load`.
/// Public because `MEADataSource.huffmanDictionaries()` returns it, but the two
/// stored tables are internal — decompression happens inside the module, so no
/// caller outside it ever touches them.
public struct HuffmanDictionaries: Sendable, Equatable {
    var version11: HuffmanDictionary?
    var version12: HuffmanDictionary?

    public init() {}

    /// Dictionary version for a (variant, major, minor) triple — `nil` when no
    /// Huffman dictionary is needed (non-CSE engines / CSSPS 1). Upstream picks
    /// version 11 for CSME 11, CSSPS 4 and CSME 14.5, else 12.
    static func version(variant: String, major: Int, minor: Int) -> Int? {
        if variant.hasPrefix("CSTXE") || variant.hasPrefix("PMC")
            || variant.hasPrefix("PCHC") || variant.hasPrefix("PHY")
            || variant.hasPrefix("OROM") || (variant == "CSSPS" && major == 1) {
            return nil
        }
        if (variant == "CSME" && major == 11) || (variant == "CSSPS" && major == 4)
            || (variant == "CSME" && major == 14 && minor == 5) {
            return 11
        }
        return 12
    }

    /// The parsed dictionary for a (variant, major, minor), or nil when none.
    func dictionary(variant: String, major: Int, minor: Int) -> HuffmanDictionary? {
        switch HuffmanDictionaries.version(variant: variant, major: major, minor: minor) {
        case 11: return version11
        case 12: return version12
        default: return nil
        }
    }

    /// Parse `Huffman.dat` (JSON: `{"<version>": {"code": {bits: hex}, "data": {...}}}`).
    /// Throws `.malformed` when the JSON is not that shape.
    static func parse(_ text: String) throws -> HuffmanDictionaries {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8))
            as? [String: Any] else {
            throw MEADataError.malformed(file: "Huffman.dat")
        }
        var out = HuffmanDictionaries()
        for key in ["11", "12"] {
            guard let versionMap = root[key] as? [String: Any] else { continue }
            guard let codeMap = versionMap["code"] as? [String: String],
                  let dataMap = versionMap["data"] as? [String: String] else {
                throw MEADataError.malformed(file: "Huffman.dat")
            }
            let shape = Self.shape(from: codeMap)
            guard !shape.isEmpty else { throw MEADataError.malformed(file: "Huffman.dat") }
            let dictionary = HuffmanDictionary(
                shape: shape,
                code: Self.table(from: codeMap, shape: shape),
                data: Self.table(from: dataMap, shape: shape))
            if key == "11" { out.version11 = dictionary } else { out.version12 = dictionary }
        }
        return out
    }

    // MARK: - JSON → tables

    /// Canonical shape from one mapping: group codeword integers by bit length,
    /// ascending; each length's used codewords occupy `[min, max]`.
    private static func shape(from mapping: [String: String]) -> [HuffmanShape] {
        var ranges: [Int: (min: Int, max: Int)] = [:]
        for (bits, _) in mapping {
            guard bits.allSatisfy({ $0 == "0" || $0 == "1" }) else { continue }
            let value = Int(bits, radix: 2) ?? 0
            let current = ranges[bits.count]
            ranges[bits.count] = (min: Swift.min(current?.min ?? value, value),
                                  max: Swift.max(current?.max ?? -1, value))
        }
        return ranges.keys.sorted().compactMap { length in
            guard length >= 1, length <= 32, let range = ranges[length] else { return nil }
            // min << (32 - length): min is < 2^length, so the shift fits a u32.
            let threshold = UInt32(range.min) << UInt32(32 - length)
            return HuffmanShape(length: length, threshold: threshold,
                                maxCodeword: range.max)
        }
    }

    /// Symbols for one mapping, grouped by length. Upstream iterates a length's
    /// codewords from max down to min, so index `maxCodeword - codeword`; gaps
    /// (codewords absent from the mapping) become unknown 0x7F placeholders and
    /// are recorded in `unknownCodewords` so the decoder flags them.
    private static func table(from mapping: [String: String],
                              shape: [HuffmanShape]) -> HuffmanSymbolTable {
        var symbols: [Int: [[UInt8]]] = [:]
        var unknowns: [Int: Set<Int>] = [:]
        for entry in shape {
            let length = entry.length
            var list: [[UInt8]] = []
            var unknownSet: Set<Int> = []
            if entry.maxCodeword >= 0 {
                for codeword in stride(from: entry.maxCodeword, through: 0, by: -1) {
                    // Only codewords within [min, max] are used; pad the rest with
                    // unknown placeholders so indexing by (max - codeword) is dense.
                    let bits = String(codeword, radix: 2)
                    let padded = String(repeating: "0", count: length - bits.count) + bits
                    if let symbol = mapping[padded] {
                        list.append(Self.symbolBytes(symbol))
                        if symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || symbol.contains("??") {
                            unknownSet.insert(codeword)
                        }
                    } else {
                        list.append([0x7F])
                        unknownSet.insert(codeword)
                    }
                }
            }
            symbols[length] = list
            if !unknownSet.isEmpty { unknowns[length] = unknownSet }
        }
        return HuffmanSymbolTable(symbolsByLength: symbols, unknownCodewords: unknowns)
    }

    /// A symbol string → bytes. `""` and `"??"`-only strings mean unknown
    /// codewords and expand to 0x7F placeholder bytes (one per `??` pair);
    /// anything else is hex.
    private static func symbolBytes(_ symbol: String) -> [UInt8] {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [0x7F] }
        if trimmed.count % 2 == 0, trimmed.contains("??") {
            return Array(repeating: 0x7F, count: trimmed.count / 2)
        }
        var bytes: [UInt8] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            if let byte = UInt8(trimmed[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return bytes
    }
}

/// `cse_huffman_decompress`. `module` is the raw module bytes, of which the first
/// `chunkCount * 4` bytes are the chunk directory and `[headerSize, compressedSize)`
/// the compressed stream (so the last chunk's end is `compressedSize - headerSize`).
/// Always yields exactly `decompressedSize` output bytes (matching upstream, which
/// never returns early): a chunk that runs out of stream, meets an overflowing
/// codeword or hits an unknown codeword is 0x7F-filled to its 0x1000 boundary and
/// decoding carries on into the next chunk. `clean` is false when any chunk hit
/// one of those (upstream's `huff_error`).
enum HuffmanDecoder {
    static let chunkSize = 0x1000

    static func decompress(module: Data, compressedSize: Int, decompressedSize: Int,
                           dictionary: HuffmanDictionary)
        -> (output: Data, clean: Bool) {
        guard decompressedSize > 0 else { return (Data(), false) }
        guard !dictionary.shape.isEmpty else { return (module, false) }

        let chunkCount = decompressedSize / chunkSize
        let headerSize = chunkCount * 4
        let bounded = min(module.count, max(0, compressedSize))
        guard headerSize <= bounded else { return (Data(repeating: 0x7F, count: decompressedSize), false) }

        // Chunk directory: (start offset in the compressed stream, dictionary type).
        var startOffsets: [Int] = []
        var flags: [Int] = []
        for i in 0..<chunkCount {
            let entry = readUInt32(module, headerOffset: i * 4)
            startOffsets.append(Int(entry & 0x1FF_FFFF))
            flags.append(Int((entry >> 25) & 0x7F))
        }
        let endOffsets: [Int] = startOffsets.dropFirst()
            + [max(0, bounded - headerSize)]

        let codeSymbols = dictionary.code.symbolsByLength
        let dataSymbols = dictionary.data.symbolsByLength
        let codeUnknowns = dictionary.code.unknownCodewords
        let dataUnknowns = dictionary.data.unknownCodewords

        var out: [UInt8] = []
        out.reserveCapacity(decompressedSize)
        var clean = true

        for chunk in 0..<chunkCount {
            let usesData = flags[chunk] == 0x60
            let symbols = usesData ? dataSymbols : codeSymbols
            let unknowns = usesData ? dataUnknowns : codeUnknowns
            let compressedStart = startOffsets[chunk]
            let compressedEnd = min(endOffsets[chunk], bounded - headerSize)

            let decompressedEnd = (chunk + 1) * chunkSize

            var bitBuffer: UInt32 = 0
            var availableBits = 0
            var read = compressedStart

            while out.count < decompressedEnd {
                // Top up the 32-bit window until a codeword is decidable.
                while availableBits <= 24, read < compressedEnd {
                    bitBuffer = bitBuffer | (UInt32(module[headerSize + read]) << (24 - availableBits))
                    read += 1
                    availableBits += 8
                }
                // Shortest codeword whose range the window tops out in.
                var length = 0
                var baseCodeword = 0
                for shape in dictionary.shape where bitBuffer >= shape.threshold {
                    length = shape.length
                    baseCodeword = shape.maxCodeword
                    break
                }
                guard length > 0, availableBits >= length else {
                    // Reached end of compressed stream early: fill the chunk tail
                    // (0x7F) and stop this chunk — later chunks still decode.
                    out.append(contentsOf: repeatElement(0x7F,
                        count: decompressedEnd - out.count))
                    clean = false
                    break
                }
                let codeword = Int(bitBuffer >> UInt32(32 - length))
                bitBuffer = (bitBuffer << UInt32(length)) & 0xFFFF_FFFF
                availableBits -= length

                let symbol = symbols[length]?[baseCodeword - codeword] ?? [0x7F]
                if decompressedEnd - out.count >= symbol.count {
                    if unknowns[length]?.contains(codeword) == true { clean = false }
                    out.append(contentsOf: symbol)
                } else {
                    // Overflowing codeword: pad the chunk tail, stop this chunk.
                    out.append(contentsOf: repeatElement(0x7F,
                        count: decompressedEnd - out.count))
                    clean = false
                    break
                }
            }
        }
        return (Data(out), clean)
    }

    private static func readUInt32(_ data: Data, headerOffset: Int) -> UInt32 {
        let i = headerOffset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }
}
