import XCTest
@testable import UEFIImage

/// `LazyUEFITree`: the shared, incrementally-materialized parse that a
/// region's raw-area scan and a volume's file walk defer until `expand` asks
/// for them, and that `invalidate` collapses precisely after an edit.
@MainActor
final class LazyUEFITreeTests: XCTestCase {
    private let volumeA = TestImage.volume(
        length: 0x1000,
        files: [TestImage.file(body: [1, 2, 3, 4, 5, 6, 7, 8])]
    )
    private let volumeB = TestImage.volume(
        length: 0x1000,
        files: [TestImage.file(body: [9, 9, 9])]
    )

    /// Two volumes back to back in the BIOS region, so region-level and
    /// volume-level expansion can be tested independently of each other.
    private func twoVolumeImage() -> [UInt8] {
        TestImage.intelImage(
            size: 0x8000,
            regions: [
                (.descriptor, 0..<0x1000),
                (.me, 0x1000..<0x2000),
                (.bios, 0x4000..<0x8000)
            ],
            contents: [.bios: volumeA + volumeB]
        )
    }

    /// Awaits `expand`, whether it resolves synchronously (a volume) or in
    /// the background (a region).
    private func expandAsync(_ tree: LazyUEFITree, _ id: NodeID) async -> [UEFINode] {
        await withCheckedContinuation { continuation in
            tree.expand(id) { children in
                continuation.resume(returning: children)
            }
        }
    }

    /// A reference-type `ByteSource`, standing in for the app's real
    /// `EditOverlayStorage`: mutable, and read live by anything holding a
    /// reference to it — the property `LazyUEFITree.invalidate` relies on to
    /// need no "fresh bytes" of its own.
    private final class MutableByteSource: ByteSource, @unchecked Sendable {
        private var storage: [UInt8]
        init(_ bytes: [UInt8]) { storage = bytes }
        var byteCount: UInt64 { UInt64(storage.count) }
        func bytes(in range: Range<UInt64>) -> [UInt8] {
            Array(storage[Int(range.lowerBound)..<Int(range.upperBound)])
        }
        func overwrite(at offset: UInt64, with newBytes: [UInt8]) {
            storage.replaceSubrange(Int(offset)..<(Int(offset) + newBytes.count), with: newBytes)
        }
    }

    // MARK: - Roots and region-level laziness

    func testRootsAreAvailableImmediatelyWithoutExpandingRegions() {
        let tree = LazyUEFITree(twoVolumeImage())
        XCTAssertEqual(tree.rootNodes.map(\.kind), [.intelImage])
        let intelChildren = tree.rootNodes[0].children
        XCTAssertEqual(intelChildren.map(\.kind), [.flashDescriptor, .region, .padding, .region])
        let bios = intelChildren.first { $0.name == "BIOS region" }
        XCTAssertNotNil(bios)
        XCTAssertEqual(bios?.children, [])
        XCTAssertTrue(bios?.isExpandable == true)
    }

    func testExpandingARegionRunsInTheBackgroundAndFillsInVolumes() async {
        let tree = LazyUEFITree(twoVolumeImage())
        let bios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!

        XCTAssertFalse(tree.isExpanding(bios.id))
        let children = await expandAsync(tree, bios.id)

        XCTAssertEqual(children.filter { $0.kind == .volume }.count, 2)
        XCTAssertFalse(tree.isExpanding(bios.id))
        // Memoized: children(of:) now answers without expanding again.
        XCTAssertEqual(tree.children(of: bios.id).filter { $0.kind == .volume }.count, 2)
    }

    func testAnMERegionThatIsNotReadFurtherIsNeverExpandable() {
        let tree = LazyUEFITree(twoVolumeImage())
        let me = tree.rootNodes[0].children.first { $0.name == "ME region" }!
        XCTAssertFalse(me.isExpandable)
        XCTAssertEqual(me.children, [])
    }

    // MARK: - region(_:) — cheap, never triggers a scan

    func testRegionLookupWorksBeforeAnyExpansion() {
        let tree = LazyUEFITree(twoVolumeImage())
        XCTAssertEqual(tree.region(.me), 0x1000..<0x2000)
        XCTAssertEqual(tree.region(.bios), 0x4000..<0x8000)
        XCTAssertEqual(tree.region(.descriptor), 0..<0x1000)
        // Asking for the region did not expand it.
        let bios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!
        XCTAssertEqual(bios.children, [])
    }

