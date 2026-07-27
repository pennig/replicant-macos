//
//  TravelItinerary.swift
//  Replicould — GameModels
//
//  The ONE rule for "which route should a travel surface display?", plus the
//  normalization of the backend's bare-system proxy codes.
//
//  Two sources describe the same trip and disagree. The device's live `travel`
//  block lists only the REMAINING legs and is observed to go stale (a surge plate
//  reports `route_progress_percent: 100` beside a live leg — see
//  `.claude/memory/travel-block-leg-vs-route.md`). The operation's stored command
//  response froze the WHOLE route at dispatch, with resolved location codes. The
//  star map used to read the first, the sidebar and device detail the second, so
//  the same trip rendered two different destinations. This is that rule, in one
//  place, for all three.
//
//  Separately, the backend names a destination two ways in one payload: a bare
//  system designation (`ASTELLIO`) that is a PROXY for the system's entry point,
//  and the resolved code (`ASTELLIO-1-L4`). A proxy code means nothing to the
//  orrery — `OrreryLayout` resolves a system designation to the star — so a route
//  carrying one planted its riser on the sun. `resolvingSystemProxies` swaps in
//  the specific code the same payload already supplies, and does nothing when it
//  supplies none.
//

import Foundation

extension TravelSnapshot {
    /// The itinerary to display for a travel op: the whole route captured at
    /// dispatch when we have it, else the device's remaining-legs snapshot. A
    /// stored route with no legs is a command response that carried no `route`
    /// (a surge plate's, say), which the live block can only improve on.
    public static func itinerary(stored: TravelSnapshot?, live: TravelSnapshot?) -> TravelSnapshot? {
        if let stored, !stored.legs.isEmpty { return stored }
        return live
    }

    /// The star system a location code belongs to — the designation up to the
    /// first hyphen (`AINALRAM-1-L4` → `AINALRAM`, `SOL-BELT-1` → `SOL`).
    public static func systemDesignation(_ code: String) -> String {
        String(code.split(separator: "-").first ?? "")
    }

    /// Whether `code` is a bare system designation — the backend's proxy for "this
    /// system's entry point". Every real location code carries at least one hyphen
    /// (`SOL-3`, `SOL-BELT-1`, `SOL-3-L4`), so the absence of one is the whole test.
    static func isSystemProxy(_ code: String) -> Bool {
        !code.isEmpty && !code.contains("-")
    }

    /// This itinerary with every bare-system proxy among its LEG endpoints replaced
    /// by the specific location the same itinerary already names for that system.
    ///
    /// Substitution order for a proxy at route position `p`:
    ///   1. the nearest specific code in the same system, by distance along the leg
    ///      endpoint sequence, ties going downstream;
    ///   2. `destination`, then `origin`, if either names that system specifically;
    ///   3. nothing — the proxy survives. We never synthesize an entry point.
    ///
    /// `origin` and `destination` are read as sources but never rewritten: they
    /// feed labels the sidebar and device detail already render correctly, and the
    /// riser anchor comes from the legs.
    public var resolvingSystemProxies: TravelSnapshot {
        // The endpoint sequence as (position, code). Each leg contributes its
        // `from` then its `to`, so "nearest in route" is a plain distance here even
        // when a leg is missing an endpoint.
        var sequence: [(pos: Int, code: String)] = []
        for (i, leg) in legs.enumerated() {
            if let from = leg.from { sequence.append((i * 2, from)) }
            if let to = leg.to { sequence.append((i * 2 + 1, to)) }
        }

        func substitute(for proxy: String, at pos: Int) -> String? {
            let system = Self.systemDesignation(proxy)
            let nearest = sequence
                .filter { !Self.isSystemProxy($0.code) && Self.systemDesignation($0.code) == system }
                .min { a, b in
                    let da = abs(a.pos - pos), db = abs(b.pos - pos)
                    return da == db ? a.pos > b.pos : da < db
                }
            if let nearest { return nearest.code }
            for fallback in [destination, origin] {
                if let fallback, !Self.isSystemProxy(fallback),
                   Self.systemDesignation(fallback) == system { return fallback }
            }
            return nil
        }

        func resolved(_ code: String?, at pos: Int) -> String? {
            guard let code, Self.isSystemProxy(code) else { return code }
            return substitute(for: code, at: pos) ?? code
        }

        var copy = self
        copy.legs = legs.enumerated().map { i, leg in
            var leg = leg
            leg.from = resolved(leg.from, at: i * 2)
            leg.to = resolved(leg.to, at: i * 2 + 1)
            return leg
        }
        return copy
    }
}
