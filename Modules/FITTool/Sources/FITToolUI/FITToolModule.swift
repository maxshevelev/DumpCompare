import AppKit
import FITTool
import ToolModuleKit
import UEFIContentSource
import UEFIImage

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
/// nothing else. The reading is worth doing again — it is a handful of lookups
/// over the pane's own tree — and a tree of thousands of nodes per parked
/// tool-module is how an app comes to hold four copies of an image it is not
/// showing (`ToolSession.parkedState`).
struct FITParkedState: ToolSessionState {
    var focus: Int?
}

/// The running instrument: read the table through the pane's shared tree, show
/// what came back, publish the zones, and offer the one repair this tool makes.
///
/// It never parses the image. The mapping every address here is measured
/// against comes from the tree's one descent to the Volume Top File, and what
/// a row points *into* is named by opening that row's own chain — so opening
/// this panel after the UEFI one costs nothing the UEFI one has already paid
/// for, and neither of them ever walks the whole file.
@MainActor public final class FITToolSession: ToolSession {
    private let host: any ToolHost
    private let controller = FITToolViewController()
    /// What the panel is showing. Readable from outside so the app's tests can
    /// assert on it without reaching into a view.
    public private(set) var display = FITDisplay.empty
    /// Called on the main actor once a reading has landed and the panel has
    /// been shown. It runs off the main actor, so a test that waited for it on
    /// the clock would be a test that fails on a busy machine.
    public var onDisplay: ((FITDisplay) -> Void)?
    /// Called on the main actor once the Points-at column has been filled in —
    /// the pass that runs behind the table rather than in front of it. Not
    /// `onDisplay`: that one means "the table is up", and a test waiting for it
    /// must not be answered twice.
    public var onTargetsNamed: (() -> Void)?

    /// Called once the add form's catalogue has arrived — empty when it could
    /// not be fetched. Another seam for the app's tests, which wait on it
    /// rather than on the clock.
    public var onCatalogueLoaded: (([MicrocodeCatalogueEntry]) -> Void)?

    /// The same seam as a method, because `try session().onCatalogueLoaded = {}`
    /// puts the `try` inside the closure as far as the compiler is concerned.
    public func withCatalogueSeam(_ body: @escaping () -> Void) {
        onCatalogueLoaded = { _ in body() }
    }
    private var focus: Int?
    /// The CPUIDs this image already names, which is the narrowing the add
    /// form offers: a dump is for one board.
    private var cpuidsInTheImage: Set<UInt32> = []

    /// The add form while it is on screen.
    private var form: FITAddMicrocodeViewController?

    /// True while a reading is off the main actor. A catalogue that lands in
    /// that window is not re-shown over the table mid-read — the reading itself
    /// applies it when it lands, and a re-show would publish a stale zone map
    /// over a file that is being re-read.
    private var isParsing = false

    /// The catalogue of what can be added, read once into the session rather
    /// than once per sheet: a row's "latest" verdict has its basis, and the
    /// add form has its list, from one fetch of the whole repository.
    private var catalogue: [MicrocodeCatalogueEntry] = []

    /// The read in flight, so a form that opens while it runs joins it rather
    /// than starting a second fetch. Nil once a read has finished.
    private var catalogueLoad: Task<Void, Never>?

    /// Listening for a newer listing. Cancelled in `stop()`.
    private var catalogueWatch: Task<Void, Never>?

    /// Which reading is the current one. A file edited twice in quick
    /// succession starts two, and the one that finishes second is not
    /// necessarily the one that read the newer bytes.
    private var generation = 0

    /// The tree this session built for itself, under a host that offers no
    /// shared one — a test double. Dropped whenever the content changes, since
    /// it is over a frozen snapshot rather than the live file.
    private var ownTree: LazyUEFITree?

    /// Where microcode comes from. Swappable, because a test suite that
    /// reaches GitHub is a suite that fails on a train.
    public static var microcodeSource: any MicrocodeSource = CPUMicrocodesRepository()