    func testRegionLookupIsNilForARegionTheDescriptorDidNotMap() {
        let tree = LazyUEFITree(twoVolumeImage())
        XCTAssertNil(tree.region(.gbe))
    }

    // MARK: - Volume-level laziness

    func testExpandingAVolumeIsSynchronousAndFillsInFiles() async {
        let tree = LazyUEFITree(twoVolumeImage())
        let bios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!
        _ = await expandAsync(tree, bios.id)
        let firstVolume = tree.children(of: bios.id)[0]

        XCTAssertTrue(firstVolume.isExpandable)
        XCTAssertEqual(firstVolume.children, [])

        // A volume never goes through the async path: expand() resolves
        // before this call returns, via the synchronous branch.
        var resolvedSynchronously = false
        tree.expand(firstVolume.id) { _ in resolvedSynchronously = true }
        XCTAssertTrue(resolvedSynchronously)

        let files = tree.children(of: firstVolume.id)
        XCTAssertEqual(files.filter { $0.kind == .file }.count, 1)
    }

    func testExpandingOneVolumeDoesNotDisturbItsSibling() async {
        let tree = LazyUEFITree(twoVolumeImage())
        let bios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!
        let volumes = await expandAsync(tree, bios.id).filter { $0.kind == .volume }
        XCTAssertEqual(volumes.count, 2)

        _ = await expandAsync(tree, volumes[0].id)
        // The sibling, looked up fresh through the tree, is still collapsed.
        let sibling = tree.children(of: bios.id)[1]
        XCTAssertTrue(sibling.isExpandable)
        XCTAssertEqual(sibling.children, [])
    }

    // MARK: - Eager/lazy equivalence once fully expanded

    func testFullyExpandedMatchesTheEagerParse() async {
        let bytes = twoVolumeImage()
        let eager = UEFIParser.parse(bytes)

        let tree = LazyUEFITree(bytes)
        await expandEverything(tree, id: nil, nodes: tree.rootNodes)

        XCTAssertEqual(collectAll(tree.rootNodes).map(\.range), collectAll(eager.roots).map(\.range))
        XCTAssertEqual(collectAll(tree.rootNodes).map(\.kind), collectAll(eager.roots).map(\.kind))
        XCTAssertEqual(collectAll(tree.rootNodes).map(\.name), collectAll(eager.roots).map(\.name))
    }

    /// Expands every expandable node reachable from `nodes`, recursively.
    private func expandEverything(_ tree: LazyUEFITree, id: NodeID?, nodes: [UEFINode]) async {
        for node in nodes {
            if node.isExpandable {
                let children = await expandAsync(tree, node.id)
                await expandEverything(tree, id: node.id, nodes: children)
            } else if !node.children.isEmpty {
                await expandEverything(tree, id: node.id, nodes: node.children)
            }
        }
    }

    private func collectAll(_ nodes: [UEFINode]) -> [UEFINode] {
        nodes + nodes.flatMap { collectAll($0.children) }
    }

    // MARK: - invalidate — sizeDelta == 0

    func testInvalidateWithNoOverlapLeavesAnExpandedVolumeAlone() async {
        let tree = LazyUEFITree(twoVolumeImage())
        let bios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!
        let volumes = await expandAsync(tree, bios.id).filter { $0.kind == .volume }
        _ = await expandAsync(tree, volumes[0].id)
        _ = await expandAsync(tree, volumes[1].id)

        // An edit inside the ME region, far from either volume.
        tree.invalidate(editedRange: 0x1000..<0x1004, sizeDelta: 0)

        let refreshedBios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!
        let refreshedVolumes = tree.children(of: refreshedBios.id).filter { $0.kind == .volume }
        XCTAssertEqual(refreshedVolumes.count, 2)
        XCTAssertFalse(tree.children(of: refreshedVolumes[0].id).isEmpty)
        XCTAssertFalse(tree.children(of: refreshedVolumes[1].id).isEmpty)
    }

