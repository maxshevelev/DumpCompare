import Foundation

/// Stable identity of a file on disk (decision D8).
///
/// Two URLs refer to the same file — across hard links, symlinks, or relative
/// vs absolute paths — when their `stat(2)` device + inode numbers and volume
/// identity match. When `stat` fails (file gone, still being written), identity
/// falls back to the standardized path with symlinks resolved, so equality keeps
/// working for not-yet-existing Save As targets.
///
/// Equality is deliberately about the underlying file, not the spelling of the
/// path.
public struct FileIdentity: Equatable, Sendable, CustomStringConvertible {
    /// Device number (`st_dev`) when `stat` succeeded.
    public let deviceID: Int32?
    /// Inode number (`st_ino`) when `stat` succeeded.
    public let fileID: UInt64?
    /// Volume identity (`statfs` fsid) when available; disambiguates the same
    /// `(device, inode)` on different volumes.
    public let volumeID: String?
    /// Standardized path with symlinks resolved; the equality key when `stat`
    /// failed.
    public let standardizedPath: String

    /// Computes identity for `url` via `stat(2)` + `statfs(2)`, falling back to
    /// the resolved standardized path if the file cannot be stat'ed.
    public init(url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        self.standardizedPath = resolved.path

        var st = stat()
        // Unqualified call: qualified `Darwin.stat` resolves to the `stat` type,
        // not the function, so the function would never be found.
        if stat(url.path, &st) == 0 {
            self.deviceID = Int32(st.st_dev)
            self.fileID = st.st_ino
            self.volumeID = Self.volumeIdentity(for: url.path)
        } else {
            self.deviceID = nil
            self.fileID = nil
            self.volumeID = nil
        }
    }

    /// Identity from a resolved path only (used when no file exists yet).
    public init(standardizedPath: String) {
        self.standardizedPath = standardizedPath
        self.deviceID = nil
        self.fileID = nil
        self.volumeID = nil
    }

    public static func == (lhs: FileIdentity, rhs: FileIdentity) -> Bool {
        if let ldev = lhs.deviceID, let lino = lhs.fileID,
           let rdev = rhs.deviceID, let rino = rhs.fileID {
            return ldev == rdev && lino == rino && lhs.volumeID == rhs.volumeID
        }
        // Fall back to the resolved path when either side could not be stat'ed.
        return lhs.standardizedPath == rhs.standardizedPath
    }

    public var description: String {
        if let deviceID, let fileID {
            return "file \(fileID) on dev \(deviceID) (\(volumeID ?? "unknown volume"))"
        }
        return "path \(standardizedPath)"
    }

    /// Filesystem ID of the volume containing `path` (`statfs` `f_fsid`).
    private static func volumeIdentity(for path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let v = fs.f_fsid.val
        return "\(v.0)-\(v.1)"
    }
}
