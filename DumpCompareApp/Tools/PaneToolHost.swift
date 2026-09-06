import Cocoa
import DumpCompareCore
import ToolModuleKit

/// One open pane, as the tool-module bound to it is allowed to see it — the
/// app's side of `ToolHost` (`Design/TOOL_MODULES_PLAN.md`).
///
/// It holds the pane and the tab weakly and answers from them: everything a
/// tool-module reads is read at the moment it asks, so a session cannot serve
/// its panel from a copy of the file made when it started. When the pane goes,
/// every call fails rather than answering about a file that is no longer there.
@MainActor final class PaneToolHost: ToolHost {
    /// The pane this host is about — the one the session is bound to, which is
    /// not necessarily the active one.
    private(set) weak var pane: PaneViewModel?
    private weak var owner: MainViewController?
    private weak var tools: ToolController?

    /// Where a snapshot puts whatever it has to spill. It belongs to the host
    /// and goes with it, so a parse that outlives its session still reads
    /// through a file nothing else will remove.
    private let scratch = TemporaryFileStore()

    init(pane: PaneViewModel, owner: MainViewController, tools: ToolController) {
        self.pane = pane
        self.owner = owner
        self.tools = tools
    }

    var fileName: String { pane?.status.fileName ?? "" }
    var contentSize: UInt64 { pane?.fileSize ?? 0 }
    var isReadOnly: Bool { pane?.status.isReadOnly ?? true }

    var caret: UInt64 { pane?.caretOffset ?? 0 }

    var selection: Range<UInt64>? {
        guard let selection = pane?.hexSelection(), !selection.isEmpty else { return nil }
        return selection.start..<selection.end
    }

    func read(_ range: Range<UInt64>) throws -> [UInt8] {
        guard let storage = pane?.byteStorage else { throw ToolHostError.noFile }
        guard range.lowerBound <= range.upperBound, range.upperBound <= storage.size else {
            throw ToolHostError.outsideTheFile
        }
        return try storage.read(at: range.lowerBound, length: Int(range.count))
    }

    /// The document's content frozen as it is now — including unsaved edits,
    /// which is the point: the panel has to describe the dump on screen and not
    /// the file on disk.
    ///
    /// This is what Duplicate already does (§23), and for the same reason: the
    /// snapshot copies no bytes, cannot be disturbed by later edits, and is
    /// readable from any thread. A parse of a 16 MiB image therefore runs off
    /// the main actor without holding anything still.
    func snapshot() throws -> any ToolContentReader {
        guard let storage = pane?.document?.storage else { throw ToolHostError.noFile }
        guard let overlay = storage as? EditOverlayStorage else {
            throw ToolHostError.noFile
        }
        return FrozenContent(storage: try overlay.contentSnapshot(scratch: scratch))
    }

    /// Writes the transaction as one named undo step.
    ///
    /// Everything that can be wrong with it is decided before a byte moves: the
    /// file must be there and writable, the transaction must validate (which is
    /// where two writes over one byte are caught), and every write must land
    /// inside the file. A tool-module that computed an offset wrong therefore
    /// gets an error rather than an image with a microcode written into the
    /// middle of something else — the failure §11 of the FIT document is a
    /// post-mortem of.
    ///
    /// Overwrite only, and deliberately: a dump's size is the flash chip's
    /// size. A tool-module that needs to insert or delete does it through the
    /// app's own shifting edits, under the warning they already carry.
    func apply(_ transaction: ToolTransaction) throws {
        guard let pane, pane.isOpen, let document = pane.document else {
            throw ToolHostError.noFile
        }
        guard !pane.status.isReadOnly else { throw ToolHostError.readOnly }
        let checked = try transaction.validated()
        let size = document.size
        for write in checked.writes where write.range.upperBound > size {
            throw ToolHostError.outsideTheFile
        }
        try pane.applyToolWrites(checked.writes.map { ($0.offset, $0.bytes) },
                                 named: checked.name)
    }

    func publish(_ zones: ZoneMap) {
        tools?.publish(zones, from: self)
    }

    func reveal(_ range: Range<UInt64>, select: Bool) {
        guard let pane, let owner else { return }
        owner.revealForTool(range, in: pane, select: select)
    }

    /// Asks the user for a file and hands back its bytes. The panel is the
    /// app's, so the sandbox's grant on what the user picked stays on this side
    /// of the line: a tool-module is never given a URL or a scope to hold.
    func requestFile(kinds: [String]) async -> ToolFile? {
        guard let owner else { return nil }
        return owner.requestFileForTool(kinds: kinds, message: String?.none)
    }

    func exportFile(_ bytes: [UInt8], suggestedName: String) async -> Bool {
        guard let owner else { return false }
        return owner.exportFileForTool(bytes, suggestedName: suggestedName)
    }
}

/// Bytes that cannot change, from any thread: an immutable storage snapshot
/// behind the reader a tool-module was given.
private struct FrozenContent: ToolContentReader {
    let storage: any ByteStorage

    var size: UInt64 { storage.size }

    func read(at offset: UInt64, length: Int) throws -> [UInt8] {
        guard length >= 0, offset &+ UInt64(length) <= size else {
            throw ToolHostError.outsideTheFile
        }
        return try storage.read(at: offset, length: length)
    }
}

/// What the host refuses, and why. Each case is something a tool-module's
/// author can act on rather than a bare failure.
enum ToolHostError: Error, Equatable {
    /// The pane has no document — it was closed under the session.
    case noFile
    /// The range asked for is not inside the file.
    case outsideTheFile
    /// The file is open read-only.
    case readOnly
}
