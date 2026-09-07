import Foundation

/// Errors thrown by the storage layer.
///
/// The presentation layer maps these to user-facing alerts (§16 of
/// REQUIREMENTS.md). The sandboxed app surfaces `.permissionDenied` when the
/// security-scoped access to a file is missing or has been revoked.
public enum StorageError: Error, Equatable, Sendable {
    case fileNotFound
    case isDirectory
    case notRegularFile
    case permissionDenied
    case readFailed
    case writeFailed
    case invalidOffset

    /// Classifies a POSIX `open(2)` errno into a storage error.
    static func fromOpenError(_ code: Int32) -> StorageError {
        switch code {
        case ENOENT: return .fileNotFound
        case EISDIR: return .isDirectory
        case EACCES, EPERM: return .permissionDenied
        default: return .permissionDenied
        }
    }
}
