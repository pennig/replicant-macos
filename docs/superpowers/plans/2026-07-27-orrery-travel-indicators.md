# Orrery Travel Indicators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the orrery's transit callout count down to when a device enters or leaves the view you are looking at, and stop a route to a bare system designation from planting its riser on the sun.

**Architecture:** One shared travel-itinerary derivation in `GameModels` (prefer the frozen dispatch route, fall back to the live block, normalize bare-system proxy codes) replaces three divergent per-surface rules. In `NewStarMapFeature`, `TransitBoundary` gains the anchor's route index and `Ship.Leg` gains a wall-clock end date, which together let the callout name the exact leg boundary it marks.

**Tech Stack:** Swift 6 / SwiftUI / Metal, Swift Testing (`@Test`/`#expect`), SQLiteData `@FetchAll`, SPM package rooted at `app/Modules`.

## Global Constraints

- Design spec: `docs/superpowers/specs/2026-07-27-orrery-travel-indicators-design.md`.
- All work happens in the SPM package at `app/Modules`. Run tests from there.
- **Never hard-code colors, spacing, or font sizes** — use `DesignSystem.swift` tokens (`.rcTextSecondary`, `Space.xs`, `.rcMonoSmall`, …).
- **System and location designations always render in a monospace token** (`.rcMonoSmall` here).
- Logging is `os.Logger` only — no `print`. None of these tasks should need logging.
- Read `swift test` results from the JSON event stream via the **`swift-test-event-stream`** skill, never by grepping console text.
- Commit after every task. Commits go to the local branch; no PR, no push.
- `NewStarMapFeature` defaults to `MainActor` isolation. Pure types in it (`SystemTransit`, `Ship`, `OrreryLayout`) are deliberately SwiftUI/GPU-free — keep them that way so they stay unit-testable.
- Do not put pure logic in a `static` on a SwiftUI `View` — it traps under `swift test` (see `.claude/memory/swiftui-view-statics-trap-in-tests.md`).

---

## File Structure

**Create:**
- `app/Modules/GameModels/Sources/TravelItinerary.swift` — the shared itinerary rule + system-proxy normalization, as an extension on `TravelSnapshot`. Separate file from `Device.swift` (already 695 lines and holding the model + schema) so the derivation has one clear home.
- `app/Modules/GameModels/Tests/TravelItineraryTests.swift` — tests for the above, using real payload shapes.

**Modify:**
- `app/Modules/NewStarMapFeature/Sources/SystemTransit.swift` — `TransitBoundary.anchorIndex`.
- `app/Modules/NewStarMapFeature/Sources/Ship.swift` — `Ship.departedAt`, `Ship.Leg.endsAt`, `Ship.legEndDates(seconds:arrivesAt:)`.
- `app/Modules/NewStarMapFeature/Sources/TransitProjection.swift` — `ProjectedTransit.arrivesAt` → `eventAt`.
- `app/Modules/NewStarMapFeature/Sources/TransitCalloutLayer.swift` — `enters in` / `leaves in`.
- `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift` — build leg dates into `Ship`; resolve each boundary's event date.
- `app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift` — fetch operations; build ships from the shared itinerary.
- `app/Modules/DevicesFeature/Sources/ActiveTaskCard.swift` — use the shared itinerary.
- `app/Modules/SidebarFeature/Sources/SidebarProgress.swift` — use the shared itinerary.

**Test:**
- `app/Modules/NewStarMapFeature/Tests/SystemTransitTests.swift` — `anchorIndex` coverage.
- `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift` — leg-date helper + the bare-system regression test.

---

### Task 1: Shared travel itinerary + system-proxy normalization

**Files:**
- Create: `app/Modules/GameModels/Sources/TravelItinerary.swift`
- Test: `app/Modules/GameModels/Tests/TravelItineraryTests.swift`

**Interfaces:**
- Consumes: `TravelSnapshot` (existing, `app/Modules/GameModels/Sources/Device.swift:577`) with `origin: String?`, `destination: String?`, `legs: [Leg]`, and `Leg` having `from: String?` / `to: String?`.
- Produces:
  - `static func TravelSnapshot.itinerary(stored: TravelSnapshot?, live: TravelSnapshot?) -> TravelSnapshot?`
  - `var TravelSnapshot.resolvingSystemProxies: TravelSnapshot`
  - `static func TravelSnapshot.isSystemProxy(_ code: String) -> Bool` (internal to GameModels — tests are `@testable`)
  - `static func TravelSnapshot.systemDesignation(_ code: String) -> String` (public — Task 6 reuses it)

- [ ] **Step 1: Write the failing tests**

Create `app/Modules/GameModels/Tests/TravelItineraryTests.swift`:

