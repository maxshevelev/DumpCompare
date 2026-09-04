import Foundation
import DumpCompareCore

/// What the app *calls* an encoding: the Find bar's popup item, the label on a
/// history entry, a line of Smart Search's notice (§11).
///
/// One list, because the three must agree — a notice saying `UTF-16 LE — no
/// results` is about the item the popup calls `UTF-16 LE`. Naming is the view's
/// business, which is why it lives here and not beside the model's own
/// `SearchEncoding`.
extension SearchEncoding {
    var displayName: String {
        switch self {
        case .hex: return "Hex bytes"
        case .ascii: return "ASCII"
        case .utf8: return "UTF-8"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        }
    }
}

extension SmartSearch.Attempt {
    /// How an attempt is named when it has to be reported — every encoding it
    /// answered for, so "no results" is honest about what was tried.
    var label: String {
        encodings.map(\.displayName).joined(separator: ", ")
    }
}