    public init(host: any ToolHost) {
        self.host = host
        controller.onSelect = { [weak self] index in self?.select(index) }
        controller.onGoToTarget = { [weak self] index in self?.goToOffset(of: index) }
        controller.onSelectTable = { [weak self] in self?.showTable() }
        controller.onCopyCPUID = { [weak self] index in self?.copyCPUID(of: index) }
        controller.onReplaceMicrocode = { [weak self] index in self?.replaceMicrocode(at: index) }
        controller.onRemoveMicrocode = { [weak self] index in self?.removeMicrocode(at: index) }
        controller.onAddMicrocode = { [weak self] in self?.addMicrocode() }
        controller.onGoToProblem = { [weak self] index in self?.goToProblem(index) }
        controller.onFixChecksum = { [weak self] in self?.fixChecksum() }
    }

    public var viewController: NSViewController { controller }

    public func start() {
        controller.say("Reading…")
        // The catalogue starts loading now — a row's "latest" verdict and the
        // add form's list are answered from this one fetch, cached for the
        // session, not fetched again for every sheet.
        loadCatalogue()
        watchTheCatalogue()
        reparse()
    }

    /// The listing is re-checked once a day, behind whatever is being read at
    /// the time, so a table can be rated against a listing that has since been
    /// superseded — and "this microcode is the latest there is" is a verdict
    /// about exactly that listing. When a newer one lands the table is rated
    /// again, the same way the first fetch rates it.
    private func watchTheCatalogue() {
        guard catalogueWatch == nil else { return }
        let source = FITToolSession.microcodeSource
        catalogueWatch = Task { [weak self] in
            for await entries in await source.catalogueChanges() {
                self?.catalogueReady(entries)
            }
        }
    }

    /// Any change is a reason to read again. The table is 128 bytes and the
    /// read is a handful of lookups, so patching what we hold would buy
    /// nothing and cost the one thing this tool sells: that what it shows is
    /// what is in the file. The tree behind it is the pane's, and has already
    /// been told which of its branches the edit made stale.
    public func contentChanged(_ change: ToolContentChange) {
        // A tree of our own is over a frozen snapshot and cannot be told about
        // an edit; the shared one can, and was.
        ownTree = nil
        reparse()
    }

    public func stop() {
        catalogueWatch?.cancel()
        catalogueWatch = nil
    }

    public var parkedState: (any ToolSessionState)? { FITParkedState(focus: focus) }

    public func restore(_ state: any ToolSessionState) {
        guard let state = state as? FITParkedState else { return }
        focus = state.focus
    }

    // MARK: - Reading

    /// The seam a UEFI-aware tool-module reaches through for the pane's one
    /// shared tree — the same protocol `UEFITool` and `MEATool` cast `host`
    /// for, defined in `UEFIImage` so neither side has to depend on the other
    /// or on the app.
    private var treeProvider: (any UEFITreeProviding)? { host as? any UEFITreeProviding }

    /// Reads the table and shows it, then names what its rows point into.
    ///
    /// The table itself needs one thing from the tree — the address mapping,
    /// which is a descent to the Volume Top File — and a handful of point
    /// reads over 128 bytes. That is the panel, and it goes up as soon as it
    /// is read.
    ///
    /// What a row points *into* is a second question and a slower one: it
    /// means opening the branch each address lands in. It is also the least of
    /// what the row says — the address, the type and the size are all already
    /// there — so it is never allowed to hold the table back. The rows go up
    /// with their addresses, and the names join them in front when the
    /// branches have been read.
    private func reparse() {
        generation += 1
        let generation = self.generation
        isParsing = true
        controller.showBusy()
        Task { [weak self] in
            guard let self else { return }
            guard let tree = await self.readyTree() else {
                guard self.generation == generation else { return }
                self.isParsing = false
                self.controller.endBusy()
                self.show(.empty)
                self.fail("Could not read the file.")
                return
            }
            guard self.generation == generation else { return }

            let report = await FITToolSession.read(tree.imageReader, image: tree.image())
            guard self.generation == generation else { return }
            self.isParsing = false

            self.controller.endBusy()
            // A catalogue already in hand rates the rows as they are shown; one
            // that lands later is applied by `catalogueReady`, which re-shows
            // this display with the verdicts filled in.
            self.show(
                FITPresenter.display(report, focus: self.focus)
                    .ratingLatest(against: self.catalogue)
            )
            if self.noticeAnswersTheUser {
                self.noticeAnswersTheUser = false
            } else {
                self.controller.say(FITToolSession.advice(for: report))
            }
            self.onDisplay?(self.display)

            self.nameTargets(of: report, in: tree, generation: generation)
        }
    }

