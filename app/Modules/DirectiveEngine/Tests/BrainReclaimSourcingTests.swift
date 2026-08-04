//
//  BrainReclaimSourcingTests.swift
//  Replicould — DirectiveEngine
//
//  Task 23: the two halves of `tendMesh` meet. `PrunePredicate` says which
//  deployed relays are spare; `RelayRun` can already fly out and reclaim one.
//  This is the tick that joins them — when the brain decides to grow, it looks
//  for the NEAREST spare relay within a distance cutoff and, if it finds one,
//  sets `Directive.sourceRelayCode` to it instead of printing a fresh relay
//  (370 units, ~800 s).
//
//  Everything below drives the REAL seam — a real `GameDatabase`, `Brain
//  .evaluateOnce()`, and assertions on the `directives` row that comes out —
//  for the reason `BrainGrowTests` states: the row IS the interface to
//  `RelayRun`, and a source chosen in a pure function nobody wires up is worth
//  nothing.
//
//  **Geometry of `seedReclaimWorld` (every test reads off it):**
//
//      SOL      (0, 0,  0)   meshed by REL_SOL, print hub at SOL-3, carriers
//      VEGA     (5, 0,  0)   the grow target — 3,200 units of salvage, 1 hop
//      PROXIMA  (5, 0,  3)   spare relay,  3.000 ly from VEGA
//      DEADEND  (0, 0, -5)   spare relay,  7.071 ly from VEGA
//      OUTBACK  (0, 0,-40)   spare relay, 40.311 ly from VEGA — past the cutoff
//
//  The spares are genuinely spare rather than declared so: each is a meshed,
//  SURVEYED system with no value, no fleet and no replicant, so the anchor→
//  target path-union misses it and `PrunePredicate` returns it. And none of
//  them shortens the SOL→VEGA chain — SOL reaches VEGA directly in 5 ly, where
//  the cheapest route through PROXIMA is 8.831 ly for the same one relay — so
//  the grow decision is identical in every world here and only the SOURCING
//  differs.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import UniverseModels

@testable import DirectiveEngine

private let tickTime = Date(timeIntervalSince1970: 1_000)

/// A spare relay to plant in the world: its device code, its system, and where
/// that system sits.
private struct Spare {
    let relay: String
    let system: String
    let position: Position

    static let proxima = Spare(relay: "R_B", system: "PROXIMA", position: .init(x: 5, y: 0, z: 3))
    static let deadend = Spare(relay: "R_A", system: "DEADEND", position: .init(x: 0, y: 0, z: -5))
    static let outback = Spare(relay: "R_C", system: "OUTBACK", position: .init(x: 0, y: 0, z: -40))
}

/// The smallest world in which a reclaim can actually be sourced. See the file
/// header for the geometry.
///
/// **`hosts` is the carrier-safety input, and it defaults to hosting.** A
/// reclaim deactivates the source relay, which takes that system off the mesh,
/// so the `stow` that follows is only commandable because a replicant is aboard
/// the carrier standing there (`ftl-authority-rule`, rule 1). Passing `[]`
/// models the fleet a later `growFleet` could build — a vessel hosting nobody —
/// which must fall back to printing.
///
/// Every spare system is seeded SURVEYED with no belts. That is not decoration:
/// an unsurveyed meshed system is a prune TARGET (unknown value reads as
/// pinned), so without it no spare would ever be reclaimable and every test here
/// would pass for the wrong reason.
private func seedReclaimWorld(
    _ db: Database,
    carriers: [String] = ["V1"],
    hosts: [String] = ["V1"],
    spares: [Spare] = []
) throws {
    try seedRelay(db, code: "REL_SOL", location: "SOL")
    try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
    try seedSystemDetail(db, system: "SOL", scanned: true)
    try seedPrintHub(db, code: "HUB1", location: growHubLocation)
    for code in carriers {
        try seedDevice(db, code: code, type: "heaven_vessel", location: growHubLocation)
    }
    for (index, host) in hosts.enumerated() {
        try seedReplicant(db, code: "REP\(index)", star: "SOL", hostedDeviceCode: host)
    }
    try seedStar(db, designation: "VEGA", x: 5, y: 0, z: 0)
    try seedSalvageAssay(db, id: "SITE-VEGA", system: "VEGA", totals: ["metal": 3_200])
    for spare in spares {
        try seedStar(
            db, designation: spare.system,
            x: spare.position.x, y: spare.position.y, z: spare.position.z
        )
        try seedSystemDetail(db, system: spare.system, scanned: true)
        try seedRelay(db, code: spare.relay, location: "\(spare.system)-1")
    }
}

/// One brain tick against `database`, with the confirm-fresh gate answering
/// from the local fleet table (nothing moved between ranking and the commit).
private func tick(_ database: any DatabaseWriter, uuid: UUIDGenerator) async -> BrainDecision {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(tickTime)
        $0.uuid = uuid
        $0.deviceRefresher = confirmingRefresher(database)
    } operation: {
        await Brain(now: tickTime).evaluateOnce()
    }
}

