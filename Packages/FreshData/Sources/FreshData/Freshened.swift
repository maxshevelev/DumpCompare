import Foundation

/// A value that is fetched once and then re-checked once a day.
///
/// It holds the *parsed* value rather than the bytes it came from, because the
/// parse is as much of the cost as the download for a 680 KB CSV, and because
/// what every caller wants back is the model.
///
/// It knows nothing about HTTP. `value(_:)` is handed a closure that receives
/// whatever validator was stored with the held value — an `ETag`, a
/// `Last-Modified`, anything the source can echo back — and answers either
/// "unchanged" or "here is a new one". That keeps the network in the
/// repository, and it means the rules below can be tested without a network and
/// without the wall clock.
///
/// The rules, which are the reason this is a type rather than three fields:
///
/// - **Nothing held.** Fetch. If the fetch fails, the error is thrown and
///   **nothing is remembered** — a remembered failure outlives the network that
///   caused it, and a bench that opened a tool while offline would go on seeing
///   the same error after plugging the cable back in.
/// - **Held and younger than `ttl`.** The closure is not called at all. This is
///   the case that matters: the second, third and fourth file opened in a run.
/// - **Held and older than `ttl`.** Check. `unchanged` keeps the value and
///   restarts the clock — no bytes, no re-parse. A new value replaces it.
/// - **A check that could not be made.** The held value is returned and no
///   error is raised: a database from yesterday is what the tool is for. The
///   failure is remembered for `retryInterval` only, so a day without a network
///   does not put a fetch timeout in front of every file opened.
/// - **Two callers at once.** One call to the closure.
public actor Freshened<Value: Sendable> {
    /// What a check found.
    public enum Outcome: Sendable {
        /// The source says what we hold is still current — an HTTP `304`.
        case unchanged
        /// A new value, with the validator to present at the next check.
        case fresh(Value, validator: String?)
    }

    public enum Failure: Error, Equatable {
        /// The closure answered `.unchanged` when nothing was held, which it
        /// cannot know: with nothing held it is passed a `nil` validator and
        /// has nothing to compare against.
        case unchangedWithNothingHeld
    }

    /// What the tool panel's header needs to say how old the data is.
    public struct Status: Sendable, Equatable {
        /// When the body last actually changed. This is the date to show: a
        /// check that answered `304` today does not make last week's database
        /// any fresher.
        public let changedAt: Date
        /// When it was last confirmed current.
        public let checkedAt: Date
    }

    private struct Held {
        var value: Value
        var validator: String?
        var changedAt: Date
        var checkedAt: Date
    }

    private let ttl: TimeInterval
    private let retryInterval: TimeInterval
    private let now: @Sendable () -> Date

    private var held: Held?
    private var checkFailedAt: Date?
    private var inFlight: Task<Value, Error>?

    /// - Parameters:
    ///   - ttl: how long a value is used without asking the source. A day, for
    ///     databases that change about weekly.
    ///   - retryInterval: how long a failed check suppresses the next one.
    ///   - now: the clock, so the tests do not have one.
    public init(
        ttl: TimeInterval = 24 * 60 * 60,
        retryInterval: TimeInterval = 5 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ttl = ttl
        self.retryInterval = retryInterval
        self.now = now
    }

    /// The held value, or the result of a fetch or a check, by the rules above.
    public func value(
        _ check: @escaping @Sendable (_ validator: String?) async throws -> Outcome
    ) async throws -> Value {
        if let held, !isDue(held) { return held.value }
        if let inFlight { return try await inFlight.value }

        let task = Task { try await self.run(check) }
        inFlight = task
        do {
            let value = try await task.value
            inFlight = nil
            return value
        } catch {
            inFlight = nil
            throw error
        }
    }

    /// What is held and how old it is, or `nil` if nothing has been fetched.
    public var status: Status? {
        held.map { Status(changedAt: $0.changedAt, checkedAt: $0.checkedAt) }
    }

    /// Make the next `value(_:)` check, whatever the clock says — the Refresh
    /// command. It does not throw the value away: a Refresh on a bench with no
    /// network must not be the gesture that empties the panel.
    public func markStale() {
        held?.checkedAt = .distantPast
        checkFailedAt = nil
    }

    private func isDue(_ held: Held) -> Bool {
        let t = now()
        if t.timeIntervalSince(held.checkedAt) < ttl { return false }
        if let checkFailedAt, t.timeIntervalSince(checkFailedAt) < retryInterval { return false }
        return true
    }

    private func run(
        _ check: @Sendable (_ validator: String?) async throws -> Outcome
    ) async throws -> Value {
        let outcome: Outcome
        do {
            outcome = try await check(held?.validator)
        } catch {
            guard let held else { throw error }
            checkFailedAt = now()
            return held.value
        }

        let t = now()
        checkFailedAt = nil
        switch outcome {
        case .unchanged:
            guard var held else { throw Failure.unchangedWithNothingHeld }
            held.checkedAt = t
            self.held = held
            return held.value
        case .fresh(let value, let validator):
            held = Held(value: value, validator: validator, changedAt: t, checkedAt: t)
            return value
        }
    }
}
