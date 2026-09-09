import Foundation
import CryptoKit

/// Hash helpers mirroring upstream `MEA.py` (`sha_1`/`sha_256`/`sha_384` at
/// ~9891, `get_hash` at ~9898, `calc_hash_hex`/`calc_hash` at ~10131). Every
/// digest is uppercase hex when rendered (`get_hash` appends `.upper()`), the
/// form that keys `RSAPKEY_*` and firmware rows; the raw `Data` variants feed
/// the RSA-PSS signature check (upstream `calc_hash`, which needs digest bytes
/// to build the encoded message).
enum Digest {
    /// SHA-256 of `data`, uppercase hex — upstream `sha_256` + `get_hash(x, 0x20)`.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    /// SHA-384 of `data`, uppercase hex — upstream `sha_384` + `get_hash(x, 0x30)`.
    static func sha384Hex(_ data: Data) -> String {
        SHA384.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    /// Raw SHA-1 digest bytes (the `$MAN`/2048-bit signature path).
    static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    /// Raw SHA-256 digest bytes.
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Raw SHA-384 digest bytes.
    static func sha384(_ data: Data) -> Data {
        Data(SHA384.hash(data: data))
    }

    /// Digest of the chosen size, selected like upstream `get_hash`: 0x10 = MD5
    /// (unused by the port so far), 0x14 = SHA-1, 0x20 = SHA-256, 0x30 = SHA-384.
    static func raw(_ hashSize: Int, _ data: Data) -> Data {
        switch hashSize {
        case 0x14: return sha1(data)
        case 0x20: return sha256(data)
        default:   return sha384(data)      // 0x30 and anything unknown
        }
    }
}
