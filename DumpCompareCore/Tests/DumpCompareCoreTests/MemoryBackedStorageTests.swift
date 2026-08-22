import XCTest
@testable import DumpCompareCore

/// What is specific to the in-memory buffer. The `EditableByteStorage` contract
/// it shares with `EditOverlayStorage` is in `EditableByteStorageContractTests`.
final class MemoryBackedStorageTests: XCTestCase {
    /// The `bytes:` initialiser seeds the buffer; the default one leaves it empty
    /// (File > New File).
    func testInitWithBytes() throws {
        let seeded = MemoryBackedStorage(bytes: [0x01, 0x02, 0x03])
        XCTAssertEqual(seeded.size, 3)
        XCTAssertEqual(try TestSupport.readAll(seeded), [0x01, 0x02, 0x03])

        XCTAssertEqual(MemoryBackedStorage().size, 0)
    }
}
