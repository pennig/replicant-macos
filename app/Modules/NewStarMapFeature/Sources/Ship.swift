import Foundation
import simd

// A ship in transit — state-tier data. Travel is a multi-leg, location→location route
// (HANDOFF §1: a direct point-to-point trajectory, not constrained to the mesh). At
// galaxy scale every leg endpoint resolves to its SYSTEM's star, so an intra-system
// cruise leg collapses to a point (the ship parks at the star) and a surge/jump leg
// spans two stars — the ship therefore parks, then moves, then parks across a trip like
// `AINALRAM-BELT-1 → … → SOL-3-1`. Position is a pure function of time, so it's
// deterministic and testable; the renderer feeds it the clock each frame.
//
// The trip window is expressed in the renderer's monotonic media-time domain (the same
// `CACurrentMediaTime()` clock `draw` runs on). The renderer converts the real
// wall-clock timestamps into this domain once, when built, so per-frame progress is a
// cheap linear map with no date arithmetic.

struct Ship {
    /// The device in transit — the identity the tappable overlay icon carries.
    let deviceCode: String
    /// The device's type, resolving the icon's `device.<type>` glyph. Defaults to
    /// empty for callers that don't draw icons (tests).
    var deviceType: String = ""
    /// Overall endpoint systems (indices into the star array). Both are state-clamped so
    /// they never dim; they anchor the drawn ribbon.
    let fromStar: Int
    let toStar: Int
    /// Overall trip window in media-time seconds (drives the ribbon's dash cadence and
    /// the straight-line fallback when there are no resolved legs).
    let departedMedia: Double
    let arrivesMedia: Double
    /// The real wall-clock final-arrival time, carried straight from the route so the
    /// transit callout can show a live "arrives in …" countdown (media-time is monotonic,
    /// not a date). Defaults to `.distantFuture` for callers that don't need it (tests).
    var arrivesAt: Date = .distantFuture
    /// The real wall-clock departure, carried straight from the route. A transit
    /// callout whose anchor is the route's ORIGIN counts down to this (the ship
    /// leaves the view the instant the first leg starts). Defaults to
    /// `.distantPast` for callers that don't need it (tests).
    var departedAt: Date = .distantPast
    /// The route's legs, each resolved to its endpoint SYSTEM stars + its media-time
    /// window. Empty ⇒ a single straight `fromStar`→`toStar` segment over the window.
    let legs: [Leg]

    /// One leg: its endpoint SYSTEM stars (galaxy placement) AND its full LOCATION codes
    /// (in-orrery placement, resolved against the focused system's `OrreryLayout`), plus
    /// its media-time window.
    struct Leg: Equatable {
        let fromStar: Int
        let toStar: Int
        let fromCode: String
        let toCode: String
        let startMedia: Double
        let endMedia: Double
        /// This leg's real wall-clock end. The media-time window drives per-frame
        /// placement; this drives the callout's live countdown, which needs a date.
        /// Defaults for callers that only exercise placement (tests).
        var endsAt: Date = .distantFuture
    }

    /// The distinct SYSTEM stars the route passes through, in order — the galaxy ribbon's
    /// polyline (so a 3+-system trip's drawn line bends through the intermediate systems
    /// instead of cutting straight origin→dest). Consecutive duplicates (cruise legs, which
    /// hold at a system) collapse out. Falls back to the overall endpoints with no legs.
    var nodeStars: [Int] {
        guard !legs.isEmpty else { return [fromStar, toStar] }
        var seq: [Int] = [legs[0].fromStar]
        for leg in legs {
            if leg.fromStar != seq.last { seq.append(leg.fromStar) }
            if leg.toStar != seq.last { seq.append(leg.toStar) }
        }
        return seq
    }

    /// The route's location codes in order (origin → each leg's destination), the input to
    /// `SystemTransit` for the inbound/outbound affordance. Empty with no legs.
    var orderedCodes: [String] {
        guard let first = legs.first else { return [] }
        return [first.fromCode] + legs.map(\.toCode)
    }