```swift
//
//  TravelItineraryTests.swift
//  Replicould — GameModels
//
//  The one itinerary rule every travel surface reads, and the normalization of
//  the backend's bare-system proxy codes.
//
//  The backend names a travel destination two ways in the SAME payload: a bare
//  system designation (`ASTELLIO`) standing in for that system's entry point,
//  and the resolved code (`ASTELLIO-1-L4`). Which one appears where varies by
//  endpoint, so the map used to anchor a riser on the star while the sidebar
//  named the Lagrange point. These pin the substitution down.
//

import Foundation
import Testing
import Utils
@testable import GameModels

/// A leg with just the fields the normalization reads.
private func leg(_ index: Int, _ from: String?, _ to: String?) -> TravelSnapshot.Leg {
    TravelSnapshot.Leg(index: index, from: from, fromName: nil, to: to, toName: nil,
                       type: nil, timeSeconds: nil, active: false)
}

private func snapshot(origin: String? = nil, destination: String? = nil,
                      legs: [TravelSnapshot.Leg] = []) -> TravelSnapshot {
    var s = TravelSnapshot(travelObject: .object(["destination": .string("PLACEHOLDER")]))!
    s.origin = origin
    s.destination = destination
    s.legs = legs
    return s
}

struct TravelItinerarySelectionTests {
    @Test func prefersTheFrozenDispatchRouteWhenItHasLegs() {
        let stored = snapshot(destination: "MEREDIANA-3",
                              legs: [leg(1, "AINALRAM-BELT-1", "AINALRAM-1-L4")])
        let live = snapshot(destination: "AINALRAM-BELT-1", legs: [leg(1, "X-1", "X-2")])

        #expect(TravelSnapshot.itinerary(stored: stored, live: live)?.destination == "MEREDIANA-3")
    }

    @Test func fallsBackToTheLiveBlockWhenTheStoredRouteHasNoLegs() {
        // A surge-plate command response carries no `route` at all.
        let stored = snapshot(origin: "SOL-3", destination: "AINALRAM")
        let live = snapshot(destination: "AINALRAM-BELT-1",
                            legs: [leg(1, "AINALRAM-1-L4", "AINALRAM-BELT-1")])

        #expect(TravelSnapshot.itinerary(stored: stored, live: live)?.legs.count == 1)
        #expect(TravelSnapshot.itinerary(stored: stored, live: live)?.destination == "AINALRAM-BELT-1")
    }

    @Test func fallsBackToTheLiveBlockWhenThereIsNoStoredRoute() {
        let live = snapshot(destination: "AINALRAM-BELT-1")
        #expect(TravelSnapshot.itinerary(stored: nil, live: live)?.destination == "AINALRAM-BELT-1")
    }

    @Test func isNilWhenNeitherSourceExists() {
        #expect(TravelSnapshot.itinerary(stored: nil, live: nil) == nil)
    }
}

struct SystemProxyResolutionTests {
    @Test func proxyDiscrimination() {
        #expect(TravelSnapshot.isSystemProxy("ASTELLIO"))
        #expect(!TravelSnapshot.isSystemProxy("ASTELLIO-1-L4"))
        #expect(!TravelSnapshot.isSystemProxy("SOL-BELT-1"))
        #expect(!TravelSnapshot.isSystemProxy(""))
    }

    /// The live block for a device mid-surge to a bare system: the leg names the
    /// proxy, `final_destination` names the entry point. The riser must anchor on
    /// the entry point, not the star.
    @Test func proxyResolvesFromTheItinerarysOwnDestination() {
        let s = snapshot(origin: "ALKALUROP-3-L4", destination: "ASTELLIO-1-L4",
                         legs: [leg(1, "ALKALUROP-3-L4", "ASTELLIO")])

        #expect(s.resolvingSystemProxies.legs[0].to == "ASTELLIO-1-L4")
    }

    /// When another leg already names a specific code in that system, it wins over
    /// the destination — it is nearer in the route.
    @Test func proxyResolvesToTheNearestSpecificCodeInTheSameSystem() {
        let s = snapshot(origin: "SOL-3", destination: "MEREDIANA-3",
                         legs: [leg(1, "SOL-3", "MEREDIANA"),
                                leg(2, "MEREDIANA-4-L4", "MEREDIANA-3")])

        #expect(s.resolvingSystemProxies.legs[0].to == "MEREDIANA-4-L4")
    }

    /// Nothing specific is known for that system anywhere in the itinerary, so the
    /// proxy survives untouched — we never invent an entry point.
    @Test func proxyWithNothingSpecificToSubstituteIsLeftAlone() {
        let s = snapshot(origin: "SOL-3", destination: "AINALRAM",
                         legs: [leg(1, "SOL-3", "AINALRAM")])

        #expect(s.resolvingSystemProxies.legs[0].to == "AINALRAM")
    }

    /// A route that visits one system twice resolves each proxy against its OWN
    /// neighbourhood, not a single global pick for that system.
    @Test func eachProxyResolvesAgainstItsOwnPositionInTheRoute() {
        let s = snapshot(origin: "SOL-3", destination: "MID-4",
                         legs: [leg(1, "SOL-3", "MID"),
                                leg(2, "MID-1-L4", "FAR-2"),
                                leg(3, "FAR-2", "MID"),
                                leg(4, "MID-9-L5", "MID-4")])
        let r = s.resolvingSystemProxies

        #expect(r.legs[0].to == "MID-1-L4")   // nearest downstream neighbour
        #expect(r.legs[2].to == "MID-9-L5")   // nearest to THIS proxy, not the first
    }

    /// A specific `from` in a foreign system is untouched, and a leg missing an
    /// endpoint entirely stays missing.
    @Test func specificCodesAndMissingEndpointsPassThrough() {
        let s = snapshot(origin: "SOL-3", destination: "ASTELLIO-1-L4",
                         legs: [leg(1, "SOL-3", nil), leg(2, nil, "ASTELLIO-1-L4")])
        let r = s.resolvingSystemProxies

        #expect(r.legs[0].from == "SOL-3")
        #expect(r.legs[0].to == nil)
        #expect(r.legs[1].from == nil)
        #expect(r.legs[1].to == "ASTELLIO-1-L4")
    }

    /// Normalization rewrites LEG endpoints only. `origin`/`destination` are read as
    /// substitution sources but left as the backend sent them, so the labels the
    /// sidebar and device detail already render correctly are not disturbed.
    @Test func originAndDestinationAreNotRewritten() {
        let s = snapshot(origin: "AINALRAM", destination: "ASTELLIO-1-L4",
                         legs: [leg(1, "AINALRAM-1-L4", "ASTELLIO")])
        let r = s.resolvingSystemProxies

        #expect(r.origin == "AINALRAM")
        #expect(r.destination == "ASTELLIO-1-L4")
        #expect(r.legs[0].to == "ASTELLIO-1-L4")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app/Modules && swift test --filter 'TravelItinerary|SystemProxyResolution' 2>&1 | tail -20
```