    /// Opens the branches the rows point into and re-reads the table with them
    /// open, so the Points-at column can say what is there rather than only
    /// where. Behind the table rather than in front of it, and silent when
    /// there is nothing to name.
    private func nameTargets(of report: FITReport, in tree: LazyUEFITree, generation: Int) {
        let targets = FITToolSession.offsetsWorthNaming(in: report)
        guard !targets.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.materialize(targets, in: tree)
            guard self.generation == generation else { return }
            let named = await FITToolSession.read(tree.imageReader, image: tree.image())
            guard self.generation == generation else { return }
            // Rated like the first show. This display replaces that one, and a
            // fresh `FITPresenter.display` starts every microcode row back at
            // `.notRated` — so leaving it unrated here is the verdict icons
            // appearing when the table is first drawn and going again the
            // moment the names land.
            self.show(FITPresenter.display(named, focus: self.focus)
                .ratingLatest(against: self.catalogue))
            self.onTargetsNamed?()
        }
    }

    /// The pane's shared tree with its top level built and its address mapping
    /// worked out — the two things a FIT read cannot start without. Nil when
    /// there is no file to read.
    ///
    /// Under a host that offers no shared tree — a test double — one of our
    /// own over a frozen snapshot stands in, dropped whenever the content
    /// changes.
    private func readyTree() async -> LazyUEFITree? {
        let tree: LazyUEFITree
        if let shared = treeProvider?.uefiTree() {
            tree = shared
        } else if let ownTree {
            tree = ownTree
        } else if let snapshot = try? host.snapshot() {
            tree = LazyUEFITree(ToolContentByteSource(reader: snapshot))
            ownTree = tree
        } else {
            return nil
        }
        await withCheckedContinuation { continuation in
            tree.whenReady { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            tree.resolveAddresses { continuation.resume() }
        }
        return tree
    }

    /// Opens the chain of nodes covering each offset, one at a time — what
    /// makes a row able to name what it points into instead of leaving it
    /// blank.
    private func materialize(_ offsets: [UInt64], in tree: LazyUEFITree) async {
        for offset in offsets {
            await withCheckedContinuation { continuation in
                tree.materialize(containing: offset) { _ in continuation.resume() }
            }
        }
    }

    /// The offsets a reading of this report wants named: the ones a row points
    /// at and nothing else is able to say what is there.
    ///
    /// A microcode row is not one of them — its target is read from the
    /// component's own header, which needs no tree at all — and on most images
    /// that is every row there is, so most tables want nothing opened.
    private nonisolated static func offsetsWorthNaming(in report: FITReport) -> [UInt64] {
        guard let table = report.table else { return [] }
        var offsets = Set<UInt64>()
        for row in table.rows {
            if case .bytes(let offset, _) = row.target { offsets.insert(offset) }
        }
        return offsets.sorted()
    }

    /// The same, for an edit: the editor reasons about what holds each
    /// component and what sits behind it, so it wants the table's own
    /// surroundings and every row's target opened, microcode included.
    private nonisolated static func offsetsWorthOpening(in report: FITReport) -> [UInt64] {
        guard let table = report.table else { return [] }
        var offsets = Set([table.range.lowerBound])
        offsets.formUnion(table.rows.compactMap(\.target.offset))
        return offsets.sorted()
    }

    /// Off the main actor: the reads are small, but a table whose pointer does
    /// not check out is answered by a scan of the whole image for `_FIT_   `,
    /// and the panel is on screen while that runs.
    private nonisolated static func read(
        _ reader: ImageReader,
        image: UEFIImage
    ) async -> FITReport {
        await Task.detached(priority: .userInitiated) {
            // The tree is read for one thing this tool cannot work out for
            // itself — where an address lands in the file — and for one that
            // makes it readable: what the bytes at that address belong to.
            FITReader.read(reader, image: image)
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

    /// Whether the line under the buttons is one this session put there in
    /// answer to something the user did.
    ///
    /// Every edit is followed by a re-read, and the re-read has something to
    /// say too — so without this the answer to "did that work?" is wiped by
    /// "every rule checks out" a few milliseconds later, and nobody ever sees
    /// it. It survives exactly one parse: the one its own edit caused.
    private var noticeAnswersTheUser = false

    /// Something the user asked for did not happen. Red, and audible.
    private func fail(_ text: String, inTheForm: Bool = false) {
        FITToolSession.alert()
        noticeAnswersTheUser = true
        if inTheForm, let form {
            form.say(text, asProblem: true)
        } else {
            controller.say(text, asProblem: true)
        }
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

    /// The title names the table, not a row: clicking it puts the whole table
    /// in focus and takes the dump there. A read with no table has nothing to
    /// focus, so it does nothing rather than clear a focus the user set.
    ///
    /// Public because a click on the title is driven the same way the panel's
    /// other clicks are — through the session, not a simulated mouse.
    public func showTable() {
        guard let range = display.zones.zones.first(where: { $0.id == FITPresenter.tableZoneID })?.range
        else { return }
        show(display.focusing(zoneID: FITPresenter.tableZoneID))
        host.reveal(range, select: false)
    }

    /// The user picked one of our zones in the dump. The bytes are already
    /// selected; what is left is to bring the row it stands for to the front,
    /// which is the half only this side knows how to do.
    public func zoneSelected(_ id: Zone.ID) {
        focus = FITPresenter.rowIndex(ofZone: id)
        show(display.focusing(zoneID: id))
    }

    /// How a refusal asks for attention. The panel is a narrow strip beside a
    /// dump the user is reading, and a line that appears in it silently is a
    /// line nobody sees.
    ///
    /// Swappable, because a test suite that beeps is a test suite people run
    /// with the volume down.
    public static var alert: @MainActor () -> Void = { NSSound.beep() }

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

    // MARK: - The catalogue

    /// Fetches the catalogue once and caches it in `catalogue`. Called by
    /// `start()` so the session has its answers early, and by a form that
    /// opens with neither a cache nor a read to join.
    private func loadCatalogue() {
        guard catalogueLoad == nil else { return }
        let source = FITToolSession.microcodeSource
        catalogueLoad = Task { [weak self] in
            do {
                let entries = try await source.catalogue()
                self?.catalogueReady(entries)
            } catch {
                self?.catalogueFailed(error)
            }
        }
    }

    /// The catalogue is in hand: it is cached, and any table already on screen
    /// is rated against it — unless a parse is mid-read, which rates its own
    /// rows when it lands — and a form that opened while the fetch ran is fed
    /// by its end.
    private func catalogueReady(_ entries: [MicrocodeCatalogueEntry]) {
        catalogueLoad = nil
        catalogue = entries
        // Nothing to rate before the first parse shows a table: re-showing the
        // empty display over "Reading…" buys nothing, and the parse's own show
        // applies the catalogue.
        if !isParsing && !display.rows.isEmpty {
            show(display.ratingLatest(against: entries))
        }
        if let form, !entries.isEmpty {
            form.show(entries)
        }
        onCatalogueLoaded?(entries)
    }

    /// The fetch failed. A start-time read failing has nobody to tell — the
    /// verdicts stay unrated, and a form that opens later tries the fetch
    /// again. A form already on screen asked for the list, so it is told where
    /// it is looking.
    private func catalogueFailed(_ error: Error) {
        catalogueLoad = nil
        if form != nil {
            fail(error.localizedDescription, inTheForm: true)
        }
        onCatalogueLoaded?([])
    }

    // MARK: - Adding and removing

    /// Opens the form: the catalogue at `github.com/platomav/CPUMicrocodes`,
    /// searchable by CPUID, with the file names doing the describing so nothing
    /// is downloaded until one is picked. The list is the session's cached
    /// catalogue, not a fetch for this sheet.
    private func addMicrocode() {
        let form = FITAddMicrocodeViewController()
        self.form = form
        form.cpuidsInTheImage = cpuidsInTheImage
        form.onCancel = { [weak self] in self?.closeForm() }
        form.onAdd = { [weak self] entry in self?.download(entry) }
        form.onChooseFile = { [weak self] in self?.chooseMicrocodeFile() }
        controller.presentAsSheet(form)
        serveCatalogue(to: form)
    }

    /// Feeds the form its list from the session's catalogue.
    ///
    /// The catalogue is read once, at `start()`, and cached. A form that opens
    /// with the cache in hand is fed from it on the spot; one that opens while
    /// the read is still running says so and is fed when the read lands; and
    /// with neither (a start-time read that failed offline) a read starts now,
    /// because the form is on screen and the list is what it is for.
    private func serveCatalogue(to form: FITAddMicrocodeViewController) {
        if !catalogue.isEmpty {
            form.show(catalogue)
            onCatalogueLoaded?(catalogue)
            return
        }
        if catalogueLoad == nil { loadCatalogue() }
        form.say("Fetching the list from github.com…", busy: true)
    }

    /// The row's "Replace Microcode": the same catalogue, but the form names
    /// itself after the replacing and its button does the replacing. The
    /// replacement need not be the same CPUID — the row, not the processor, is
    /// what is being changed — so the form opens on the whole list rather than
    /// narrowed to the row's own CPUID.
    ///
    /// Public because the menu item that calls it cannot be simulated — a
    /// right-click is not something a test can put on a row — so this is the
    /// level the app's tests drive.
    public func replaceMicrocode(at index: Int) {
        let form = FITAddMicrocodeViewController()
        form.isReplacing = true
        self.form = form
        let target = display.rows.first { $0.index == index }
        form.targetCpuidText = target?.cpuidText
        form.targetCpuid = target?.cpuidText.flatMap { UInt32($0, radix: 16) }
        // The narrowing is to the one CPUID the row names — "replace it with a
        // newer one" — not to everything the image has.
        form.cpuidsInTheImage = form.targetCpuid.map { [$0] } ?? []
        form.onCancel = { [weak self] in self?.closeForm() }
        form.onReplace = { [weak self] entry in self?.replaceMicrocode(entry, at: index) }
        form.onChooseFile = { [weak self] in self?.chooseMicrocodeFile(at: index) }
        controller.presentAsSheet(form)
        serveCatalogue(to: form)
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
                self?.fail(error.localizedDescription, inTheForm: true)
            }
        }
    }

    /// The replace half of the form's button: fetch the picked component, close
    /// the form, and swap it into the row the form was opened from.
    private func replaceMicrocode(_ entry: MicrocodeCatalogueEntry, at index: Int) {
        form?.say("Fetching \(entry.fileName)…", busy: true)
        let source = FITToolSession.microcodeSource
        Task { [weak self] in
            do {
                let bytes = try await source.download(entry)
                self?.closeForm()
                self?.replaceMicrocode(bytes, at: index, describedAs: "CPUID \(entry.cpuidText)")
            } catch {
                self?.fail(error.localizedDescription, inTheForm: true)
            }
        }
    }

    /// The way in without a network, and the way in for a microcode this
    /// collection does not have. When the form opened to replace a row, the
    /// file goes to that row rather than to a new entry.
    private func chooseMicrocodeFile(at index: Int? = nil) {
        Task { [weak self] in
            guard let file = await self?.host.requestFile(kinds: ["bin", "mcu", "dat"]) else {
                return
            }
            self?.closeForm()
            if let index {
                self?.replaceMicrocode(file.bytes, at: index, describedAs: file.name)
            } else {
                self?.addMicrocode(file.bytes, describedAs: file.name)
            }
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
            fail("This file is open read-only.")
            return
        }
        controller.showBusy()
        Task { [weak self] in
            guard let self else { return }
            guard let tree = await self.readyTree() else {
                self.controller.endBusy()
                self.fail("Could not read the file.")
                return
            }
            let prepared = await self.prepareAdd(component, in: tree)
            self.controller.endBusy()
            switch prepared {
            case .failure(let problem):
                self.fail(problem.message)
            case .success(let (transaction, outcome)):
                self.apply(transaction,
                           saying: FITToolSession.note(for: outcome, describedAs: description))
            }
        }
    }

    /// Everything after the bytes are in hand for a replace: read the image
    /// again, swap the row's component, and land the whole change as one step.
    ///
    /// Public because it is the half worth driving from a test: the form above
    /// it is a list and a search field, and the network behind that has no
    /// place in a test suite.
    public func replaceMicrocode(_ component: [UInt8], at index: Int, describedAs description: String) {
        guard !host.isReadOnly else {
            fail("This file is open read-only.")
            return
        }
        controller.showBusy()
        Task { [weak self] in
            guard let self else { return }
            guard let tree = await self.readyTree() else {
                self.controller.endBusy()
                self.fail("Could not read the file.")
                return
            }
            let prepared = await self.prepareReplace(index, component, in: tree)
            self.controller.endBusy()
            switch prepared {
            case .failure(let problem):
                self.fail(problem.message)
            case .success(let (transaction, outcome)):
                self.apply(transaction,
                           saying: FITToolSession.note(for: outcome, describedAs: description))
            }
        }
    }

    /// Takes a microcode out of the table (§10): the row goes, the component's
    /// bytes go with it, and what followed it in the run moves up into the
    /// space — the run is one block, and a hole in the middle of it is not what
    /// a bench wants back.
    public func removeMicrocode(at index: Int) {
        guard !host.isReadOnly else {
            fail("This file is open read-only.")
            return
        }
        controller.showBusy()
        Task { [weak self] in
            guard let self else { return }
            guard let tree = await self.readyTree() else {
                self.controller.endBusy()
                self.fail("Could not read the file.")
                return
            }
            let prepared = await self.prepareRemove(index, in: tree)
            self.controller.endBusy()
            switch prepared {
            case .failure(let problem):
                self.fail(problem.message)
            case .success(let (transaction, outcome)):
                self.apply(transaction, saying: FITToolSession.note(for: outcome))
            }
        }
    }

    private func apply(_ transaction: ToolTransaction, saying note: String) {
        do {
            try host.apply(transaction)
            noticeAnswersTheUser = true
            controller.say(note + " ⌘Z takes it back.")
        } catch {
            fail("Could not write: \(error)")
        }
    }

    /// Off the main actor, and from the file as it is now rather than from the
    /// parse the panel is showing: the user may have typed in the dump since.
    private func prepareAdd(
        _ component: [UInt8],
        in tree: LazyUEFITree
    ) async -> Result<(ToolTransaction, FITEditOutcome), FITEditProblem> {
        let reader = tree.imageReader
        guard let table = await placementTable(in: tree) else { return .failure(.noTable) }
        let image = tree.image()
        let addressDiff = image.addressDiff ?? (0x1_0000_0000 &- reader.count)
        return await Task.detached(priority: .userInitiated) {
            FITEditor.addOrReplaceMicrocode(
                component, in: table, image: image, reader: reader,
                addressDiff: addressDiff
            )
        }.value
    }

    /// From the file as it is now rather than from the reading the panel is
    /// showing: the user may have typed in the dump since.
    private func prepareReplace(
        _ index: Int,
        _ component: [UInt8],
        in tree: LazyUEFITree
    ) async -> Result<(ToolTransaction, FITEditOutcome), FITEditProblem> {
        let reader = tree.imageReader
        guard let table = await placementTable(in: tree) else { return .failure(.noTable) }
        let image = tree.image()
        let addressDiff = image.addressDiff ?? (0x1_0000_0000 &- reader.count)
        return await Task.detached(priority: .userInitiated) {
            FITEditor.replaceMicrocode(
                at: index, component, in: table, image: image, reader: reader,
                addressDiff: addressDiff
            )
        }.value
    }

    /// What the panel says afterwards. The Boot Guard caveat is on all three:
    /// a component written into a protected range breaks its hash whether it
    /// arrived in new space or over an old one.
    private static func note(for outcome: FITEditOutcome, describedAs description: String) -> String {
        let at = "0x" + String(outcome.range.lowerBound, radix: 16, uppercase: true)
        let caveat = " Boot Guard ranges are not checked — this tool cannot read them yet."
        guard let replaced = outcome.replaced else {
            return "Added \(description) at \(at)." + caveat
        }
        let was = String(replaced.updateRevision, radix: 16, uppercase: true)
        var note = "Replaced \(description) — revision \(was) — at \(at)"
        if outcome.moved > 0 {
            note += ", and \(outcome.moved) microcode"
                + (outcome.moved == 1 ? "" : "s")
                + " behind it moved to suit the new size"
        }
        return note + "." + caveat
    }

    private func prepareRemove(
        _ index: Int,
        in tree: LazyUEFITree
    ) async -> Result<(ToolTransaction, FITRemovalOutcome), FITEditProblem> {
        let reader = tree.imageReader
        guard let table = await placementTable(in: tree) else { return .failure(.noTable) }
        // The tree, because a removal moves microcode up into the space the
        // removed one leaves, and the addresses that name them come from the
        // same mapping every other address here does.
        let image = tree.image()
        let addressDiff = image.addressDiff ?? (0x1_0000_0000 &- reader.count)
        return await Task.detached(priority: .userInitiated) {
            FITEditor.removeMicrocode(
                index, from: table, image: image, in: reader, addressDiff: addressDiff
            )
        }.value
    }

    /// Reads the table from the file as it is now, and opens the branches the
    /// editor is going to reason about: what element each component lives in,
    /// and what free space sits behind it. Those are the chains covering the
    /// table and every row's target — the same ones a reading opens, asked for
    /// again because the file may have changed since.
    ///
    /// Nil when there is no table to edit.
    private func placementTable(in tree: LazyUEFITree) async -> FITTable? {
        let first = await FITToolSession.read(tree.imageReader, image: tree.image())
        guard first.table != nil else { return nil }
        await materialize(FITToolSession.offsetsWorthOpening(in: first), in: tree)
        return await FITToolSession.read(tree.imageReader, image: tree.image()).table
    }

    /// What the panel says after a removal. Moving a component changes its
    /// address, and anything outside the FIT that named it will not know —
    /// Boot Guard being the one that matters.
    private static func note(for outcome: FITRemovalOutcome) -> String {
        var parts = ["Entry \(outcome.entryIndex) and its component are gone"]
        if outcome.moved > 0 {
            parts.append("\(outcome.moved) microcode"
                + (outcome.moved == 1 ? "" : "s")
                + " moved up and the rows now point there")
        }
        if let erased = outcome.erased {
            parts.append("0x" + String(erased.count, radix: 16, uppercase: true)
                + " bytes erased at the end of the run")
        }
        return parts.joined(separator: "; ") + "."
            + " Boot Guard ranges are not checked — this tool cannot read them yet."
    }

    /// The second defect of §11, and the one a tool can put right on its own:
    /// a checksum left over from an edit that changed the table and did not
    /// recompute it.
    ///
    /// Public because the menu item that calls it cannot be simulated — a
    /// right-click is not something a test can put on a row — so this is the
    /// level the app's tests drive.
    public func fixChecksum() {
        guard let transaction = display.checksumFix else { return }
        do {
            try host.apply(transaction)
            noticeAnswersTheUser = true
            controller.say("Checksum written. ⌘Z takes it back.")
        } catch {
            fail("Could not write: \(error)")
        }
    }
}
