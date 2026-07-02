//
//  ProgressGeometry.swift
//  Replicould — UI
//
//  The pure math behind the operation/travel progress bars: elapsed fraction and
//  ETA text, plus the segmented travel bar's leg layout. Deliberately SwiftUI-free
//  and kept *off* the `View` types — referencing a symbol nested in a SwiftUI
//  `View` forces realization of that view's runtime metadata, which traps in a
//  headless test process, so hosting this math here keeps it unit-testable.
//

import Foundation

/// Elapsed-fraction and ETA math shared by the progress bars.
enum ProgressMath {
    /// Elapsed fraction in `0...1`, clamped. A non-positive span reads as done.
    static func fraction(now: Date, start: Date, end: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    /// Compact ETA string, e.g. "ETA 1m 23s", or "Arriving…" once due.
    static func etaText(now: Date, end: Date) -> String {
        let remaining = Int(end.timeIntervalSince(now).rounded())
        guard remaining > 0 else { return "Arriving…" }
        let minutes = remaining / 60
        let seconds = remaining % 60
        return minutes > 0 ? "ETA \(minutes)m \(seconds)s" : "ETA \(seconds)s"
    }

    /// Where we are within the *current* repeating cycle, in `0...1`. Unlike a
    /// one-shot operation, mining loops: the bar fills over each `cycle` seconds
    /// then wraps. Anchored on the operation's start so every cycle boundary lands
    /// on the same phase the server ticks at.
    static func cycleFraction(now: Date, start: Date, cycle: Double) -> Double {
        guard cycle > 0 else { return 0 }
        return intoCycle(now: now, start: start, cycle: cycle) / cycle
    }

    /// Seconds left in the current cycle, as "next cycle 12s".
    static func cycleText(now: Date, start: Date, cycle: Double) -> String {
        guard cycle > 0 else { return "" }
        let remaining = Int((cycle - intoCycle(now: now, start: start, cycle: cycle)).rounded())
        return "next cycle \(max(0, remaining))s"
    }

    /// Elapsed time into the current cycle, in `0..<cycle`. Positive even when
    /// `now` precedes `start` (clock skew), so the fraction never goes negative.
    private static func intoCycle(now: Date, start: Date, cycle: Double) -> Double {
        let elapsed = now.timeIntervalSince(start)
        let wrapped = elapsed.truncatingRemainder(dividingBy: cycle)
        return wrapped < 0 ? wrapped + cycle : wrapped
    }
}

/// The segmented travel bar's leg layout — pure geometry over the route.
public enum TravelBar {
    /// One leg of the route. `weight` is the leg's relative duration; a zero or
    /// missing weight falls back to an equal share so the bar still renders.
    public struct Segment: Identifiable, Equatable, Sendable {
        public let id: Int
        public let weight: Double
        public let type: String?
        public let from: String?
        public let to: String?

        public init(id: Int, weight: Double, type: String? = nil, from: String? = nil, to: String? = nil) {
            self.id = id
            self.weight = max(weight, 0)
            self.type = type
            self.from = from
            self.to = to
        }
    }

    /// A segment placed on the normalized 0...1 route axis.
    struct Band: Identifiable, Equatable {
        let id: Int
        let segment: Segment
        let start: Double
        let end: Double

        /// The filled fraction (0...1) of this band at the given overall progress.
        func fill(at progress: Double) -> Double {
            let span = Swift.max(end - start, 0.0001)
            return Swift.min(Swift.max((progress - start) / span, 0), 1)
        }
    }

    /// Lay the segments out along the normalized 0...1 route axis, each taking a
    /// share proportional to its weight. A zero/negative weight falls back to an
    /// equal share so a leg without a duration still renders.
    static func bands(for segments: [Segment]) -> [Band] {
        let total = segments.reduce(0.0) { $0 + ($1.weight > 0 ? $1.weight : 1) }
        let denominator = total > 0 ? total : 1
        var cursor = 0.0
        return segments.map { segment in
            let share = (segment.weight > 0 ? segment.weight : 1) / denominator
            let start = cursor
            cursor += share
            return Band(id: segment.id, segment: segment, start: start, end: Swift.min(cursor, 1))
        }
    }

    /// A caption for the leg currently under way — its mode and endpoints. The
    /// active leg is the first not yet passed, or the last once the route is done.
    static func activeCaption(_ bands: [Band], progress: Double) -> String? {
        guard let band = bands.first(where: { progress < $0.end }) ?? bands.last else { return nil }
        let segment = band.segment
        var parts: [String] = []
        if let type = segment.type { parts.append(type.capitalized) }
        if let from = segment.from, let to = segment.to {
            parts.append("\(from) → \(to)")
        } else if let to = segment.to {
            parts.append(to)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
