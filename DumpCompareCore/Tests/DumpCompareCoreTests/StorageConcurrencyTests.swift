import Foundation
import XCTest
@testable import DumpCompareCore

/// The storage types promise that "reads and mutations may come from any
/// thread", and the app relies on it: background diff and search tasks read the
/// same storage the main actor is editing. What that has to mean is that a read
/// returns one state of the file — never a window stitched together from before
/// and after an insert.
final class StorageConcurrencyTests: XCTestCase {
    /// A reusable barrier for a fixed set of threads: every participant meets at
    /// the end of each round, so the interleaving is bounded and repeatable
    /// without a single sleep.
    private final class RoundBarrier: @unchecked Sendable {
        private let condition = NSCondition()
        private let participants: Int
        private var waiting = 0
        private var generation = 0

        init(participants: Int) {
            self.participants = participants
        }

        func waitForRound() {
            condition.lock()
            let current = generation
            waiting += 1
            if waiting == participants {
                waiting = 0
                generation += 1
                condition.broadcast()
            } else {
                while generation == current { condition.wait() }
            }
            condition.unlock()
        }
    }

    /// What the threads report back, under one lock.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var failures: [String] = []
        /// Per reader, the insert count each of its reads saw, in read order.
        private(set) var observed: [[Int]]

        init(readers: Int) {
            observed = [[Int]](repeating: [], count: readers)
        }

        func fail(_ message: String) {
            lock.lock()
            failures.append(message)
            lock.unlock()
        }

        func note(reader: Int, sawInserts count: Int) {
            lock.lock()
            observed[reader].append(count)
            lock.unlock()
        }
    }

    /// A read that races an insert must return a window that some single state of
    /// the file explains — one of "n bytes inserted at the front", for exactly
    /// one n. A torn read (part of the window from before the insert, part from
    /// after) matches none of them.
    ///
    /// The insert is always at offset 0, so every valid state is
    /// `[0xFF] * n + base`, and 0xFF appears nowhere in the base — which makes
    /// the state that explains a window unique and lets the reader name it.
    func testAReadRacingAnInsertAlwaysSeesOneStateOfTheFile() throws {
        let rounds = 120
        let base = (0..<400).map { UInt8($0 % 251) }
        XCTAssertFalse(base.contains(0xFF), "0xFF marks inserted bytes, so the base must not use it")
        /// Every state the file can legally be in during the run.
        let states = (0...rounds).map { [UInt8](repeating: 0xFF, count: $0) + base }

        let url = try TestSupport.makeTempFile(contents: Data(base))
        let storage = EditOverlayStorage(base: try FileBackedStorage(url: url))

        // Each window is long enough (or far enough out) that no two states can
        // produce the same bytes in it: a window of 64 bytes at offset 0 would be
        // all 0xFF from the 64th insert on, and then a reader could not say which
        // state it saw. Two windows straddle the insert point, one sits in the
        // tail the inserts keep pushing along.
        let windows: [(offset: UInt64, length: Int)] = [(0, 200), (100, 200), (250, 64)]
        let barrier = RoundBarrier(participants: windows.count + 1)
        let recorder = Recorder(readers: windows.count)

        /// The one state that explains `bytes` read at `offset`, or nil for none
        /// and nil for more than one.
        @Sendable func stateExplaining(_ bytes: [UInt8], at offset: UInt64, length: Int) -> Int? {
            var match: Int?
            for (inserted, content) in states.enumerated() {
                let start = Int(offset)
                guard start < content.count else { continue }
                let end = min(start + length, content.count)
                guard bytes == Array(content[start..<end]) else { continue }
                if match != nil { return nil }
                match = inserted
            }
            return match
        }

        let writer: @Sendable () -> Void = {
            for _ in 0..<rounds {
                do {
                    try storage.insert(at: 0, bytes: [0xFF])
                } catch {
                    recorder.fail("the writer threw: \(error)")
                }
                barrier.waitForRound()
            }
        }

        let readers: [@Sendable () -> Void] = windows.enumerated().map { index, window in
            {
                for round in 0..<rounds {
                    do {
                        let bytes = try storage.read(at: window.offset, length: window.length)
                        if let inserted = stateExplaining(bytes, at: window.offset,
                                                          length: window.length) {
                            recorder.note(reader: index, sawInserts: inserted)
                        } else {
                            recorder.fail("window \(window.offset) round \(round): no single state "
                                          + "of the file explains "
                                          + "\(bytes.prefix(16).map { String($0, radix: 16) })")
                        }
                    } catch {
                        recorder.fail("window \(window.offset) round \(round) threw: \(error)")
                    }
                    barrier.waitForRound()
                }
            }
        }

        let finished = DispatchSemaphore(value: 0)
        for body in [writer] + readers {
            Thread {
                body()
                finished.signal()
            }.start()
        }
        for _ in 0...windows.count { finished.wait() }

        XCTAssertEqual(recorder.failures, [])
        XCTAssertEqual(storage.size, UInt64(base.count + rounds))
        XCTAssertEqual(try storage.read(at: 0, length: rounds + 2),
                       [UInt8](repeating: 0xFF, count: rounds) + [0x00, 0x01])

        // The premise: every reader read while the file was growing under it, not
        // before the writer started or after it finished. One round is one
        // insert, so a reader that raced the whole run sees the count climb from
        // at most 1 to at least `rounds - 1`.
        for (index, counts) in recorder.observed.enumerated() {
            XCTAssertEqual(counts.count, rounds, "window \(windows[index].offset): every read landed")
            guard let low = counts.min(), let high = counts.max() else { continue }
            XCTAssertGreaterThanOrEqual(high - low, rounds - 2,
                                        "window \(windows[index].offset): the reads spanned the run")
            XCTAssertEqual(counts, counts.sorted(),
                           "window \(windows[index].offset): a later read never saw an earlier state")
        }
    }
}
