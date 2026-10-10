import Foundation

/// Locates quoted text inside paragraph text and computes word-level differences.
/// All offsets are unicode-scalar offsets, matching `ParagraphModel.text`.
enum TextMatching {
    /// One-for-one character folding, so a match in folded text maps straight back to the
    /// original offsets. Covers the usual mismatches between Word's typography and a model's quote.
    static func fold(_ s: Unicode.Scalar) -> Unicode.Scalar {
        switch s.value {
        case 0x2018, 0x2019, 0x201A, 0x201B, 0x2032: return "'"
        case 0x201C, 0x201D, 0x201E, 0x201F, 0x2033: return "\""
        case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212: return "-"
        case 0x00A0, 0x2007, 0x202F, 0x2009, 0x200A: return " "
        case 0x2026: return "…"
        default: return s
        }
    }

    static func folded(_ a: [Unicode.Scalar]) -> [Unicode.Scalar] { a.map(fold) }

    static func occurrences(of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar]) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var hits: [Int] = []
        var i = 0
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0] && Array(haystack[i..<(i + needle.count)]) == needle {
                hits.append(i)
            }
            i += 1
        }
        return hits
    }

    enum MatchResult: Equatable {
        case found(Range<Int>)
        case notFound
        case ambiguous(Int)
    }

    /// Exact match first, then a typography-insensitive match.
    static func locate(_ quote: String, in text: [Unicode.Scalar]) -> MatchResult {
        let needle = Array(quote.unicodeScalars)
        guard !needle.isEmpty else { return .notFound }
        var hits = occurrences(of: needle, in: text)
        if hits.isEmpty { hits = occurrences(of: folded(needle), in: folded(text)) }
        switch hits.count {
        case 0: return .notFound
        case 1: return .found(hits[0]..<(hits[0] + needle.count))
        default: return .ambiguous(hits.count)
        }
    }

    // MARK: - Word diff

    struct Hunk: Equatable {
        /// Range to delete, relative to the start of the compared original text.
        var deleted: Range<Int>
        var inserted: String
    }

    static func tokenize(_ s: [Unicode.Scalar]) -> [Range<Int>] {
        var tokens: [Range<Int>] = []
        var i = 0
        func isWord(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic || CharacterSet.decimalDigits.contains(c) }
        while i < s.count {
            var j = i + 1
            if isWord(s[i]) {
                while j < s.count && isWord(s[j]) { j += 1 }
            } else if s[i] == " " {
                while j < s.count && s[j] == " " { j += 1 }
            }
            tokens.append(i..<j)
            i = j
        }
        return tokens
    }

    /// Word-level difference between `original` (document text) and `revised`.
    /// Short unchanged islands between changes are absorbed so the redline reads the way a
    /// person would mark it up, rather than as a scatter of one-word edits.
    static func diff(original: [Unicode.Scalar], revised: [Unicode.Scalar]) -> [Hunk] {
        let a = tokenize(original), b = tokenize(revised)
        let fa = a.map { folded(Array(original[$0])) }, fb = b.map { folded(Array(revised[$0])) }

        // Longest common subsequence over tokens.
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = fa[i] == fb[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        // Walk the table into aligned (aIndex?, bIndex?) pairs.
        enum Step { case same(Int, Int), del(Int), ins(Int) }
        var steps: [Step] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n && j < m && fa[i] == fb[j] { steps.append(.same(i, j)); i += 1; j += 1 }
            else if j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j]) { steps.append(.ins(j)); j += 1 }
            else { steps.append(.del(i)); i += 1 }
        }

        // Group into hunks: maximal runs of non-equal steps.
        struct Raw { var aStart: Int; var aEnd: Int; var bStart: Int; var bEnd: Int }
        var raws: [Raw] = []
        var aPos = 0, bPos = 0
        var current: Raw?
        for step in steps {
            switch step {
            case .same:
                if let c = current { raws.append(c); current = nil }
                aPos += 1; bPos += 1
            case .del:
                if current == nil { current = Raw(aStart: aPos, aEnd: aPos, bStart: bPos, bEnd: bPos) }
                aPos += 1; current!.aEnd = aPos
            case .ins:
                if current == nil { current = Raw(aStart: aPos, aEnd: aPos, bStart: bPos, bEnd: bPos) }
                bPos += 1; current!.bEnd = bPos
            }
        }
        if let c = current { raws.append(c) }
        guard !raws.isEmpty else { return [] }

        // Merge hunks separated by at most one word (plus its spacing) of unchanged text.
        var merged: [Raw] = [raws[0]]
        for r in raws.dropFirst() {
            let gap = merged[merged.count - 1].aEnd..<r.aStart
            let words = gap.filter { idx in original[a[idx]].contains { $0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0) } }
            if words.count <= 1 {
                merged[merged.count - 1].aEnd = r.aEnd
                merged[merged.count - 1].bEnd = r.bEnd
            } else {
                merged.append(r)
            }
        }

        // When most of the passage changed, show it as one clean replacement.
        let changedTokens = merged.reduce(0) { $0 + ($1.aEnd - $1.aStart) }
        if merged.count > 1 && Double(changedTokens) > 0.6 * Double(max(n, 1)) {
            merged = [Raw(aStart: merged.first!.aStart, aEnd: merged.last!.aEnd,
                          bStart: merged.first!.bStart, bEnd: merged.last!.bEnd)]
        }

        func aOffset(_ t: Int) -> Int { t < n ? a[t].lowerBound : original.count }
        func bOffset(_ t: Int) -> Int { t < m ? b[t].lowerBound : revised.count }
        return merged.map { r in
            let ins = revised[bOffset(r.bStart)..<bOffset(r.bEnd)]
            return Hunk(deleted: aOffset(r.aStart)..<aOffset(r.aEnd), inserted: String(String.UnicodeScalarView(ins)))
        }
    }
}
