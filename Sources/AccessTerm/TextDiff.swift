import Foundation

/// The smallest edit that turns one text into another, so a view showing the old text can be
/// patched instead of replaced: a replacement throws away the selection and whatever
/// VoiceOver was holding, an edit confined to what changed leaves the rest alone.
enum TextDiff {
    /// The range of `old` (in UTF-16 units, as NSTextStorage counts) to replace, and what to
    /// replace it with. Nil when the two are identical. A shared prefix and suffix are kept,
    /// never cut through a surrogate pair.
    static func minimalEdit(from old: String, to new: String) -> (range: NSRange, replacement: String)? {
        if old == new { return nil }
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        // Not between the halves of a surrogate pair.
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return (NSRange(location: prefix, length: a.count - prefix - suffix), replacement)
    }
}
