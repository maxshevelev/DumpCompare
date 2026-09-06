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
    /// Called once the add form's catalogue has arrived — empty when it could
    /// not be fetched. Another seam for the app's tests, which wait on it
    /// rather than on the clock.
    public var onCatalogueLoaded: (([MicrocodeCatalogueEntry]) -> Void)?
    private var focus: Int?
    /// The CPUIDs this image already names, which is what the add form opens
    /// on: a dump is for one board.
    private var cpuidsInTheImage: Set<UInt32> = []

    /// The add form while it is on screen.
    private var form: FITAddMicrocodeViewController?

    /// Which parse is the current one. A file edited twice in quick succession
    /// starts two, and the one that finishes second is not necessarily the one
    /// that read the newer bytes.
    private var generation = 0

    /// Where microcode comes from. Swappable, because a test suite that
    /// reaches GitHub is a suite that fails on a train.
    public static var microcodeSource: any MicrocodeSource = CPUMicrocodesRepository()

    public init(host: any ToolHost) {
        self.host = host
        controller.onSelect = { [weak self] index in self?.select(index) }
        controller.onGoToTarget = { [weak self] index in self?.goToOffset(of: index) }
        controller.onCopyCPUID = { [weak self] index in self?.copyCPUID(of: index) }
        controller.onRemoveEntry = { [weak self] index in self?.removeEntry(at: index) }
        controller.onAddMicrocode = { [weak self] in self?.addMicrocode() }
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
        cpuidsInTheImage = Set(display.rows.compactMap {
            $0.cpuidText.flatMap { UInt32($0, radix: 16) }
        })
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

    /// Where the row leads: what it points at, or — for the header and for an
    /// empty slot — the row's own bytes in the table. Every row has an offset,
    /// so every row goes somewhere.
    ///
    /// The zone is brought to the front and the dump is taken there, but
    /// nothing is *selected*: an active outline says "this is what you asked
    /// for" without touching a selection the user may be part-way through.
    ///
    /// Public because neither a double-click nor a right-click can be
    /// simulated — `clickedRow` is -1 unless a real mouse put it there — so
    /// this is the level the app's tests drive.
    public func goToOffset(of index: Int) {
        guard let row = display.rows.first(where: { $0.index == index }) else { return }
        focus = index
        show(display.focusingTarget(of: index))
        host.reveal(row.offsetToGoTo..<(row.offsetToGoTo + 1), select: false)
    }

    /// The user picked one of our zones in the dump. The bytes are already
    /// selected; what is left is to bring the row it stands for to the front,
    /// which is the half only this side knows how to do.
    public func zoneSelected(_ id: Zone.ID) {
        focus = FITPresenter.rowIndex(ofZone: id)
        show(display.focusing(zoneID: id))
    }

    /// Where a copy goes. Swappable so the app's tests do not walk off with
    /// whatever the person running them had on their clipboard.
    public static var pasteboard: NSPasteboard = .general

    /// The number a bench writes down and looks up.
    public func copyCPUID(of index: Int) {
        guard let cpuid = display.rows.first(where: { $0.index == index })?.cpuidText else {
            return
        }
        FITToolSession.pasteboard.clearContents()
        FITToolSession.pasteboard.setString(cpuid, forType: .string)
        controller.say("CPUID \(cpuid) copied.")
    }

    private func goToProblem(_ index: Int) {
        guard index < display.problems.count, let offset = display.problems[index].offset else {
            return
        }
        host.reveal(offset..<min(offset + 16, host.contentSize), select: true)
    }

    // MARK: - Adding and removing

    /// Opens the form: the catalogue at `github.com/platomav/CPUMicrocodes`,
    /// searchable by CPUID, with the file names doing the describing so nothing
    /// is downloaded until one is picked.
    private func addMicrocode() {
        let form = FITAddMicrocodeViewController()
        self.form = form
        form.cpuidsInTheImage = cpuidsInTheImage
        form.onCancel = { [weak self] in self?.closeForm() }
        form.onAdd = { [weak self] entry in self?.download(entry) }
        form.onChooseFile = { [weak self] in self?.chooseMicrocodeFile() }
        controller.presentAsSheet(form)

        form.say("Fetching the list from github.com…", busy: true)
        let source = FITToolSession.microcodeSource
        Task { [weak self, weak form] in
            do {
                let entries = try await source.catalogue()
                form?.show(entries)
                self?.onCatalogueLoaded?(entries)
            } catch {
                form?.say(error.localizedDescription)
                self?.onCatalogueLoaded?([])
            }
        }
    }

    private func closeForm() {
        guard let form else { return }
        controller.dismiss(form)
        self.form = nil
    }

    private func download(_ entry: MicrocodeCatalogueEntry) {
        form?.say("Fetching \(entry.fileName)…", busy: true)
        let source = FITToolSession.microcodeSource
        Task { [weak self] in
            do {
                let bytes = try await source.download(entry)
                self?.closeForm()
                self?.addMicrocode(bytes, describedAs: "CPUID \(entry.cpuidText)")
            } catch {
                self?.form?.say(error.localizedDescription)
            }
        }
    }

    /// The way in without a network, and the way in for a microcode this
    /// collection does not have.
    private func chooseMicrocodeFile() {
        Task { [weak self] in
            guard let file = await self?.host.requestFile(kinds: ["bin", "mcu", "dat"]) else {
                return
            }
            self?.closeForm()
            self?.addMicrocode(file.bytes, describedAs: file.name)
        }
    }

    /// Everything after the bytes are in hand: read the image again, work out
    /// where the component goes, and land the whole change as one step.
    ///
    /// Public because it is the half worth driving from a test: the form above
    /// it is a list and a search field, and the network behind that has no
    /// place in a test suite.
    public func addMicrocode(_ component: [UInt8], describedAs description: String) {
        guard !host.isReadOnly else {
            controller.say("This file is open read-only.")
            return
        }
        guard let snapshot = try? host.snapshot() else {
            controller.say("Could not read the file.")
            return
        }
        let progress = host.beginProgress("Adding microcode", onCancel: nil)
        Task { [weak self] in
            let prepared = await FITToolSession.prepareAdd(component, snapshot: snapshot)
            progress.finish()
            guard let self else { return }
            switch prepared {
            case .failure(let problem):
                self.controller.say(problem.message)
            case .success(let (transaction, placement)):
                self.apply(transaction, saying: "Added \(description) at "
                    + "0x\(String(placement.range.lowerBound, radix: 16, uppercase: true))."
                    + " Boot Guard ranges are not checked — this tool cannot read them yet.")
            }
        }
    }

    /// Takes a row out (§10). The component it named stays in the image:
    /// erasing it is the riskier half of step 5.
    public func removeEntry(at index: Int) {
        guard !host.isReadOnly else {
            controller.say("This file is open read-only.")
            return
        }
        guard let snapshot = try? host.snapshot() else {
            controller.say("Could not read the file.")
            return
        }
        let progress = host.beginProgress("Removing entry", onCancel: nil)
        Task { [weak self] in
            let prepared = await FITToolSession.prepareRemove(index, snapshot: snapshot)
            progress.finish()
            guard let self else { return }
            switch prepared {
            case .failure(let problem):
                self.controller.say(problem.message)
            case .success(let transaction):
                self.apply(transaction,
                           saying: "Entry \(index) removed. Its component is still in the image.")
            }
        }
    }

    private func apply(_ transaction: ToolTransaction, saying note: String) {
        do {
            try host.apply(transaction)
            controller.say(note + " ⌘Z takes it back.")
        } catch {
            controller.say("Could not write: \(error)")
        }
    }

    /// Off the main actor, and from the file as it is now rather than from the
    /// parse the panel is showing: the user may have typed in the dump since.
    private nonisolated static func prepareAdd(
        _ component: [UInt8],
        snapshot: any ToolContentReader
    ) async -> Result<(ToolTransaction, FITPlacement), FITEditProblem> {
        await Task.detached(priority: .userInitiated) {
            let source = ToolContentByteSource(reader: snapshot)
            let reader = ImageReader(source)
            let image = UEFIParser.parse(source)
            let report = FITReader.read(reader, image: image)
            guard let table = report.table else { return .failure(.noTable) }

            let header: MicrocodeHeader
            switch FITEditor.microcode(in: component) {
            case .success(let read): header = read
            case .failure(let problem): return .failure(problem)
            }
            // Exactly what the header claims, so a file with something after it
            // does not drag the extra bytes into the image.
            let bytes = Array(component.prefix(Int(header.totalSize)))

            let placement: FITPlacement
            switch FITEditor.placement(
                forSize: UInt64(header.totalSize), table: table, image: image,
                reader: reader, addressDiff: report.addressDiff
            ) {
            case .success(let found): placement = found
            case .failure(let problem): return .failure(problem)
            }
            return FITEditor.addMicrocode(bytes, at: placement, to: table, in: reader)
                .map { ($0, placement) }
        }.value
    }

    private nonisolated static func prepareRemove(
        _ index: Int,
        snapshot: any ToolContentReader
    ) async -> Result<ToolTransaction, FITEditProblem> {
        await Task.detached(priority: .userInitiated) {
            let reader = ImageReader(ToolContentByteSource(reader: snapshot))
            guard let table = FITReader.read(reader, image: nil).table else {
                return .failure(.noTable)
            }
            return FITEditor.removeEntry(index, from: table, in: reader)
        }.value
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