    func testInvalidateWithOverlapCollapsesOnlyTheAffectedVolume() async {
        let source = MutableByteSource(twoVolumeImage())
        let tree = LazyUEFITree(source)
        let bios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!
        let volumes = await expandAsync(tree, bios.id).filter { $0.kind == .volume }
        _ = await expandAsync(tree, volumes[0].id)
        _ = await expandAsync(tree, volumes[1].id)

        // Flip a byte inside the first volume's file body (well inside its range).
        let editOffset = volumes[0].range.lowerBound + 0x30
        source.overwrite(at: editOffset, with: [0xAA])
        tree.invalidate(editedRange: editOffset..<(editOffset + 1), sizeDelta: 0)

        let refreshedBios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!
        let refreshedVolumes = tree.children(of: refreshedBios.id).filter { $0.kind == .volume }
        // The touched volume collapsed back to expandable/empty…
        XCTAssertTrue(refreshedVolumes[0].isExpandable)
        XCTAssertEqual(refreshedVolumes[0].children, [])
        // …its sibling's already-materialized files are untouched.
        XCTAssertFalse(refreshedVolumes[1].children.isEmpty)
    }

    /// The point of a live source: re-expanding a collapsed node reads the
    /// bytes as they are now, not as they were when the tree was built —
    /// without `invalidate` needing to be handed anything fresh itself.
    func testAReExpandedNodeReadsCurrentBytes() async {
        let source = MutableByteSource(twoVolumeImage())
        let tree = LazyUEFITree(source)
        let bios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!
        let volumes = await expandAsync(tree, bios.id).filter { $0.kind == .volume }
        let firstVolumeID = volumes[0].id

        let filesBefore = await expandAsync(tree, firstVolumeID)
        let fileBodyBefore = filesBefore.first { $0.kind == .file }!.body

        // Overwrite the file's body with new bytes, without changing its
        // recorded size — a pure content change.
        source.overwrite(
            at: fileBodyBefore.lowerBound,
            with: [UInt8](repeating: 0x42, count: Int(fileBodyBefore.count))
        )
        tree.invalidate(editedRange: fileBodyBefore, sizeDelta: 0)

        let filesAfter = await expandAsync(tree, firstVolumeID)
        let fileAfter = filesAfter.first { $0.kind == .file }!
        XCTAssertEqual(source.bytes(in: fileAfter.body), [UInt8](repeating: 0x42, count: Int(fileAfter.body.count)))
    }

    // MARK: - invalidate — sizeDelta != 0

    func testSizeChangingInvalidateCollapsesFromTheEditPointOnward() async {
        let tree = LazyUEFITree(twoVolumeImage())
        let bios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!
        let volumes = await expandAsync(tree, bios.id).filter { $0.kind == .volume }
        _ = await expandAsync(tree, volumes[0].id)
        _ = await expandAsync(tree, volumes[1].id)

        // An insert right at the start of the second volume: everything from
        // there on is now at a different offset.
        let editPoint = volumes[1].range.lowerBound
        tree.invalidate(editedRange: editPoint..<editPoint, sizeDelta: 16)

        let refreshedBios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!
        let refreshedVolumes = tree.children(of: refreshedBios.id).filter { $0.kind == .volume }
        // The first volume, entirely before the edit point, is untouched.
        XCTAssertFalse(refreshedVolumes[0].children.isEmpty)
        // The second volume, at the edit point, collapsed.
        XCTAssertTrue(refreshedVolumes[1].isExpandable)
        XCTAssertEqual(refreshedVolumes[1].children, [])
    }

    // MARK: - Coalescing a second expand while one is already running

    func testASecondExpandWhileOneIsInFlightCoalescesOntoIt() async {
        let tree = LazyUEFITree(twoVolumeImage())
        let bios = tree.rootNodes[0].children.first { $0.name == "BIOS region" }!

        async let first = expandAsync(tree, bios.id)
        // Give the first call a chance to mark the node as expanding before
        // the second one arrives.
        await Task.yield()
        async let second = expandAsync(tree, bios.id)

        let (a, b) = await (first, second)
        XCTAssertEqual(a.filter { $0.kind == .volume }.count, 2)
        XCTAssertEqual(b.filter { $0.kind == .volume }.count, 2)
    }
}
