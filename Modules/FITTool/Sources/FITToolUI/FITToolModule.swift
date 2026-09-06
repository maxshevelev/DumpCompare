import AppKit
import FITTool
import ToolModuleKit
import UEFIFormat

/// The Intel Firmware Interface Table, read and checked
/// (`Design/UEFI/FIT_TABLE_FORMAT.md`).
///
/// What it is for: a bench opens a dump and wants to know whether the FIT is
/// intact — where it is, what its entries point at, and which of the rules in
/// §8 the last hand edit broke. It answers by reading, never by assuming: every
/// address is followed to see what is actually there, which is the check the
/// post-mortem in §11 turns on.
public enum FITToolModule: ToolModule {
    public static let identifier = "dev.maxik.tool.fit"
    public static let title = "FIT Table"
    /// Six columns of table need the room; the minimap is happy at 120 and this
    /// is not (`Design/TOOL_MODULES_PLAN.md`).
    public static let preferredPanelWidth: CGFloat = 480

    @MainActor public static func makeSession(host: any ToolHost) -> any ToolSession {
        FITToolSession(host: host)
    }
}

/// What a parked session hands back: the row the user was looking at, and
/// nothing else. The parse is worth doing again — it is milliseconds — and a
/// tree of thousands of nodes per parked tool-module is how an app comes to
/// hold four copies of an image it is not showing (`ToolSession.parkedState`).
struct FITParkedState: ToolSessionState {
    var focus: Int?
}

/// The running instrument: parse off the main actor, show what came back,
/// publish the zones, and offer the one repair this tool makes.
@MainActor public final class FITToolSession: ToolSession {
    private let host: any ToolHost
    private let controller = FITToolViewController()
    /// What the panel is showing. Readable from outside so the app's tests can
    /// assert on it without reaching into a view.
    public private(set) var display = FITDisplay.empty
    /// Called on the main actor once a parse has landed and the panel has been
    /// shown. The parse runs off the main actor, so a test that waited for it
    /// on the clock would be a test that fails on a busy machine.
    public var onDisplay: ((FITDisplay) -> Void)?
    private var focus: Int?
    /// Which parse is the current one. A file edited twice in quick succession
    /// starts two, and the one that finishes second is not necessarily the one
    /// that read the newer bytes.
    private var generation = 0

    public init(host: any ToolHost) {
        self.host = host
        controller.onSelect = { [weak self] index in self?.select(index) }
        controller.onGoToTarget = { [weak self] index in self?.goToTarget(of: index) }
        controller.onGoToProblem = { [weak self] index in self?.goToProblem(index) }
        controller.onFixChecksum = { [weak self] in self?.fixChecksum() }
    }

    public var viewController: NSViewController { controller }

    public func start() {
        controller.say("Reading…")
        reparse()
    }

    /// Any change is a reason to read again. The table is 128 bytes and the
    /// parse is milliseconds, so patching what we hold would buy nothing and
    /// cost the one thing this tool sells: that what it shows is what is in the
    /// file.
    public func contentChanged(_ change: ToolContentChange) {
        reparse()
    }

    public func stop() {}

    public var parkedState: (any ToolSessionState)? { FITParkedState(focus: focus) }

    public func restore(_ state: any ToolSessionState) {
        guard let state = state as? FITParkedState else { return }
        focus = state.focus
    }

    // MARK: - Reading

    private func reparse() {
        let snapshot: any ToolContentReader
        do {
            snapshot = try host.snapshot()
        } catch {
            show(.empty)
            controller.say("Could not read the file: \(error)")
            return
        }

        generation += 1
        let generation = self.generation
        let progress = host.beginProgress("Reading the FIT table", onCancel: nil)
        Task { [weak self] in
            let report = await FITToolSession.parse(snapshot)
            progress.finish()
            guard let self, self.generation == generation else { return }
            self.show(FITPresenter.display(report, focus: self.focus))
            self.controller.say(FITToolSession.advice(for: report))
            self.onDisplay?(self.display)
        }
    }

    /// Off the main actor: a 16 MiB image is a full UEFI parse, and the panel
    /// is on screen while it runs.
    private nonisolated static func parse(_ snapshot: any ToolContentReader) async -> FITReport {
        await Task.detached(priority: .userInitiated) {
            let source = ToolContentByteSource(reader: snapshot)
            // The tree is read for one thing this tool cannot work out for
            // itself — where an address lands in the file — and for one thing
            // that makes it readable: what the bytes at that address belong to.
            let image = UEFIParser.parse(source)
            return FITReader.read(ImageReader(source), image: image)
        }.value
    }

    private static func advice(for report: FITReport) -> String {
        guard report.table != nil else {
            return report.candidates.isEmpty
                ? "Nothing here looks like a firmware image with a FIT."
                : "The pointer and the table disagree. Double-click a problem to look."
        }
        let errors = report.problems.filter { $0.severity == .error }.count
        if errors == 0 { return "Every rule in the specification checks out." }
        return "\(errors) " + (errors == 1 ? "problem" : "problems")
            + " — double-click one to go there."
    }

    private func show(_ display: FITDisplay) {
        self.display = display
        controller.show(display, focus: focus, canWrite: !host.isReadOnly)
        host.publish(display.zones)
    }

    // MARK: - What the panel asks for

    private func select(_ index: Int?) {
        focus = index
        // Publishing again is what moves the outline in the dump, and the host
        // brings a newly focused zone on screen by itself.
        show(display.focusing(index))
    }

    /// Where the row points, which is the question a FIT row exists to answer.
    /// Public because a double-click cannot be simulated — `clickedRow` is -1
    /// unless a real mouse put it there — so this is the level the app's tests
    /// drive.
    public func goToTarget(of index: Int) {
        guard let row = display.rows.first(where: { $0.index == index }),
              let target = row.targetRange
        else {
            controller.say("That entry does not point anywhere in this file.")
            return
        }
        host.reveal(target, select: true)
    }

    private func goToProblem(_ index: Int) {
        guard index < display.problems.count, let offset = display.problems[index].offset else {
            return
        }
        host.reveal(offset..<min(offset + 16, host.contentSize), select: true)
    }

    /// The second defect of §11, and the one a tool can put right on its own:
    /// a checksum left over from an edit that changed the table and did not
    /// recompute it.
    private func fixChecksum() {
        guard let transaction = display.checksumFix else { return }
        do {
            try host.apply(transaction)
            controller.say("Checksum written. ⌘Z takes it back.")
        } catch {
            controller.say("Could not write: \(error)")
        }
    }
}