Expected: compile failure — `type 'TravelSnapshot' has no member 'itinerary'` (and `isSystemProxy`, `resolvingSystemProxies`).

- [ ] **Step 3: Write the implementation**

Create `app/Modules/GameModels/Sources/TravelItinerary.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd app/Modules && swift test --filter 'TravelItinerary|SystemProxyResolution' 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/GameModels/Sources/TravelItinerary.swift app/Modules/GameModels/Tests/TravelItineraryTests.swift
git commit -m "Give every travel surface one itinerary to read

The live travel block lists only remaining legs and goes stale; the stored
command response froze the whole route with resolved codes. Three surfaces
picked differently. One rule now, plus normalization of the backend's bare
system proxy codes against the specific ones the same payload supplies."
```

---

### Task 2: Adopt the shared itinerary in the device detail and sidebar

**Files:**
- Modify: `app/Modules/DevicesFeature/Sources/ActiveTaskCard.swift:44-49`
- Modify: `app/Modules/SidebarFeature/Sources/SidebarProgress.swift:50-52`

**Interfaces:**
- Consumes: `TravelSnapshot.itinerary(stored:live:)` and `.resolvingSystemProxies` from Task 1.
- Produces: nothing new. This is a behaviour-preserving refactor that additionally applies proxy normalization to both surfaces.

- [ ] **Step 1: Replace `ActiveTaskCard`'s inline rule**

In `app/Modules/DevicesFeature/Sources/ActiveTaskCard.swift`, replace the body of `itinerary`:

```swift
    /// The itinerary to display for a travel op — the shared rule (whole route
    /// frozen at dispatch when we have it, else the device's remaining-legs
    /// snapshot), with the backend's bare-system proxy codes resolved. Nil for a
    /// non-travel op.
    private var itinerary: TravelSnapshot? {
        guard operation?.kind == OperationKind.travel.rawValue else { return nil }
        return TravelSnapshot.itinerary(stored: operation?.travelSnapshot, live: liveTravel)?
            .resolvingSystemProxies
    }
```

- [ ] **Step 2: Replace `SidebarProgress`'s `??` chain**

In `app/Modules/SidebarFeature/Sources/SidebarProgress.swift`, inside `row(for:operation:)`, replace the `if kind == .travel` label assignment:

```swift
        if kind == .travel {
            let itinerary = TravelSnapshot.itinerary(
                stored: operation.travelSnapshot, live: device.travelSnapshot
            )?.resolvingSystemProxies
            label = itinerary?.destinationLabel
                ?? device.locationName ?? device.location ?? "In transit"
            symbol = "arrow.right"
        } else if kind == .print {
```

- [ ] **Step 3: Build and run the affected suites**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
cd app/Modules && swift test --filter 'SidebarProgress|ActiveTask|DevicesFeature' 2>&1 | tail -20
```

Expected: build clean; existing tests pass unchanged (both surfaces already preferred the stored route, so the visible behaviour is the same).

- [ ] **Step 4: Commit**

```bash
git add app/Modules/DevicesFeature/Sources/ActiveTaskCard.swift app/Modules/SidebarFeature/Sources/SidebarProgress.swift
git commit -m "Read the shared itinerary in the device detail and sidebar

Same route preference as before, lifted to the one place that owns it, and
these two surfaces now get proxy-code normalization for free."
```

---

### Task 3: Give a transit boundary its route index

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/SystemTransit.swift:18-32,56-93`
- Test: `app/Modules/NewStarMapFeature/Tests/SystemTransitTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `TransitBoundary.anchorIndex: Int` — the anchor's index in the `orderedCodes` array passed to `SystemTransit.resolve`. Task 5 uses it to pick the leg whose end date the callout counts down to.

- [ ] **Step 1: Write the failing tests**

In `app/Modules/NewStarMapFeature/Tests/SystemTransitTests.swift`, add to `SystemTransitTests`:

```swift
    /// The boundary carries WHERE in the route its anchor sits, not just which code
    /// it is — the callout counts down to that leg's end, and a route can name the
    /// same code twice.
    @Test func boundaryCarriesItsRouteIndex() {
        // SHERATANON orrery: inbound anchor is orderedCodes[2].
        let inbound = SystemTransit.resolve(
            orderedCodes: route, deviceCode: "AAAA",
            resolves: resolve(["SHERATANON-6-L4", "SHERATANON-2"]))
        #expect(inbound.boundaries.map(\.anchorIndex) == [2])

        // SOL orrery: outbound anchor is orderedCodes[1].
        let outbound = SystemTransit.resolve(
            orderedCodes: route, deviceCode: "AAAA",
            resolves: resolve(["SOL-3", "SOL-5-L4"]))
        #expect(outbound.boundaries.map(\.anchorIndex) == [1])
    }

    @Test func passThroughBoundariesCarryBothIndices() {
        let through = ["A-1", "MID-3-L4", "MID-1", "MID-2-L5", "Z-9"]
        let r = SystemTransit.resolve(
            orderedCodes: through, deviceCode: "BBBB",
            resolves: resolve(["MID-3-L4", "MID-1", "MID-2-L5"]))

        #expect(r.boundaries.map(\.direction) == [.inbound, .outbound])
        #expect(r.boundaries.map(\.anchorIndex) == [1, 3])
    }

    /// A route whose origin is the only in-view code: the outbound anchor is index
    /// 0, which the renderer reads as "left at departure".
    @Test func outboundAnchorAtTheRouteOrigin() {
        let r = SystemTransit.resolve(
            orderedCodes: route, deviceCode: "AAAA", resolves: resolve(["SOL-3"]))

        #expect(r.boundaries.map(\.anchorIndex) == [0])
        #expect(r.boundaries.map(\.direction) == [.outbound])
    }
