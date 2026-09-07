import Foundation

/// Maps rendered selection text onto accessibility leaves. Whitespace can differ
/// between the browser's selection string and its AX tree; all other UTF-16 code
/// units must match exactly. Ambiguous matches are rejected, never guessed.
enum SourceTextMapper {
    struct Span: Equatable {
        let sourceStart: Int
        let sourceLength: Int
        let leaf: Int
        let leafOffset: Int
        let leafLength: Int
    }

    private struct Unit {
        let value: UInt16
        let offset: Int
        let leaf: Int
    }

    private static func units(_ text: String, leaf: Int = 0) -> [Unit] {
        var result: [Unit] = []
        var offset = 0
        for scalar in text.unicodeScalars {
            let encoded = Array(String(scalar).utf16)
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                for (index, value) in encoded.enumerated() {
                    result.append(Unit(value: value, offset: offset + index, leaf: leaf))
                }
            }
            offset += encoded.count
        }
        return result
    }

    static func map(selection: String, leaves: [String], preferredLeaf: Int? = nil, preferredOffset: Int? = nil) -> [Span] {
        let needle = units(selection)
        guard !needle.isEmpty else { return [] }
        let haystack = leaves.enumerated().flatMap { units($0.element, leaf: $0.offset) }
        guard haystack.count >= needle.count else { return [] }
        // KMP keeps long articles and repetitive text linear in input size.
        var prefix = [Int](repeating: 0, count: needle.count)
        var length = 0
        for index in 1..<needle.count {
            while length > 0 && needle[index].value != needle[length].value { length = prefix[length - 1] }
            if needle[index].value == needle[length].value { length += 1 }
            prefix[index] = length
        }
        var matches: [Int] = []
        length = 0
        for (index, unit) in haystack.enumerated() {
            while length > 0 && unit.value != needle[length].value { length = prefix[length - 1] }
            if unit.value == needle[length].value { length += 1 }
            if length == needle.count {
                let start = index + 1 - needle.count
                let anchor = haystack[start]
                if (preferredLeaf == nil || anchor.leaf == preferredLeaf) &&
                    (preferredOffset == nil || anchor.offset == preferredOffset! + needle[0].offset) {
                    matches.append(start)
                    if matches.count > 1 { return [] }
                }
                length = prefix[length - 1]
            }
        }
        guard let match = matches.first else { return [] }
        var result: [Span] = []
        var start = 0
        while start < needle.count {
            var end = start + 1
            // Preserve a linear mapping within each run. If rendered whitespace
            // differs, split the run so subsequent character offsets stay exact.
            while end < needle.count,
                  haystack[match + end].leaf == haystack[match + start].leaf,
                  haystack[match + end].offset - haystack[match + start].offset == needle[end].offset - needle[start].offset {
                end += 1
            }
            let count = needle[end - 1].offset + 1 - needle[start].offset
            result.append(Span(sourceStart: needle[start].offset, sourceLength: count,
                               leaf: haystack[match + start].leaf, leafOffset: haystack[match + start].offset,
                               leafLength: haystack[match + end - 1].offset + 1 - haystack[match + start].offset))
            start = end
        }
        return result
    }
}
