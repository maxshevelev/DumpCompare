import XCTest
@testable import FreshData

/// A clock the test moves by hand, so nothing here waits on real seconds.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        date += seconds
        lock.unlock()
    }
}

/// What the closure was asked, and how often.
actor Checks {
    private(set) var validators: [String?] = []
    var count: Int { validators.count }

    func record(_ validator: String?) {
        validators.append(validator)
    }
}

/// A one-shot gate, so a test can hold a fetch open and let it go.
actor Gate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { self.waiting = $0 }
    }
}

private let day: TimeInterval = 24 * 60 * 60

/// `Freshened` — the rules a held database follows: fetched once, checked once
/// a day, and kept when the check cannot be made.
final class FreshenedTests: XCTestCase {
    // MARK: Nothing held

    func testTheFirstCallFetches() async throws {
        let cache = Freshened<String>()
        let checks = Checks()

        let value = try await cache.value { validator in
            await checks.record(validator)
            return .fresh("database", validator: "etag-1")
        }

        XCTAssertEqual(value, "database")
        let asked = await checks.validators
        XCTAssertEqual(asked.count, 1)
        XCTAssertNil(asked[0], "with nothing held there is no validator to present")
    }

    func testAFailedFirstFetchIsNotRemembered() async {
        struct Offline: Error {}
        let cache = Freshened<String>()

        do {
            _ = try await cache.value { _ in throw Offline() }
            XCTFail("the error must reach the caller: there is nothing to serve")
        } catch is Offline {
        } catch {
            XCTFail("unexpected \(error)")
        }

        // The network came back. The tool must not go on replaying the old
        // error for the rest of the run.
        let value = try? await cache.value { _ in .fresh("database", validator: nil) }
        XCTAssertEqual(value, "database")
    }

    func testUnchangedWithNothingHeldIsRefused() async {
        let cache = Freshened<String>()
        do {
            _ = try await cache.value { _ in .unchanged }
            XCTFail("nothing is held, so nothing can be unchanged")
        } catch {
            XCTAssertEqual(error as? Freshened<String>.Failure, .unchangedWithNothingHeld)
        }
    }

    // MARK: Held

    func testWithinTheDayTheSourceIsNotAsked() async throws {
        let clock = TestClock()
        let cache = Freshened<String>(now: { clock.now })
        let checks = Checks()

        for _ in 0..<3 {
            clock.advance(60 * 60)
            let value = try await cache.value { validator in
                await checks.record(validator)
                return .fresh("database", validator: "etag-1")
            }
            XCTAssertEqual(value, "database")
        }

        let count = await checks.count
        XCTAssertEqual(count, 1, "the second and third file cost nothing")
    }

    func testAfterADayUnchangedKeepsTheValueAndRestartsTheClock() async throws {
        let clock = TestClock()
        let cache = Freshened<String>(now: { clock.now })
        let checks = Checks()

        _ = try await cache.value { _ in .fresh("database", validator: "etag-1") }
        clock.advance(day + 1)

        let value = try await cache.value { validator in
            await checks.record(validator)
            return .unchanged
        }
        XCTAssertEqual(value, "database")
        await cache.settle()
        let asked = await checks.validators
        XCTAssertEqual(asked, ["etag-1"], "the check presents what was stored")

        // The clock restarted, so the day after the *check*, not after the
        // fetch, is when the next one is due.
        clock.advance(day - 60)
        _ = try await cache.value { _ in
            XCTFail("checked an hour ago; nothing to ask")
            return .unchanged
        }
    }

    func testAfterADayFreshReplacesTheValueForTheNextReader() async throws {
        let clock = TestClock()
        let cache = Freshened<String>(now: { clock.now })

        _ = try await cache.value { _ in .fresh("old", validator: "etag-1") }
        clock.advance(day + 1)

        // This reader is answered from what is held; the new database arrives
        // behind it, for whoever asks next.
        let value = try await cache.value { _ in .fresh("new", validator: "etag-2") }
        XCTAssertEqual(value, "old")
        await cache.settle()

        let next = try await cache.value { _ in
            XCTFail("checked a moment ago; nothing to ask")
            return .unchanged
        }
        XCTAssertEqual(next, "new")

        clock.advance(day + 1)
        _ = try await cache.value { validator in
            XCTAssertEqual(validator, "etag-2", "the new validator is the one presented next")
            return .unchanged
        }
        await cache.settle()
    }

    // MARK: Nobody waits on a check

    func testAReaderIsAnsweredWhileTheCheckIsStillOpen() async throws {
        let clock = TestClock()
        let cache = Freshened<String>(now: { clock.now })
        let release = Gate()
        let entered = Gate()

        _ = try await cache.value { _ in .fresh("yesterday", validator: "etag-1") }
        clock.advance(day + 1)

        let value = try await cache.value { _ in
            await entered.open()
            await release.wait()
            return .fresh("today", validator: "etag-2")
        }
        // The check has not answered and cannot have: nothing has let it go.
        XCTAssertEqual(value, "yesterday", "a reader never waits on the network for what is in hand")

        await entered.wait()
        await release.open()
        await cache.settle()
        let next = try await cache.value { _ in .unchanged }
        XCTAssertEqual(next, "today")
    }

    // MARK: What a background check found