    /// Overall progress 0…1 across the whole trip window (clamped) — the straight-line
    /// fallback's parameter.
    func progress(at time: Double) -> Float {
        let span = arrivesMedia - departedMedia
        guard span > 1e-4 else { return 1 }
        return Float(min(max((time - departedMedia) / span, 0), 1))
    }

    /// Current world position: interpolate along the active leg's system endpoints (a
    /// cruise leg's endpoints are the same star, so the ship holds there), else the
    /// straight `fromStar`→`toStar` fallback.
    func position(at time: Double, stars: [Star]) -> SIMD3<Float> {
        guard let leg = activeLeg(at: time) else {
            let a = stars[fromStar].position, b = stars[toStar].position
            return a + (b - a) * progress(at: time)
        }
        let a = stars[leg.fromStar].position, b = stars[leg.toStar].position
        return a + (b - a) * legProgress(leg, at: time)
    }

    /// The head's fraction ALONG the drawn ribbon (`fromStar`→`toStar`), so the ribbon's
    /// traveled/remaining split tracks the head even though the head moves per-leg. The
    /// head's world point is projected onto the ribbon segment. For the common two-system
    /// trip the head lies exactly on the ribbon; for a 3+-system trip it's the nearest
    /// point (a minor approximation).
    func ribbonProgress(at time: Double, stars: [Star]) -> Float {
        let a = stars[fromStar].position, b = stars[toStar].position
        let ab = b - a
        let denom = simd_dot(ab, ab)
        guard denom > 1e-6 else { return progress(at: time) }
        let h = position(at: time, stars: stars) - a
        return min(max(simd_dot(h, ab) / denom, 0), 1)
    }

    /// The ship's world position INSIDE the focused system's orrery, or nil when its
    /// active leg isn't wholly within this system (both endpoint location codes must
    /// resolve). Used to keep a ship visible + correctly placed on an intra-system cruise
    /// leg once the camera has drilled in. `resolve` is the orrery layer's location→world.
    func orreryPosition(at time: Double, resolve: (String) -> SIMD3<Float>?) -> SIMD3<Float>? {
        guard let leg = activeLeg(at: time),
              let a = resolve(leg.fromCode), let b = resolve(leg.toCode) else { return nil }
        return a + (b - a) * legProgress(leg, at: time)
    }

    /// The leg under way at `time` (the first whose window hasn't ended; the last once
    /// the trip is over). Nil only when there are no legs (straight-line fallback).
    private func activeLeg(at time: Double) -> Leg? {
        guard !legs.isEmpty else { return nil }
        for leg in legs where time < leg.endMedia { return leg }
        return legs.last
    }

    /// Progress 0…1 within a leg (clamped), so `time` before a leg's start reads 0 and
    /// after its end reads 1.
    private func legProgress(_ leg: Leg, at time: Double) -> Float {
        let span = leg.endMedia - leg.startMedia
        guard span > 1e-4 else { return 1 }
        return Float(min(max((time - leg.startMedia) / span, 0), 1))
    }

    /// Wall-clock end times for a route's legs: the LAST leg ends at `arrivesAt`
    /// and each earlier end is found by walking backwards through the durations
    /// after it — the date-domain twin of the renderer's media-time walk, so the
    /// two never disagree about where a leg boundary falls.
    ///
    /// Nil when the route has no legs or any leg lacks a duration; the renderer
    /// already treats that case as "no resolved legs" and draws a straight segment.
    static func legEndDates(seconds: [Double?], arrivesAt: Date) -> [Date]? {
        guard !seconds.isEmpty else { return nil }
        var out = [Date](repeating: arrivesAt, count: seconds.count)
        var end = arrivesAt
        for i in stride(from: seconds.count - 1, through: 0, by: -1) {
            guard let s = seconds[i] else { return nil }
            out[i] = end
            end = end.addingTimeInterval(-s)
        }
        return out
    }
}
