import XCTest
@testable import DumpCompareCore

/// The `EditableByteStorage` contract, asserted once against every
/// implementation of it. `EditOverlayStorage` (a piece table over a file) and
/// `MemoryBackedStorage` (a plain buffer) must be indistinguishable through the
/// protocol: the same fixture, the same operation, the same content and size
/// afterwards. Anything specific to one of them lives in its own test class.
final class EditableByteStorageContractTests: XCTestCase {
    /// Every implementation of the contract, by name. A failure names the one
    /// that broke.
    private static let implementations: [(name: String, make: ([UInt8]) throws -> any EditableByteStorage)] = [
        ("EditOverlayStorage", { EditOverlayStorage(base: try TestSupport.makeStorage(Data($0))) }),
        ("MemoryBackedStorage", { MemoryBackedStorage(bytes: $0) }),
    ]

    /// One labelled case: a fixture, the operations to run on it, and the exact
    /// bytes the storage must then hold. `size` is asserted from the same
    /// expectation, so a storage that reads right but counts wrong still fails.
    private struct Case {
        let name: String
        let initial: [UInt8]
        let expected: [UInt8]
        let apply: (any EditableByteStorage) throws -> Void
    }

    private func check(_ cases: [Case], file: StaticString = #filePath, line: UInt = #line) {
        for implementation in Self.implementations {
            for testCase in cases {
                let label = "\(implementation.name)/\(testCase.name)"
                do {
                    let storage = try implementation.make(testCase.initial)
                    try testCase.apply(storage)
                    XCTAssertEqual(try TestSupport.readAll(storage), testCase.expected,
                                   "\(label): content", file: file, line: line)
                    XCTAssertEqual(storage.size, UInt64(testCase.expected.count),
                                   "\(label): size", file: file, line: line)
                } catch {
                    XCTFail("\(label): threw \(error)", file: file, line: line)
                }
            }
        }
    }

    // MARK: - Overwrite

    func testOverwrite() {
        check([
            Case(name: "in place, read back",
                 initial: [0x00, 0x00, 0x00, 0x00],
                 expected: [0x00, 0xAA, 0xBB, 0x00],
                 apply: { try $0.overwrite(range: 1..<3, with: [0xAA, 0xBB]) }),
            Case(name: "starting at EOF extends the file",
                 initial: [0x00],
                 expected: [0x00, 0x01, 0x02],
                 apply: { try $0.overwrite(range: 1..<1, with: [0x01, 0x02]) }),
            // The gap a write past EOF leaves has always read as zeros.
            Case(name: "far beyond EOF zero-fills the gap",
                 initial: [0x01, 0x02],
                 expected: [0x01, 0x02, 0x00, 0x00, 0x00, 0x99],
                 apply: { try $0.overwrite(range: 5..<5, with: [0x99]) }),
            Case(name: "empty bytes are a no-op",
                 initial: [0x01, 0x02],
                 expected: [0x01, 0x02],
                 apply: { try $0.overwrite(range: 0..<0, with: []) }),
        ])
    }

    // MARK: - Insert

    func testInsert() {
        check([
            Case(name: "in the middle shifts the tail",
                 initial: [0x01, 0x02, 0x03, 0x04],
                 expected: [0x01, 0x02, 0xFF, 0xFE, 0x03, 0x04],
                 apply: { try $0.insert(at: 2, bytes: [0xFF, 0xFE]) }),
            Case(name: "at EOF appends",
                 initial: [0x01, 0x02],
                 expected: [0x01, 0x02, 0x03],
                 apply: { try $0.insert(at: 2, bytes: [0x03]) }),
            Case(name: "past EOF is clamped to EOF",
                 initial: [0x01, 0x02],
                 expected: [0x01, 0x02, 0x03],
                 apply: { try $0.insert(at: 50, bytes: [0x03]) }),
        ])
    }

    // MARK: - Delete

    func testDelete() {
        check([
            Case(name: "a middle range shrinks the file",
                 initial: [0x00, 0x01, 0x02, 0x03, 0x04, 0x05],
                 expected: [0x00, 0x01, 0x04, 0x05],
                 apply: { try $0.delete(range: 2..<4) }),
            Case(name: "an end past EOF is clamped",
                 initial: [0x00, 0x01],
                 expected: [0x00],
                 apply: { try $0.delete(range: 1..<10) }),
            Case(name: "everything leaves an empty file",
                 initial: [0x01, 0x02, 0x03],
                 expected: [],
                 apply: { try $0.delete(range: 0..<3) }),
            Case(name: "an empty range is a no-op",
                 initial: [0x01, 0x02],
                 expected: [0x01, 0x02],
                 apply: { try $0.delete(range: 1..<1) }),
        ])
    }

    // MARK: - Append

    func testAppend() {
        check([
            Case(name: "onto content",
                 initial: [0x01],
                 expected: [0x01, 0x02, 0x03],
                 apply: { try $0.append([0x02, 0x03]) }),
            Case(name: "onto an empty file",
                 initial: [],
                 expected: [0xDE, 0xAD],
                 apply: { try $0.append([0xDE, 0xAD]) }),
        ])
    }

    // MARK: - Sequences

    func testSequencesOfEdits() {
        check([
            Case(name: "an untouched empty file reads empty",
                 initial: [],
                 expected: [],
                 apply: { _ in }),
            // Growing an empty file, then editing inside what was added.
            Case(name: "empty: append then insert",
                 initial: [],
                 expected: [0xDE, 0xBE, 0xAD],
                 apply: {
                     try $0.append([0xDE, 0xAD])
                     try $0.insert(at: 1, bytes: [0xBE])
                 }),
            Case(name: "empty: append, insert, delete",
                 initial: [],
                 expected: [0xBE, 0xAD],
                 apply: {
                     try $0.append([0xDE, 0xAD])
                     try $0.insert(at: 1, bytes: [0xBE])
                     try $0.delete(range: 0..<1)
                 }),
            // 99 01 02 77 78 03 04 05 06 07 → delete 5..<8 (03 04 05) → +EE
            Case(name: "overwrite, insert, delete, append",
                 initial: [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07],
                 expected: [0x99, 0x01, 0x02, 0x77, 0x78, 0x06, 0x07, 0xEE],
                 apply: {
                     try $0.overwrite(range: 0..<1, with: [0x99])
                     try $0.insert(at: 3, bytes: [0x77, 0x78])
                     try $0.delete(range: 5..<8)
                     try $0.append([0xEE])
                 }),
        ])
    }

    // MARK: - Reads

    /// A read never throws for a request past the end; it returns what is there.
    func testReadClampsAtEOF() throws {
        let reads: [(name: String, offset: UInt64, length: Int, expected: [UInt8])] = [
            ("whole file", 0, 3, [0x01, 0x02, 0x03]),
            ("length past EOF", 2, 100, [0x03]),
            ("offset exactly at EOF", 3, 100, []),
            ("offset far past EOF", 50, 2, []),
            ("zero length", 1, 0, []),
        ]
        for implementation in Self.implementations {
            let storage = try implementation.make([0x01, 0x02, 0x03])
            for read in reads {
                XCTAssertEqual(try storage.read(at: read.offset, length: read.length), read.expected,
                               "\(implementation.name)/\(read.name)")
            }
        }
    }
}
