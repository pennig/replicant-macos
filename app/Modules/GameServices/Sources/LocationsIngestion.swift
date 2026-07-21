//
//  LocationsIngestion.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The locations catalog's event-ingestion policy, declared beside
//  `LocationsClient` and `LocationEventPolicy` — the client and the tested
//  decision rule its routes apply. The composition root creates one instance
//  at launch, registers `eventRoutes` with `GameSync`, and calls
//  `cancelPendingWork()` from the logout teardown (the passive-scan debounce
//  lives outside the engine's cancellation domain, so a scan armed just
//  before logout must be cancelled here or it would write into freshly-wiped
//  tables and spend the next session's budget on the old account's behalf).
//
//  A class (one instance owning its debounce handle) rather than static
//  values: the debounce is mutable state with a teardown obligation, and
//  tying it to the instance keeps "who cancels this" answerable.
//

import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData

public final class LocationsIngestion: Sendable {
    /// The armed passive-scan debounce, if any. Cancelled and re-armed per
    /// qualifying event; cancelled outright by `cancelPendingWork()`.
    private let pendingPassiveScan = LockIsolated<Task<Void, Never>?>(nil)

    public init() {}

    public var eventRoutes: [EventRoute] {
        [scanRoute(), catalogRoute()]
    }

    /// Logout teardown: cancel a scan still waiting out its debounce window.
    public func cancelPendingWork() {
        pendingPassiveScan.withValue { $0?.cancel(); $0 = nil }
    }

    /// Passively refresh the catalog. Shops, megastructures/objects, and the
    /// outer system live ONLY in the scan response (never the locations
    /// endpoint), so when an event implies the current system's observable
    /// state changed — an arrival, a megastructure contribution, a new
    /// object/threat, a shop or location event — re-scan (free, current-system)
    /// and merge into `SystemDetail`. Excludes scan-echo event types so our own
    /// scan can't feed back into a loop.
    ///
    /// A scan only ever reads *this replicant's current location*, so an event
    /// is worth a scan only when it actually concerns that location, and a
    /// host-vessel arrival additionally advances the roster location. That whole
    /// policy — the arrival host-device gate, the location-scoped current-system
    /// gate, and the arrival→location derivation — lives in (and is tested by)
    /// `LocationEventPolicy.decide`; this route just applies its decision.
    ///
    /// A scan reads the current location's *current* state, so a burst of
    /// relevant events needs exactly one scan to converge — not one per event.
    /// This matters most at launch: tier-2 backfill replays a batch of recent
    /// events through the routes, and events dispatch *serially* (see
    /// `EventRouter.dispatch`), so a per-event scan would fire a redundant scan
    /// for each replayed event. A trailing debounce collapses the burst: each
    /// relevant event (re)arms a short timer, and a single scan runs once the
    /// events quiet — the same live state one immediate scan would have read.
    private func scanRoute() -> EventRoute {
        EventRoute(id: "locations.scan", match: .all) { [pendingPassiveScan] event in
            @Dependency(\.defaultDatabase) var database
            // The replicant the event pertains to (else the sole/first on the
            // roster) — the source of the host-device and current-system gates.
            let replicant = try? await database.read { db -> Replicant? in
                if let code = event.replicantCode,
                   let match = try Replicant.where({ $0.replicantCode.eq(code) }).fetchOne(db) {
                    return match
                }
                return try Replicant.fetchAll(db).first
            }
            guard let replicant, !replicant.replicantCode.isEmpty else { return }
            let code = replicant.replicantCode

            let decision = LocationEventPolicy.decide(event: event, replicant: replicant)

            // A host-vessel arrival IS the authoritative location change: fold
            // the destination straight into the roster row so `currentStar` /
            // `currentLocation` are never stale between the move and the next
            // `accounts/me` refresh. The name columns are cleared (the arrival
            // carries no display names, and the UI falls back to the mono
            // designation) — except the star name survives an intra-system hop.
            //
            // Only *live stream* arrivals move the roster. A catch-up arrival
            // is history being replayed on launch (see `EventPipeline.catchUp`):
            // folding those in would walk the roster through stale waypoints —
            // the location flicker — before settling. The roster's launch truth
            // is `accounts/me`; catch-up exists to repair the other tables
            // (devices, etc.), which it still does.
            if event.provenance == .stream, let update = decision.rosterUpdate {
                let priorStarName = replicant.currentStarName
                try? await database.write { db in
                    try Replicant.where { $0.replicantCode.eq(code) }.update {
                        $0.currentStar = #bind(update.star)
                        $0.currentLocation = #bind(update.location)
                        $0.currentStarName = #bind(update.systemChanged ? nil : priorStarName)
                        $0.currentLocationName = #bind(String?.none)
                    }
                    .execute(db)
                }
            }

            guard decision.shouldScan else { return }

            // Debounce: cancel any scan still waiting out its window and re-arm.
            pendingPassiveScan.withValue { pending in
                pending?.cancel()
                pending = Task {
                    @Dependency(\.continuousClock) var clock
                    try? await clock.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    @Dependency(\.locationsClient) var locationsClient
                    try? await locationsClient.scanAndPersist(replicantCode: code)
                }
            }
        }
    }

    /// Fold catalog data carried in event payloads straight into
    /// `SystemDetail`, so the Locations view and gather_salvage picker stay
    /// current with no `body(_:)`/`scan` API call. This is the one dispatch
    /// table for payload-scraped catalog updates — a new event that carries
    /// catalog data is a new `case` here plus one `LocationsClient` method,
    /// nothing more. Every handler is best-effort and idempotent.
    private func catalogRoute() -> EventRoute {
        EventRoute(id: "locations.catalog", match: .all) { event in
            @Dependency(\.locationsClient) var locationsClient
            let payload = event.payload
            // Prefer the envelope's first-class `location`; fall back to payload.
            let location = event.location ?? payload?["location"]?.stringValue
            switch event.event {
            case "scan.completed":
                // Full scanned body (physical, salvage, sites, inventory).
                if let payload {
                    _ = try? await locationsClient.ingestScanResult(payload: payload)
                }
            case "salvage.depleted":
                // A salvage site at `location` is fully spent.
                if let location {
                    _ = try? await locationsClient.markSalvageDepleted(location: location)
                }
            // NOTE: the resource-level salvage-depletion event's new dotted name
            // is unconfirmed post-migration; it will surface in the event log so
            // the case can be added once its name/payload are known.
            default:
                break
            }
        }
    }
}