```

Also update the three existing `#expect(r.boundaries == [...])` assertions in this file to include the new field. `viewingDestinationSystemShowsInboundBoundary` becomes:

```swift
        #expect(r.boundaries == [
            TransitBoundary(deviceCode: "AAAA", anchorCode: "SHERATANON-6-L4", anchorIndex: 2,
                            direction: .inbound, endpointCode: "SOL-3", viaCode: "SOL-5-L4")
        ])
```

`viewingOriginSystemShowsOutboundBoundary` becomes:

```swift
        #expect(r.boundaries == [
            TransitBoundary(deviceCode: "AAAA", anchorCode: "SOL-5-L4", anchorIndex: 1,
                            direction: .outbound, endpointCode: "SHERATANON-2",
                            viaCode: "SHERATANON-6-L4")
        ])
```

`viewingDestinationBodyPlantsRiserOnTheBodyAlone` becomes:

```swift
        #expect(r.boundaries == [
            TransitBoundary(deviceCode: "AAAA", anchorCode: "SHERATANON-2", anchorIndex: 3,
                            direction: .inbound, endpointCode: "SOL-3",
                            viaCode: "SHERATANON-6-L4")
        ])
```

Then read the rest of the file (`sed -n '55,200p' app/Modules/NewStarMapFeature/Tests/SystemTransitTests.swift`) and add `anchorIndex:` to every other `TransitBoundary(...)` literal, computing the index from that test's `orderedCodes`.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app/Modules && swift test --filter SystemTransitTests 2>&1 | tail -20
```

Expected: compile failure — `extra argument 'anchorIndex' in call`.

- [ ] **Step 3: Add the field**

In `app/Modules/NewStarMapFeature/Sources/SystemTransit.swift`, add to `TransitBoundary` after `anchorCode`:

```swift
    /// The route location where the riser sits (resolves at the current layer).
    var anchorCode: String
    /// WHERE that anchor sits in `orderedCodes`. `orderedCodes[i]` is the route's
    /// origin at `i == 0` and leg `i - 1`'s destination otherwise, so this is what
    /// lets a caller name the leg whose boundary the callout marks — and it stays
    /// unambiguous when a route names the same code twice.
    var anchorIndex: Int
