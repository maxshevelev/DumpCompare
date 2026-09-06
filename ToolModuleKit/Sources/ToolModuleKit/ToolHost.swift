import Foundation

/// The open file, as the tool-module bound to it is allowed to see it: read it,
/// write it, say what the dump should draw, and send the view somewhere.
///
/// One host stands for one pane. A session gets it at birth and holds it until
/// `stop()`; everything it can ask for is here, which is also the list of what
/// a tool-module can do to this app at all.
///
/// Two things this deliberately does not carry. There is no way to reach the
/// other pane — a tool-module works on the file it was opened for. And there is
/// no rule about the file's size: whether an operation may move the bytes after
/// it is the tool-module's own business (for a flash dump the answer is usually
/// no, and `Design/UEFI/FIT_TABLE_FORMAT.md` §9.2 says why), and the app's
/// standing rule — overwrite by default, warn on a shift — covers what reaches
/// the document.
@MainActor public protocol ToolHost: AnyObject {
    /// What the panel's header calls the file it is working on.
    var fileName: String { get }
    /// The content's size *now*, unsaved edits included.
    var contentSize: UInt64 { get }
    /// A read-only file refuses `apply`; a tool-module can ask beforehand and
    /// show its own controls as disabled rather than let them fail.
    var isReadOnly: Bool { get }

    /// Where the caret is in the bound pane.
    var caret: UInt64 { get }
    /// What the user has selected there, or nil for a bare caret. A
    /// tool-module reads it to act on what the user is pointing at — "make a
    /// zone of this", "what is this?" — rather than asking them to type an
    /// offset they can already see.
    var selection: Range<UInt64>? { get }

    /// A small read on the main actor: a header, a table, the 48 bytes that
    /// answer "is there really a microcode at this address".
    func read(_ range: Range<UInt64>) throws -> [UInt8]

    /// An immutable view of the whole content, readable from any thread — what
    /// a parse of a 16 MiB image runs over.
    ///
    /// It costs nothing to take (the app already does this for Duplicate) and
    /// it cannot drift: the bytes it answers with are the bytes at the moment
    /// it was taken, whatever the document does afterwards. So a parse never
    /// has to hold the main actor, and never has to worry that an edit landed
    /// halfway through it — the edit arrives as `ToolContentChange` and the
    /// tool-module decides what to do about it.
    func snapshot() throws -> any ToolContentReader

    /// Writes the transaction as one undo step named by it. Throws if the file
    /// is read-only, if the transaction does not validate, or if it reaches
    /// outside the file.
    func apply(_ transaction: ToolTransaction) throws

    /// What the dump draws. Replaces the whole previous map; `.empty` clears it.
    func publish(_ zones: ZoneMap)

    /// Scrolls the dump to `range` — and selects it, when the point is what the
    /// bytes are rather than where they are.
    func reveal(_ range: Range<UInt64>, select: Bool)

    /// Asks the user for a file and hands back its bytes. The panel is the
    /// app's, so the sandbox's access to what the user picked stays on the
    /// app's side of the line and never has to be granted to a tool-module.
    /// Nil when the user cancels or the file cannot be read.
    func requestFile(kinds: [String]) async -> ToolFile?

    /// Offers bytes to the user as a file to save. False when they cancel or
    /// the write fails.
    func exportFile(_ bytes: [UInt8], suggestedName: String) async -> Bool
}

/// Bytes that do not change under the reader, from any thread.
///
/// `Sendable` is the whole point: this is what crosses to a detached task so a
/// parse can run off the main actor.
public protocol ToolContentReader: Sendable {
    var size: UInt64 { get }
    /// Reads `length` bytes at `offset`. Throws rather than truncates when the
    /// range runs past the end — a parser reading past the end is a parser that
    /// trusted a size field it should have checked.
    func read(at offset: UInt64, length: Int) throws -> [UInt8]
}

extension ToolContentReader {
    /// The half-open form, for the ranges everything else in this project
    /// speaks.
    public func read(_ range: Range<UInt64>) throws -> [UInt8] {
        try read(at: range.lowerBound, length: Int(range.upperBound - range.lowerBound))
    }
}

/// A file the user picked, already read.
public struct ToolFile: Equatable, Sendable {
    /// The file's name, without its path — what a tool-module shows and what it
    /// can build a suggested name from.
    public var name: String
    public var bytes: [UInt8]

    public init(name: String, bytes: [UInt8]) {
        self.name = name
        self.bytes = bytes
    }
}