    func testANewDatabaseIsAnnounced() async throws {
        let clock = TestClock()
        let cache = Freshened<String>(now: { clock.now })
        var announcements = await cache.changes().makeAsyncIterator()

        _ = try await cache.value { _ in .fresh("old", validator: "etag-1") }
        clock.advance(day + 1)
        _ = try await cache.value { _ in .fresh("new", validator: "etag-2") }
        await cache.settle()

        let announced = await announcements.next()
        XCTAssertEqual(announced, "new", "the work done against the old one can be done again")
    }

    func testTheFirstFetchIsNotAnnounced() async throws {
        let clock = TestClock()
        let cache = Freshened<String>(now: { clock.now })
        var announcements = await cache.changes().makeAsyncIterator()

        // The first fetch is the return of `value(_:)`. Announcing it as well
        // would have the consumer do its work twice for one database.
        _ = try await cache.value { _ in .fresh("database", validator: "etag-1") }
        clock.advance(day + 1)
        _ = try await cache.value { _ in .unchanged }
        await cache.settle()

        let finished = Task { await announcements.next() }
        try await Task.sleep(nanoseconds: 20_000_000)
        finished.cancel()
        let announced = await finished.value
        XCTAssertNil(announced, "one fetch, one piece of work")
    }

    // MARK: A check that could not be made

    func testAFailedCheckKeepsWhatIsHeld() async throws {
        struct Offline: Error {}
        let clock = TestClock()
        let cache = Freshened<String>(now: { clock.now })

        _ = try await cache.value { _ in .fresh("yesterday", validator: "etag-1") }
        clock.advance(day + 1)

        let value = try await cache.value { _ in throw Offline() }
        XCTAssertEqual(value, "yesterday", "a database from yesterday is what the tool is for")
        await cache.settle()
    }

    func testAFailedCheckIsNotRepeatedUntilTheRetryIntervalHasPassed() async throws {
        struct Offline: Error {}
        let clock = TestClock()
        let cache = Freshened<String>(retryInterval: 5 * 60, now: { clock.now })
        let checks = Checks()

        _ = try await cache.value { _ in .fresh("yesterday", validator: "etag-1") }
        clock.advance(day + 1)
        _ = try await cache.value { _ in throw Offline() }
        await cache.settle()

        // Every file opened in the next five minutes would otherwise wait out
        // a connection timeout of its own.
        clock.advance(60)
        _ = try await cache.value { validator in
            await checks.record(validator)
            return .unchanged
        }
        await cache.settle()
        var count = await checks.count
        XCTAssertEqual(count, 0)

        clock.advance(5 * 60)
        _ = try await cache.value { validator in
            await checks.record(validator)
            return .unchanged
        }
        await cache.settle()
        count = await checks.count
        XCTAssertEqual(count, 1)
    }

    func testASuccessfulCheckClearsTheFailure() async throws {
        struct Offline: Error {}
        let clock = TestClock()
        let cache = Freshened<String>(retryInterval: 5 * 60, now: { clock.now })

        _ = try await cache.value { _ in .fresh("old", validator: "etag-1") }
        clock.advance(day + 1)
        _ = try await cache.value { _ in throw Offline() }
        await cache.settle()
        clock.advance(5 * 60 + 1)
        _ = try await cache.value { _ in .fresh("new", validator: "etag-2") }
        await cache.settle()

        // Back on the ordinary schedule: a day from the fetch, not five
        // minutes from the failure.
        clock.advance(60 * 60)
        let value = try await cache.value { _ in
            XCTFail("fetched an hour ago; nothing to ask")
            return .unchanged
        }
        XCTAssertEqual(value, "new")
    }

    // MARK: Two callers

    func testASecondCallerDuringTheFetchDoesNotStartASecondOne() async throws {
        let cache = Freshened<String>()
        let checks = Checks()
        let entered = Gate()
        let release = Gate()

        async let first = cache.value { validator in
            await checks.record(validator)
            await entered.open()
            await release.wait()
            return .fresh("database", validator: "etag-1")
        }

        await entered.wait()
        async let second = cache.value { validator in
            await checks.record(validator)
            return .fresh("a second download", validator: "etag-2")
        }
        await release.open()

        let values = try await [first, second]
        XCTAssertEqual(values, ["database", "database"])
        let count = await checks.count
        XCTAssertEqual(count, 1, "one fetch answers both panes")
    }

    // MARK: Refresh, and the date shown

    func testMarkStaleForcesACheckAndKeepsTheValueWhenItFails() async throws {
        struct Offline: Error {}
        let clock = TestClock()
        let cache = Freshened<String>(now: { clock.now })

        _ = try await cache.value { _ in .fresh("database", validator: "etag-1") }
        await cache.markStale()

        let value = try await cache.value { _ in throw Offline() }
        XCTAssertEqual(value, "database", "Refresh on a bench with no network must not empty the panel")
        await cache.settle()
    }

    func testStatusReportsWhenTheBodyChangedNotWhenItWasChecked() async throws {
        let clock = TestClock()
        let start = clock.now
        let cache = Freshened<String>(now: { clock.now })

        _ = try await cache.value { _ in .fresh("database", validator: "etag-1") }
        clock.advance(day + 1)
        _ = try await cache.value { _ in .unchanged }
        await cache.settle()

        let status = await cache.status
        XCTAssertEqual(status?.changedAt, start, "a 304 today does not make last week's database fresher")
        XCTAssertEqual(status?.checkedAt, clock.now)
    }
}
