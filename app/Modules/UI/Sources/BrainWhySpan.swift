//
//  BrainWhySpan.swift
//  UI
//
//  Honours the house monospace rule for a designation EMBEDDED in a sentence
//  rather than standing alone in its own label — the why-view's `Goal.rationale`
//  ("meshing VEGA — 3,200 units at POLARISUM, 2 hops") and a theatre-site
//  candidate's reasons both need it. Most surfaces satisfy the rule trivially,
//  the designation being its own `Text`; this splits a sentence into runs so
//  the mid-sentence case can render mono too.
//
//  **Matched against codes we were TOLD, never against a shape.** The split
//  takes an explicit set of designations — never a heuristic sniffing for "an
//  all-caps looking token", which would also catch `DirectiveAttentionReason
//  .awaitingRelayRestock`'s "Out of FTL relays" ("FTL" is not a system) and a
//  carrier device code inside a deferral reason (also not one).
//

import SwiftUI

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

    /// The line as one `Text`, with designations in the prominence-matched
    /// mono token.
    ///
    /// Built as a single `AttributedString` with a per-run `font` attribute
    /// rather than by concatenating `Text` values (`Text + Text` is
    /// deprecated on macOS 26). One `Text` also means the line wraps as one
    /// paragraph, which is what makes the monospace rule satisfiable for a
    /// designation embedded mid-sentence at all.
    public func styled(prose: Font, designation: Font) -> Text {
        var line = AttributedString()
        for span in self {
            var run = AttributedString(span.text)
            run.font = span.isDesignation ? designation : prose
            line += run
        }
        return Text(line)
    }
}
