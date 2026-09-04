import Foundation
import DumpCompareCore

/// What the Find bar says about the current search: the count, the position in
/// it, and the one thing worth warning about (§11,
/// `Design/FIND_HIGHLIGHT_PLAN.md`).
///
/// A value, not a view: the states are the interesting part — a count in the
/// thousands is the app telling the user their pattern is too generic — so they
/// are decided here and asserted without a window.
struct FindCount: Equatable {
    /// Exact at any size. `> 1000` is not a diagnosis: 1001 and 3 000 000 call
    /// for different actions from the user.
    let total: Int
    /// 1-based position of the find indicator, or nil when the caret is not on
    /// a match — the state between activating a search and the first step.
    let ordinal: Int?
    /// Whether the results panel will list these matches (§11's limit).
    let isListable: Bool
    /// Whether the dump and the map can grey them.
    let isHighlightable: Bool

    /// The bar's reading of a pane's session, or nil when there is nothing it
    /// can say yet — no session, or one whose index is still being built.
    ///
    /// A count out of a half-built index would climb while the user read it,
    /// and "3 of 4 812" would mean "of 4 812 so far". The bar is where the
    /// app's diagnosis of a pattern goes, so it waits for the whole file; what
    /// says the work is still running is the status bar's own operation, which
    /// carries its progress (§11, §14.4).
    static func reading(of set: MatchSet?, current: Int?) -> FindCount? {
        guard let set, set.isComplete else { return nil }
        return FindCount(total: set.total,
                         ordinal: current.map { $0 + 1 },
                         isListable: set.isListable,
                         isHighlightable: set.isHighlightable)
    }

    var hasMatches: Bool { total > 0 }

    /// What the label shows. Grouped digits, because a six-figure count is a
    /// number the user has to read, not just notice.
    var text: String {
        guard total > 0 else { return "Not found" }
        let count = Self.grouped(total)
        guard let ordinal else { return count }
        return "\(Self.grouped(ordinal)) of \(count)"
    }

    /// The sentence beside the count when something is being withheld, as the
    /// glyph's tooltip. Nil when nothing is.
    ///
    /// Highlighting outranks listing: when both are withheld the picture is the
    /// bigger loss, and only one sentence fits beside a count.
    var warning: String? {
        guard total > 0 else { return nil }
        if !isHighlightable {
            return "Too many matches to highlight — navigation and the map still cover all of them."
        }
        if !isListable {
            return "Too many matches to list. Refine the pattern."
        }
        return nil
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func grouped(_ value: Int) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
