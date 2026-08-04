//
//  BrainWhySpan.swift
//  Replicould — Directives feature
//
//  How the why-view honours the house monospace rule for designations that
//  are EMBEDDED in a sentence rather than standing alone in their own label.
//
//  The rule (`app/CLAUDE.md`, `monospace-system-names`) is that a system or
//  location designation is a CODE and always renders in a mono token. Most
//  surfaces satisfy that trivially — the designation is its own `Text`. The
//  brain's gate line is not: `Goal.rationale` is a whole sentence with the
//  codes inside it ("meshing VEGA — 3,200 units at POLARISUM, 2 hops"), and
//  Task 5's review flagged that rendering the lot in `.rcCaption` breaks the
//  rule. So the projection SPLITS the sentence into runs, and the view
//  concatenates them with the prominence-matched mono token
//  (`.rcCaption`/`.rcMonoSmall`, `.rcBodyEmph`/`.rcBodyEmphMono`).
//
//  **Matched against codes we were TOLD, never against a shape.** The split
//  takes an explicit set of designations — the ones `BrainReport` carries
//  (every ranked candidate's hop and served targets, the goal's target, the
//  hub) — rather than sniffing for "an all-caps looking token". A shape rule
//  is tempting and wrong: `DirectiveAttentionReason.awaitingRelayRestock`
//  displays as "Out of FTL relays", and "FTL" would be monospaced as though
//  it were a star system. A carrier device code inside a deferral reason
//  ("deferred — carrier HV001234 unavailable on confirm") stays prose for the
//  same reason in reverse: it is not a system or location name, which is what
//  the rule is about, and the report does not carry it.
//

/// One run of gate or row text, tagged with whether it is a designation.
public enum BrainWhySpan: Equatable, Sendable {
    /// Ordinary prose — renders in the surrounding text token.
    case prose(String)
    /// A system or location designation — renders in the prominence-matched
    /// mono token.
    case designation(String)

    /// The run's characters, untagged.
    public var text: String {
        switch self {
        case let .prose(text), let .designation(text): text
        }
    }

    /// Whether this run must render monospaced.
    public var isDesignation: Bool {
        if case .designation = self { return true }
        return false
    }
}

extension [BrainWhySpan] {
    /// The whole line as plain text — what an operator would read aloud, and
    /// what an accessibility label wants.
    public var text: String { map(\.text).joined() }

    /// Splits `sentence` into prose and designation runs, recognising only
    /// the members of `designations`.
    ///
    /// Longest match first, so `SOL-3` is never split into `SOL` + `-3` when
    /// both are known codes. A match must also stand on a code boundary — the
    /// characters either side may not be alphanumerics or a hyphen — so a
    /// known `SOL` inside `SOLARIS` (or inside the tail of `SOL-3`) is left
    /// as prose rather than monospacing half a word.
    ///
    /// Adjacent runs of the same kind are never produced: prose accumulates
    /// until a designation interrupts it, which keeps the output stable
    /// enough to assert on.
    public static func spans(in sentence: String, designations: Set<String>) -> [BrainWhySpan] {
        // Longest first so a prefix code can't win over the longer code that
        // contains it; the length tie-break on the code itself only exists to
        // make the ordering total (and so the output deterministic).
        let codes = designations
            .filter { !$0.isEmpty }
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        guard !codes.isEmpty else { return sentence.isEmpty ? [] : [.prose(sentence)] }

        var spans: [BrainWhySpan] = []
        var prose = ""
        var index = sentence.startIndex

        while index < sentence.endIndex {
            let matched = codes.first { code in
                sentence[index...].hasPrefix(code)
                    && Self.isBoundary(sentence, at: index, length: code.count)
            }
            guard let matched else {
                prose.append(sentence[index])
                index = sentence.index(after: index)
                continue
            }
            if !prose.isEmpty {
                spans.append(.prose(prose))
                prose = ""
            }
            spans.append(.designation(matched))
            index = sentence.index(index, offsetBy: matched.count)
        }
        if !prose.isEmpty { spans.append(.prose(prose)) }
        return spans
    }

    /// Whether a match of `length` characters starting at `start` is bounded
    /// by non-code characters on both sides.
    private static func isBoundary(_ sentence: String, at start: String.Index, length: Int) -> Bool {
        let isCodeCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "-" }
        if start > sentence.startIndex {
            let before = sentence[sentence.index(before: start)]
            if isCodeCharacter(before) { return false }
        }
        let end = sentence.index(start, offsetBy: length)
        if end < sentence.endIndex, isCodeCharacter(sentence[end]) { return false }
        return true
    }
}