/// The Relay Run this tick launched — and a recorded failure, rather than a
/// silent `nil`, if it launched none. Every test here asserts about the SOURCE
/// of a launch, so a tick that never launched would otherwise pass a
/// `sourceRelayCode == nil` expectation for entirely the wrong reason.
private func launchedRun(
    _ database: any DatabaseWriter, _ decision: BrainDecision
) async throws -> Directive {
    guard case .dispatch = decision else {
        Issue.record("expected a launch, got \(decision)")
        throw LaunchMissing()
    }
    let rows = try await database.read { db in
        try Directive.where { $0.kind.eq(DirectiveKind.relayRun) }.order { $0.id }.fetchAll(db)
    }
    #expect(rows.count == 1)
    return try #require(rows.first)
}

private struct LaunchMissing: Error {}

@Suite("Brain — sourcing a grow from a reclaim")
struct BrainReclaimSourcingTests {
    /// The headline. A spare relay 7.07 ly from the plant site is inside the
    /// cutoff, so the run is sourced from it and prints nothing.
    ///
    /// The target is asserted alongside the source because the two are only
    /// meaningful together: `sourceRelayCode` is a hint about how to serve
    /// `targets`, and a run that reclaimed the right relay toward the wrong
    /// system would be no use at all.
    @Test func nearestReclaimableRelayIsPreferredOverPrint() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedReclaimWorld(db, spares: [.deadend])
        }

        let decision = await tick(database, uuid: .incrementing)
        let row = try await launchedRun(database, decision)

        #expect(row.targets == ["VEGA"])
        #expect(row.deviceCode == "V1")
        #expect(
            row.sourceRelayCode == "R_A",
            "DEADEND's relay is 7.07 ly from VEGA — well inside the cutoff, and free"
        )
    }

    /// The fallback, and the proof the cutoff is a real bound rather than
    /// decoration. `OUTBACK` holds a relay that prune calls spare, exactly like
    /// `DEADEND` above — the ONLY difference is that it stands 40.3 ly from the
    /// plant site, so fetching it would cost more travel than the 800 s print it
    /// replaces. The run prints.
    @Test func printFallbackWhenNoReclaimableInRange() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedReclaimWorld(db, spares: [.outback])
        }

        let decision = await tick(database, uuid: .incrementing)
        let row = try await launchedRun(database, decision)

        #expect(row.targets == ["VEGA"])
        #expect(
            row.sourceRelayCode == nil,
            "a spare relay 40 ly away is not worth a round trip — print instead"
        )

        // …and the relay really is spare, so this test cannot be passing
        // because prune found nothing. Same view, same graph, read directly.
        let analysis = try await database.read { db -> PruneAnalysis in
            let view = try WorldView.read(from: db, now: tickTime)
            return PrunePredicate.analyse(view: view, graph: MeshGraph(positions: view.starPositions))
        }
        #expect(analysis.declined == nil)
        #expect(analysis.reclaimable.map(\.deviceCode) == ["R_C"])
    }

    /// NEAREST, not first. Both spares are inside the cutoff; `R_A` (DEADEND,
    /// 7.07 ly) sorts before `R_B` (PROXIMA, 3.00 ly) by device code — which is
    /// the order `PruneAnalysis.reclaimable` arrives in — so an implementation
    /// that took the head of that list would pick the further one and fail here.
    @Test func nearestOfSeveralInRangeIsChosen() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedReclaimWorld(db, spares: [.deadend, .proxima])
        }

        let decision = await tick(database, uuid: .incrementing)
        let row = try await launchedRun(database, decision)

        #expect(
            row.sourceRelayCode == "R_B",
            "PROXIMA is 3.00 ly from VEGA against DEADEND's 7.07 — nearest wins, not lowest code"
        )
    }

    /// A `declined` analysis is the predicate saying "I cannot judge this
    /// world", and the brain must hear that as "print", never as "reclaim
    /// whatever is left over". `GHOST` holds a live relay and has no census row
    /// at all, which trips `PrunePredicate`'s census-coverage precondition; the
    /// perfectly good spare at DEADEND is offered up by nobody.
    ///
    /// It still LAUNCHES — a census hole is prune's problem, not grow's — which
    /// is what makes the `nil` here a decision rather than an absence.
    ///
    /// **Honest about what this does and does not kill.** `PruneAnalysis`
    /// guarantees that a declined analysis carries an EMPTY `reclaimable`, so
    /// deleting `reclaimSource`'s explicit `declined` guard leaves this test
    /// green — the guard is defence in depth against that invariant weakening,
    /// not the thing under test. What this pins is the end-to-end behaviour the
    /// brief asks for and nothing else covers: a world prune cannot judge
    /// launches a PRINT rather than stalling, guessing, or idling — and the
    /// second expectation proves the world really does decline, so the first
    /// cannot be passing because the census hole never landed.
    @Test func declinedPruneAnalysisSourcesAPrintRatherThanAGuess() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedReclaimWorld(db, spares: [.deadend])
            // A meshed system the census cannot place. No `seedStar`, by design.
            try seedRelay(db, code: "R_GHOST", location: "GHOST-1")
        }

        let decision = await tick(database, uuid: .incrementing)
        let row = try await launchedRun(database, decision)

        #expect(row.targets == ["VEGA"], "the census hole must not stop the grow itself")
        #expect(
            row.sourceRelayCode == nil,
            "prune declined to judge, so there is no reclaimable relay to source from"
        )

        let analysis = try await database.read { db -> PruneAnalysis in
            let view = try WorldView.read(from: db, now: tickTime)
            return PrunePredicate.analyse(view: view, graph: MeshGraph(positions: view.starPositions))
        }
        #expect(
            analysis.declined == .censusIncomplete(systems: ["GHOST"]),
            "and it declined for the reason this world was built to cause"
        )
    }

    /// **The carrier-safety gate.** Deactivating the source relay takes its
    /// system off the mesh, so the `stow` that must follow is commandable only
    /// under `ftl-authority-rule` rule (1) — a replicant physically present.
    /// `RelayRun.carrierRetainsAuthority` turns a carrier that lacks one into a
    /// loud stall rather than a permanent strand, but a stall is still a Relay
    /// Run wasted and a carrier held. The brain must not send one.
    ///
    /// Identical to the headline world in every respect except that no
    /// replicant rides in `V1`, so the spare at DEADEND is left where it stands
    /// and the run prints — which is always safe.
    @Test func aCarrierHostingNoReplicantPrintsRatherThanReclaiming() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedReclaimWorld(db, hosts: [], spares: [.deadend])
        }

        let decision = await tick(database, uuid: .incrementing)
        let row = try await launchedRun(database, decision)

        #expect(row.deviceCode == "V1")
        #expect(
            row.sourceRelayCode == nil,
            "V1 hosts no replicant, so it could not command the stow once the source goes dark"
        )
    }

    /// A replicant aboard SOME OTHER vessel does not license this carrier.
    /// `V1` is the carrier the brain picks (lowest code at the hub); the
    /// account's only replicant rides in `V2`. A gate that merely asked "does
    /// the account have a replicant anywhere?" — or that read the fleet rather
    /// than the chosen hull — passes this world and strands the run.
    @Test func aReplicantAboardADifferentVesselDoesNotLicenseThisCarrier() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedReclaimWorld(db, carriers: ["V1", "V2"], hosts: ["V2"], spares: [.deadend])
        }

        let decision = await tick(database, uuid: .incrementing)
        let row = try await launchedRun(database, decision)

        #expect(row.deviceCode == "V1", "lowest code at the hub — V2's replicant does not change that")
        #expect(row.sourceRelayCode == nil)
    }

    /// One spare relay, one reclaim. A Relay Run already in force names `R_B`
    /// as its source, so this tick must leave it alone and fall to the next
    /// nearest (`R_A`) — not send two carriers to deactivate the same relay.
    ///
    /// The mirror of `inFlightTargets` on the sourcing side: prune is stateless
    /// and re-derives `reclaimable` from the world every tick, and a relay that
    /// is still standing and still relaying stays on that list for the whole
    /// flight of the run coming to collect it.
    @Test func aSourceAnotherRunIsAlreadyFetchingIsNotSelectedTwice() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedReclaimWorld(db, carriers: ["V1", "V2"], hosts: ["V1", "V2"],
                                 spares: [.deadend, .proxima])
            try seedRelayRun(
                db, id: "AAA-in-force", deviceCode: "V2", targets: ["ALTAIR"], sourceRelayCode: "R_B"
            )
        }

        let rows = try await database.read { db in
            try Directive.where { $0.kind.eq(DirectiveKind.relayRun) }.order { $0.id }.fetchAll(db)
        }
        #expect(rows.count == 1, "one run in force before the tick")

        let decision = await tick(database, uuid: .incrementing)
        guard case .dispatch = decision else {
            Issue.record("expected a launch, got \(decision)")
            return
        }
        let launched = try await database.read { db in
            try Directive
                .where { $0.kind.eq(DirectiveKind.relayRun) && $0.id.neq("AAA-in-force") }
                .fetchAll(db)
        }
        #expect(launched.count == 1)
        let row = try #require(launched.first)
        #expect(row.deviceCode == "V1", "V2 is reserved by the run in force")
        #expect(
            row.sourceRelayCode == "R_A",
            "R_B is spoken for, so the nearest AVAILABLE spare is DEADEND's R_A"
        )
    }

    /// The cutoff is a distance from the PLANT SITE, and it is stated in the
    /// graph's own unit — two relay hops. Pinned as a value because it is a
    /// calibration an operator may need to find, and because a silent change to
    /// it changes which relays the fleet tears down.
    @Test func theCutoffIsTwoRelayHops() {
        #expect(Brain.reclaimRangeLY == 15.0)
        #expect(Brain.reclaimRangeLY == 2 * SalvageTargetPlanner.relayRangeLY)
    }
}
