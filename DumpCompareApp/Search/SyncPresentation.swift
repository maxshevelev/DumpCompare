import Foundation
import DumpCompareCore

/// How a synced item reads in a question put to the user (`SyncedCollection`).
///
/// Naming is the view's business, which is why it lives here and not beside the
/// model — the same reason `SearchEncoding.displayName` does
/// (`SearchEncodingNaming`). The merge in `DumpCompareCore` decides *what* the
/// question is; this decides how it reads.
protocol SyncPresentable {
    /// What names the item in a question: short, and enough to tell which row
    /// is meant.
    var label: String { get }
    /// What one side of a disagreement holds, in full — a label alone is not
    /// enough where the two sides differ in something the label leaves out.
    var summary: String { get }
}

extension SearchPatternEntry: SyncPresentable {
    /// Its name, or the pattern itself where it has none.
    var label: String { name.isEmpty ? pattern : name }

    /// The name *and* the pattern.
    ///
    /// A name alone is not enough: the two sides often disagree about the
    /// pattern under the same name, and a row reading "Test for ASCII" against
    /// "Test for ASCII" asks the user to choose between two identical things.
    var summary: String {
        let named = name.isEmpty ? "" : "\(name): "
        return "\(named)\"\(pattern)\"  \(encoding.displayName)"
    }
}
