import Foundation

/// Puts a new dictation into a note being composed.
nonisolated enum DraftText {
    /// Inserts `dictated` at `range` (UTF-16 offsets, replacing any selected text), or at
    /// the end when there is no cursor yet. Adds a space on either side only where the
    /// neighbouring text needs one. Returns the new text and the cursor after the insert.
    static func insert(
        _ dictated: String, into text: String, replacing range: Range<Int>? = nil
    ) -> (text: String, cursor: Int) {
        let ns = text as NSString
        let lower = min(max(range?.lowerBound ?? ns.length, 0), ns.length)
        let upper = min(max(range?.upperBound ?? ns.length, lower), ns.length)
        let insertion = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !insertion.isEmpty else { return (text, upper) }

        let before = ns.substring(to: lower)
        let after = ns.substring(from: upper)
        var piece = insertion
        if let last = before.last, !last.isWhitespace { piece = " " + piece }
        if let first = after.first, !first.isWhitespace, !first.isPunctuation { piece += " " }
        let head = before + piece
        return (head + after, (head as NSString).length)
    }
}