```

Then populate it at both construction sites in `resolve`:

```swift
        // Inbound: something upstream of the first in-view anchor isn't shown here.
        if firstR > 0 {
            let origin = orderedCodes[0]
            let via = orderedCodes[firstR - 1]
            boundaries.append(TransitBoundary(
                deviceCode: deviceCode,
                anchorCode: orderedCodes[firstR],
                anchorIndex: firstR,
                direction: .inbound,
                endpointCode: origin,
                viaCode: via == origin ? nil : via))
        }

        // Outbound: something downstream of the last in-view anchor isn't shown here.
        if lastR < n - 1 {
            let dest = orderedCodes[n - 1]
            let via = orderedCodes[lastR + 1]
            boundaries.append(TransitBoundary(
                deviceCode: deviceCode,
                anchorCode: orderedCodes[lastR],
                anchorIndex: lastR,
                direction: .outbound,
                endpointCode: dest,
                viaCode: via == dest ? nil : via))
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd app/Modules && swift test --filter SystemTransitTests 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/SystemTransit.swift app/Modules/NewStarMapFeature/Tests/SystemTransitTests.swift
git commit -m "Carry the route index on a transit boundary

The callout needs to name the leg it marks, and a code alone is ambiguous
on a route that visits the same place twice."
```

---

### Task 4: Wall-clock end dates for a ship's legs

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/Ship.swift:17-49`
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift` (append a new suite)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Ship.departedAt: Date` (defaults `.distantPast`)
  - `Ship.Leg.endsAt: Date`
  - `static func Ship.legEndDates(seconds: [Double?], arrivesAt: Date) -> [Date]?`

- [ ] **Step 1: Write the failing tests**

Append to `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`:

```swift
/// The date-domain twin of the renderer's media-time walk: the LAST leg ends at
/// the trip's arrival and each earlier leg's end is found by subtracting the
/// durations after it. The callout counts down to one of these.
struct ShipLegDateTests {
    private let arrival = Date(timeIntervalSince1970: 1_000)

    @Test func lastLegEndsAtArrivalAndEarlierLegsWalkBackwards() {
        let dates = Ship.legEndDates(seconds: [45, 388, 35], arrivesAt: arrival)

        #expect(dates == [
            Date(timeIntervalSince1970: 1_000 - 388 - 35),
            Date(timeIntervalSince1970: 1_000 - 35),
            Date(timeIntervalSince1970: 1_000),
        ])
    }

    @Test func singleLegEndsAtArrival() {
        #expect(Ship.legEndDates(seconds: [265], arrivesAt: arrival) == [arrival])
    }

    /// A leg with no duration makes the whole walk meaningless — the renderer
    /// already falls back to a straight segment in exactly this case.
    @Test func anyMissingDurationYieldsNoDates() {
        #expect(Ship.legEndDates(seconds: [45, nil, 35], arrivesAt: arrival) == nil)
    }

    @Test func noLegsYieldsNoDates() {
        #expect(Ship.legEndDates(seconds: [], arrivesAt: arrival) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd app/Modules && swift test --filter ShipLegDateTests 2>&1 | tail -20
```

Expected: compile failure — `type 'Ship' has no member 'legEndDates'`.

- [ ] **Step 3: Add the field and the helper**

In `app/Modules/NewStarMapFeature/Sources/Ship.swift`, add to `Ship` beside `arrivesAt`:

```swift
    /// The real wall-clock departure, carried straight from the route. A transit
    /// callout whose anchor is the route's ORIGIN counts down to this (the ship
    /// leaves the view the instant the first leg starts). Defaults to
    /// `.distantPast` for callers that don't need it (tests).
    var departedAt: Date = .distantPast
```

Add to `Ship.Leg`, after `endMedia`:

```swift
        /// This leg's real wall-clock end. The media-time window drives per-frame
        /// placement; this drives the callout's live countdown, which needs a date.
        let endsAt: Date
```

Add at the end of `Ship`, before the closing brace:

```swift
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
```

- [ ] **Step 4: Fix the one existing `Ship.Leg` construction site**

`Ship.Leg` gains a non-optional stored property, so its memberwise initializer changes. In `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift`, inside the `let fleet: [Ship] = overlays.ships.compactMap` closure, replace the leg-building block:

```swift
            var shipLegs: [Ship.Leg] = []
            if !route.legs.isEmpty,
               let endDates = Ship.legEndDates(seconds: route.legs.map(\.seconds),
                                               arrivesAt: route.arrivesAt) {
                var end = arrives
                for (i, leg) in zip(route.legs.indices, route.legs).reversed() {
                    let start = end - (leg.seconds ?? 0)
                    let fs = indexByName[systemName(leg.from)] ?? from
                    let ts = indexByName[systemName(leg.to)] ?? to
                    shipLegs.append(Ship.Leg(fromStar: fs, toStar: ts,
                                             fromCode: leg.from, toCode: leg.to,
                                             startMedia: start, endMedia: end,
                                             endsAt: endDates[i]))
                    end = start
                }
                shipLegs.reverse()
            }
            return Ship(deviceCode: route.deviceCode, deviceType: route.deviceType,
                        fromStar: from, toStar: to,
                        departedMedia: departed, arrivesMedia: arrives,
                        arrivesAt: route.arrivesAt, departedAt: route.departedAt,
                        legs: shipLegs)
```

Note the guard changed: `legEndDates` returns nil when any duration is missing, which is exactly the `allSatisfy({ $0.seconds != nil })` check it replaces.

Then check for other construction sites and fix each the same way:

```bash
cd app/Modules && grep -rn "Ship.Leg(\|Ship(" --include='*.swift' NewStarMapFeature | grep -v '\.build'
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
cd app/Modules && swift test --filter 'ShipLegDateTests|Orrery|SystemTransit' 2>&1 | tail -20
```

Expected: build clean, all pass.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/Ship.swift app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift app/Modules/NewStarMapFeature/Tests/OrreryTests.swift
git commit -m "Carry wall-clock end dates on a ship's legs

Media time is monotonic, so a live countdown needs the date domain too.
Same backwards walk from final arrival, so the two never disagree."
```

---

### Task 5: Count down to the view boundary, not the final arrival

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/TransitProjection.swift:18-34`
- Modify: `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift` (`emitTransitProjection`, ~line 2273)
- Modify: `app/Modules/NewStarMapFeature/Sources/TransitCalloutLayer.swift:29-137`

**Interfaces:**
- Consumes: `TransitBoundary.anchorIndex` (Task 3); `Ship.Leg.endsAt` and `Ship.departedAt` (Task 4).
- Produces: `ProjectedTransit.eventAt: Date` replacing `arrivesAt`.

- [ ] **Step 1: Rename the projection's date and document what it now means**

In `app/Modules/NewStarMapFeature/Sources/TransitProjection.swift`, replace the `arrivesAt` property in `ProjectedTransit`:

```swift
    /// When the device crosses THIS view's boundary — arrives at the anchor
    /// (inbound) or departs it (outbound). Drives the card's live countdown.
    /// Legs are contiguous with no dwell, so both directions read the same
    /// instant; only the verb differs.
    let eventAt: Date
```

And update the doc comment above the struct: replace "the far endpoint + immediate external waypoint it names, its screen point" with "the far endpoint + immediate external waypoint it names, when it crosses this view's boundary, its screen point".

- [ ] **Step 2: Resolve each boundary's event date in the renderer**

In `app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift`, inside `emitTransitProjection`, replace the `for ship in ships` loop:

```swift
        var out: [ProjectedTransit] = []
        for ship in ships {
            let result = SystemTransit.resolve(orderedCodes: ship.orderedCodes,
                                               deviceCode: ship.deviceCode, resolves: resolves)
            for boundary in result.boundaries {
                guard let base = layout.position(ofLocation: boundary.anchorCode) else { continue }
                let top = base + SIMD3<Float>(0, height, 0)
                guard let point = projectViewPoint(top, view: viewM, proj: proj, width: w, height: h)
                else { continue }
                out.append(ProjectedTransit(
                    deviceCode: boundary.deviceCode,
                    direction: boundary.direction == .inbound ? .inbound : .outbound,
                    endpointCode: boundary.endpointCode,
                    viaCode: boundary.viaCode,
                    eventAt: eventDate(for: boundary, on: ship),
                    point: snapToPixelGrid(point, scale: pixelScale), opacity: op))
            }
        }
        emit(out)
    }

    /// When `ship` is at a boundary's anchor — the instant the callout counts down
    /// to. `orderedCodes[i]` is the route origin at `i == 0` and leg `i - 1`'s
    /// destination otherwise, so the anchor's time is that leg's end (or the
    /// departure at the origin). Legs are contiguous with no dwell, so arriving at
    /// a waypoint and leaving it are the same instant — inbound and outbound share
    /// this, and only the card's verb differs.
    private func eventDate(for boundary: TransitBoundary, on ship: Ship) -> Date {
        let i = boundary.anchorIndex - 1
        guard i >= 0, i < ship.legs.count else { return ship.departedAt }
        return ship.legs[i].endsAt
    }
```

- [ ] **Step 3: Render `enters in` / `leaves in` on the card**

In `app/Modules/NewStarMapFeature/Sources/TransitCalloutLayer.swift`, change the `TransitCard` call site in `TransitCalloutLayer.body`:

```swift
                TransitCard(
                    symbolName: "device.\(deviceTypes[callout.deviceCode] ?? "")",
                    direction: callout.direction,
                    endpointCode: callout.endpointCode,
                    viaCode: callout.viaCode,
                    eventAt: callout.eventAt,
                    isSelected: callout.deviceCode == selectedDeviceCode,
                    action: { onSelect(callout.deviceCode) }
                )
```

In `TransitCard`, replace the `arrivesAt` property and add the countdown label:

```swift
    let eventAt: Date
```

```swift
    private var verb: String { direction == .inbound ? "Traveling from" : "Traveling to" }

    /// What the countdown measures, relative to the view you're looking at: when
    /// the device shows up here, or when it leaves. Deliberately NOT the trip's
    /// final arrival — that's on the device detail's Active Task card and the
    /// sidebar progress bar, and it isn't what this riser marks.
    private var countdownLabel: String { direction == .inbound ? "enters in" : "leaves in" }
```

And replace the countdown block:

```swift
                    // Live countdown to this view's boundary crossing — self-updating,
                    // so it ticks without the renderer re-pushing the projection each
                    // second.
                    if eventAt > .now {
                        HStack(spacing: Space.xs) {
                            Text(countdownLabel)
                                .font(.rcCaption)
                                .foregroundStyle(.rcTextSecondary)
                            Text(timerInterval: .now...eventAt, countsDown: true)
                                .font(.rcMonoSmall)
                                .monospacedDigit()
                                .foregroundStyle(.rcAccent)
                                .fixedSize()
                        }
                    }
```

- [ ] **Step 4: Build and run the star-map suites**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
cd app/Modules && swift test --filter NewStarMapFeatureTests 2>&1 | tail -30
```

Expected: build clean, all pass.

- [ ] **Step 5: Compile-check the app target**

The `.xcodeproj` shell isn't covered by the package build.

```bash
cd app && xcodebuild -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/TransitProjection.swift app/Modules/NewStarMapFeature/Sources/TransitCalloutLayer.swift app/Modules/NewStarMapFeature/Sources/StarFieldRenderer.swift
git commit -m "Count the transit callout down to this view's boundary

The card marks where a route crosses the edge of what you're looking at, so
the useful number is when the device turns up here or leaves — not when it
finishes a journey several legs later."
```

---

### Task 6: Build the map's ships from the shared itinerary

**Files:**
- Modify: `app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift:39-52,136-179`

**Interfaces:**
- Consumes: `TravelSnapshot.itinerary(stored:live:)`, `.resolvingSystemProxies`, `TravelSnapshot.systemDesignation(_:)` (Task 1).
- Produces: nothing new — `ships` keeps returning `[ShipRoute]`.

- [ ] **Step 1: Fetch the operations table**

In `app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift`, add beside the other `@FetchAll` properties (after `devices`):

```swift
    /// Open operations, for the travel route frozen at dispatch. The live `travel`
    /// block lists only remaining legs and goes stale; the stored command response
    /// has the whole route with resolved location codes — and it's what the sidebar
    /// and device detail already read, so reading it here is what keeps all three
    /// naming the same destination.
    @FetchAll(Operation.order { $0.startedAt.desc() }) private var operations
```

- [ ] **Step 2: Build ships from the shared itinerary**

Replace the `ships` computed property:

```swift
    /// Ships in transit, built from devices carrying a live travel activity: the
    /// origin/destination *systems* and the real trip window. Skips a device whose
    /// endpoints or timing can't be resolved, or that isn't going anywhere.
    private var ships: [ShipRoute] {
        devices.compactMap { device -> ShipRoute? in
            guard let activity = device.derivedActivity, activity.kind == .travel,
                  let departedAt = activity.startedAt, let arrivesAt = activity.completesAt
            else { return nil }
            // The same itinerary the sidebar and device detail read: the whole route
            // frozen at dispatch when we have it, else the device's remaining-legs
            // block — with the backend's bare-system proxy codes resolved, so a trip
            // to "ASTELLIO" anchors on ASTELLIO-1-L4 and not on the star.
            let stored = operations.first {
                $0.entityCode == device.deviceCode && $0.status.isOpen
                    && $0.kind == OperationKind.travel.rawValue
            }?.travelSnapshot
            guard let snapshot = TravelSnapshot.itinerary(stored: stored, live: device.travelSnapshot)?
                    .resolvingSystemProxies,
                  let origin = snapshot.origin.map(TravelSnapshot.systemDesignation),
                  let destination = snapshot.destination.map(TravelSnapshot.systemDesignation),
                  origin != destination
            else { return nil }
            // Per-leg route (location-level) so the renderer places the ship along its
            // real multi-leg path — parking at a star during intra-system cruise legs and
            // spanning stars on a surge/jump. Legs missing endpoints are dropped; an empty
            // set falls back to a single origin→destination segment.
            let legs = snapshot.legs.compactMap { leg -> RouteLeg? in
                guard let f = leg.from, let t = leg.to else { return nil }
                return RouteLeg(from: f, to: t, seconds: leg.timeSeconds)
            }
            return ShipRoute(deviceCode: device.deviceCode, deviceType: device.deviceType,
                             from: origin, to: destination,
                             departedAt: departedAt, arrivesAt: arrivesAt, legs: legs)
        }
    }
```

Then delete the now-unused `systemDesignation` static (around line 177) and update its two other callers — `relayNodes` (line ~127) and anywhere else — to `TravelSnapshot.systemDesignation`:

```bash
cd app/Modules && grep -n "Self.systemDesignation" NewStarMapFeature/Sources/NewStarMapView.swift
```

- [ ] **Step 3: Build and run the suites**

```bash
cd app/Modules && swift build --build-tests 2>&1 | tail -20
cd app/Modules && swift test 2>&1 | tail -30
```

Expected: build clean, whole package green.

- [ ] **Step 4: Commit**

```bash
git add app/Modules/NewStarMapFeature/Sources/NewStarMapView.swift
git commit -m "Build the map's ships from the shared itinerary

The map was the one surface still reading only the live travel block, which
is why a trip to a bare system pointed at the sun here and at the entry
point everywhere else. It now draws the whole route, completed legs and
all, so a multi-system ribbon bends through its real waypoints."
```

---

### Task 7: Regression test — a bare-system route anchors on the entry point

**Files:**
- Test: `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift` (append a new suite)

**Interfaces:**
- Consumes: `TravelSnapshot.resolvingSystemProxies` (Task 1), `TransitBoundary.anchorIndex` (Task 3), `OrreryLayout` (existing).
- Produces: nothing.

- [ ] **Step 1: Write the test**

Append to `app/Modules/NewStarMapFeature/Tests/OrreryTests.swift`:

```swift
/// The reported bug, end to end across the two pure layers that caused it: a route
/// naming a bare system designation used to anchor its riser on the star, because
/// `OrreryLayout` resolves a system code to the centre. Normalizing the proxy
/// against the code the same payload supplies moves it to the entry point.
struct BareSystemRouteAnchorTests {
    private func planet(_ id: String, phase: Double, semi: Double,
                        lagrange: [LagrangePoint]) -> OrreryPlanet {
        OrreryPlanet(
            designation: id, name: nil, type: nil, planetType: .unknown(""), estimated: false,
            tags: [], surfaceTempC: nil, atmosphere: Atmosphere(apiValue: nil), appearanceSeed: 0,
            orbitalDistanceAu: 1, inHabitableZone: false, scanned: true, moonCount: 0, lifeStage: nil,
            inventory: [], semiMajorScene: semi, periodDays: 100, phase0Deg: phase,
            displayRadius: 1, colorHex: "#ffffff", hasRing: false, indicators: [],
            hasInterestingMoon: false, moons: [], lagrange: lagrange)
    }

    /// ASTELLIO's orrery, with planet 1 carrying the L4 the backend uses as the
    /// system's entry point.
    private var layout: OrreryLayout {
        let model = SystemModel(
            star: StarDetail(designation: "ASTELLIO", name: nil, spectralType: nil, color: nil,
                             position: Position(x: 0, y: 0, z: 0), temperatureK: nil, massSolar: nil,
                             luminositySolar: nil, ageMy: nil, habitableZone: nil, miningBonusPct: nil),
            hzInnerScene: nil, hzOuterScene: nil,
            planets: [planet("ASTELLIO-1", phase: 0, semi: 10,
                             lagrange: [LagrangePoint(designation: "ASTELLIO-1-L4")])],
            belts: [], hazards: [], structures: [], kuiperScene: nil,
            frameScene: 20, deviceCount: 0, vesselCount: 0)
        return OrreryLayout(model: model, center: .zero, scale: 1, reveal: 1, time: 0)
    }

    /// The live block for a device surging to "ASTELLIO": the leg names the proxy,
    /// `final_destination` names the entry point.
    private var snapshot: TravelSnapshot {
        var s = TravelSnapshot(travelObject: .object(["destination": .string("ASTELLIO")]))!
        s.origin = "ALKALUROP-3-L4"
        s.destination = "ASTELLIO-1-L4"
        s.legs = [TravelSnapshot.Leg(index: 1, from: "ALKALUROP-3-L4", fromName: nil,
                                     to: "ASTELLIO", toName: nil, type: "surge",
                                     timeSeconds: 265, active: true)]
        return s
    }

    private func orderedCodes(_ s: TravelSnapshot) -> [String] {
        let legs = s.legs.compactMap { leg -> (String, String)? in
            guard let f = leg.from, let t = leg.to else { return nil }
            return (f, t)
        }
        guard let first = legs.first else { return [] }
        return [first.0] + legs.map(\.1)
    }

    @Test func rawProxyCodeAnchorsOnTheStar() {
        // The bug: "ASTELLIO" resolves to the layer's centre.
        #expect(layout.position(ofLocation: "ASTELLIO") == .zero)

        let r = SystemTransit.resolve(
            orderedCodes: orderedCodes(snapshot), deviceCode: "F2908E6E",
            resolves: { layout.position(ofLocation: $0) != nil })

        #expect(r.boundaries.map(\.anchorCode) == ["ASTELLIO"])
        #expect(layout.position(ofLocation: r.boundaries[0].anchorCode) == .zero)  // the sun
    }

    @Test func normalizedRouteAnchorsOnTheEntryPoint() {
        let codes = orderedCodes(snapshot.resolvingSystemProxies)
        #expect(codes == ["ALKALUROP-3-L4", "ASTELLIO-1-L4"])

        let r = SystemTransit.resolve(
            orderedCodes: codes, deviceCode: "F2908E6E",
            resolves: { layout.position(ofLocation: $0) != nil })

        #expect(r.boundaries.map(\.anchorCode) == ["ASTELLIO-1-L4"])
        #expect(r.boundaries.map(\.direction) == [.inbound])
        #expect(r.boundaries.map(\.anchorIndex) == [1])
        // The riser now sits off-centre, on the planet's leading Lagrange point.
        let anchor = layout.position(ofLocation: "ASTELLIO-1-L4")
        #expect(anchor != nil)
        #expect(anchor != .zero)
    }
}
```

- [ ] **Step 2: Run the test**

```bash
cd app/Modules && swift test --filter BareSystemRouteAnchorTests 2>&1 | tail -20
```

Expected: both pass. If `LagrangePoint`'s initializer needs more arguments, read its definition (`app/Modules/NewStarMapFeature/Sources/OrreryModels.swift:48`) and supply them; if `OrreryTests.swift` already has a usable `LagrangePoint` factory, reuse it rather than duplicating.

- [ ] **Step 3: Run the whole package and confirm green**

Use the `swift-test-event-stream` skill for the invocation, then:

```bash
cd app/Modules && swift test --event-stream-output-path /tmp/events.jsonl 2>&1 | tail -5
jq -r 'select(.kind == "testCaseEnded") | .payload._testCase.id' /tmp/events.jsonl | wc -l
jq -r 'select(.kind == "issueRecorded") | .payload' /tmp/events.jsonl
```

Expected: zero recorded issues.

- [ ] **Step 4: Commit**

```bash
git add app/Modules/NewStarMapFeature/Tests/OrreryTests.swift
git commit -m "Pin the bare-system riser to the entry point

Both halves of the reported bug: the raw proxy code resolving to the star,
and the normalized route landing on the Lagrange point instead."
```

---

### Task 8: Merge to local main

**Files:** none — integration only.

- [ ] **Step 1: Confirm the whole package is green and the app target builds**

```bash
cd app/Modules && swift test 2>&1 | tail -5
cd app && xcodebuild -scheme Replicould -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: tests pass, `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Merge into local main**

Per the standing preference: land on local `main`, no PR, no push.

```bash
cd /Users/matt/Developer/replicant-macos
git checkout main
git merge --no-ff worktree-travel-indicator-view-relative -m "Make orrery travel indicators view-relative and stop them pointing at the sun"
git log --oneline -8
```

- [ ] **Step 3: Update project memory**

Append to `app/.claude/memory/travel-block-leg-vs-route.md` a note that bare system designations are proxies for the entry point, that `TravelSnapshot.resolvingSystemProxies` normalizes them, and that all three travel surfaces now read `TravelSnapshot.itinerary(stored:live:)`. Add a matching index line if the note's summary changes materially.

```bash
git add app/.claude/memory/
git commit -m "Record the system-proxy code rule in project memory"
```

---

## Self-Review

**Spec coverage.** Part 1 (shared itinerary + proxy normalization) → Tasks 1, 2, 6. Part 2 (view-relative countdown) → Tasks 3, 4, 5. Part 3 (tests) → tests live inside Tasks 1, 3, 4 and the dedicated Task 7. The spec's accepted consequence (map draws the whole route) is realized in Task 6 and called out in its commit message. Out-of-scope items are untouched: no task modifies `OrreryLayout.resolveExact`, invents an entry point, or changes the galaxy view.

**Placeholder scan.** No TBDs. Every code step carries the actual code. Two steps deliberately end in a `grep` to find remaining call sites (Task 4 Step 4, Task 6 Step 2) rather than asserting a count I haven't verified — the grep prints them, and the required edit is shown in full immediately above.

**Type consistency.** `TravelSnapshot.itinerary(stored:live:)`, `.resolvingSystemProxies`, `TravelSnapshot.systemDesignation(_:)`, `TravelSnapshot.isSystemProxy(_:)`, `TransitBoundary.anchorIndex`, `Ship.departedAt`, `Ship.Leg.endsAt`, `Ship.legEndDates(seconds:arrivesAt:)`, `ProjectedTransit.eventAt` — each defined in one task and referenced by the same name and signature everywhere after. `isSystemProxy` is deliberately non-public (GameModels-internal, reached in tests via `@testable`); `systemDesignation` is public because Task 6 calls it from `NewStarMapFeature`.

**Known risk, flagged for the implementer.** Task 5's `eventDate(for:on:)` falls back to `ship.departedAt` whenever the anchor index has no preceding leg. That is correct for an outbound anchor at the route origin, and it is also what a ship built with NO resolved legs gets — such a ship produces no boundaries at all (`orderedCodes` is empty), so the fallback is unreachable in that case, but it is a safe value rather than a crash if that ever changes.
