import Foundation
import CryptoKit

/// Hash helpers mirroring upstream `MEA.py` (`sha_1`/`sha_256`/`sha_384` at
/// ~9891, `get_hash` at ~9898). Identification needs only SHA-256 for now: the
/// RSA public-key and RSA signature hashes are uppercase hex digests of the raw
/// file bytes — exactly how upstream keys its `RSAPKEY_*` and firmware rows.
///
/// SHA-1/SHA-384 join when the signature-verification path (`rsa_sig_val`) and
/// the 3072-bit SSA-PSS check are ported; this file stays the single home for
/// digests so callers never pick an algorithm inline.
enum Digest {
    /// SHA-256 of `data`, uppercase hex — upstream `sha_256` + `get_hash(x, 0x20)`.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
