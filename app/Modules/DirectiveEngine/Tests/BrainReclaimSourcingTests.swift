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
//  **`seedReclaimWorld` is a ONE-HOP world, and that is why the strand guard
//  never fires in it.** VEGA is 5 ly from SOL, so SOL survives as a mesh link
//  however many spares get reclaimed — `nearestOfSeveralInRangeIsChosen` really
//  does reclaim PROXIMA's relay while grow's own chain exits at PROXIMA, and it
//  is harmless only because SOL is in range too. Do not read these worlds as
//  evidence the guard is inert: the hazard needs a MULTI-hop grow, where the
//  plant site can have exactly one mesh neighbour, and it has its own world in
//  `aSourceTheNewRelayNeedsToLinkToIsNotReclaimed` at the bottom of the file.
//

import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
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
    try seedHubStockpile(db, location: growHubLocation, resources: BrainCeiling.aggregateSpendFloor * 2)
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
    await tickReport(database, uuid: uuid).decision
}

/// The same tick, keeping the WHOLE report — the why-view's feed, not just the
/// decision. `refresher` defaults to the local-fleet stand-in every test above
/// uses; a test about a DEFERRED launch overrides it.
private func tickReport(
    _ database: any DatabaseWriter,
    uuid: UUIDGenerator,
    refresher: DeviceRefreshClient? = nil
) async -> BrainReport {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(tickTime)
        $0.uuid = uuid
        $0.deviceRefresher = refresher ?? confirmingRefresher(database)
    } operation: {
        await Brain(now: tickTime).report()
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
    ///
    /// A calibration lock, NOT behavioural evidence: it restates the constant
    /// and can only fail by editing the line it guards. What proves the cutoff
    /// actually bounds anything is `printFallbackWhenNoReclaimableInRange`,
    /// which is killed by widening it to infinity.
    @Test func theCutoffIsTwoRelayHops() {
        #expect(Brain.reclaimRangeLY == 15.0)
        #expect(Brain.reclaimRangeLY == 2 * SalvageTargetPlanner.relayRangeLY)
    }

    /// **The source must not be the plant site's own way onto the mesh.**
    ///
    /// Grow and prune read one graph from two roots, and on a relay-count tie
    /// they can leave the mesh by different exits — `reach` takes the exit
    /// nearest the target, `pathUnion` the exit cheapest from the hub. This
    /// world forces exactly that split (every figure below is the real
    /// geometry, hop range 7.5 ly):
    ///
    ///     SOL     (0,   0, 0)  meshed — anchor, print hub at SOL-3, carrier V1
    ///     SPUR    (7,   0, 0)  meshed — 7.000 ly from SOL
    ///     MIDWAY  (7,   5, 0)  unmeshed — 5.000 from SPUR, 8.602 from SOL (NO link)
    ///     FARSIDE (7,  10, 0)  unmeshed — the value: 3,200 units of salvage
    ///     BYPASS  (3.5, 5, 0)  unmeshed — 6.103 from SOL, 6.103 from FARSIDE
    ///
    ///   - **Grow** (sources = every mesh system, keyed on distance FROM THE
    ///     MESH) takes `SPUR → MIDWAY → FARSIDE` at 10.000 ly over
    ///     `SOL → BYPASS → FARSIDE` at 12.207. Both cost 2 relays, so distance
    ///     decides. `firstHop == MIDWAY`.
    ///   - **Prune** (source = the anchor alone, distance accumulating FROM THE
    ///     HUB, mesh systems free) takes `SOL → BYPASS → FARSIDE` at 12.207
    ///     over `SOL → SPUR → MIDWAY → FARSIDE` at 17.000 — the free
    ///     `SOL → SPUR` leg costs no relay but its 7 ly still count. So the
    ///     union is `{SOL, BYPASS, FARSIDE}` and **`SPUR`'s relay is genuinely
    ///     spare** — correctly so, on the question prune was asked.
    ///
    /// It is then 5.000 ly from the plant site, the nearest thing there is, and
    /// well inside the 15 ly cutoff — so nearest-first selection points
    /// straight at it. But `MIDWAY`'s ONLY meshed neighbour is `SPUR` (`SOL` is
    /// 8.602 ly away, past the hop range). Reclaim it and the relay we fly to
    /// `MIDWAY` meshes nothing: the run stalls at `settling`, and the fleet is
    /// one node down having gained none.
    ///
    /// Remove `sourceWouldStrandTheHop` and this test sees `REL_SPUR`.
    @Test func aSourceTheNewRelayNeedsToLinkToIsNotReclaimed() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedRelay(db, code: "REL_SOL", location: "SOL")
            try seedRelay(db, code: "REL_SPUR", location: "SPUR-1")
            try seedPrintHub(db, code: "HUB1", location: growHubLocation)
            try seedHubStockpile(db, location: growHubLocation, resources: BrainCeiling.aggregateSpendFloor * 2)
            try seedDevice(db, code: "V1", type: "heaven_vessel", location: growHubLocation)
            try seedReplicant(db, code: "REP0", star: "SOL", hostedDeviceCode: "V1")
            try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
            try seedStar(db, designation: "SPUR", x: 7, y: 0, z: 0)
            try seedStar(db, designation: "MIDWAY", x: 7, y: 5, z: 0)
            try seedStar(db, designation: "FARSIDE", x: 7, y: 10, z: 0)
            try seedStar(db, designation: "BYPASS", x: 3.5, y: 5, z: 0)
            // Both meshed systems surveyed and valueless — an unsurveyed meshed
            // system is a prune target, which would pin SPUR and make this test
            // pass without the guard.
            try seedSystemDetail(db, system: "SOL", scanned: true)
            try seedSystemDetail(db, system: "SPUR", scanned: true)
            try seedSalvageAssay(
                db, id: "SITE-FARSIDE", system: "FARSIDE", totals: ["metal": 3_200]
            )
        }

        // The premises, asserted rather than assumed — this test is worthless if
        // the world does not actually produce the grow/prune split it describes.
        let (analysis, hopLinks) = try await database.read { db -> (PruneAnalysis, Set<String>) in
            let view = try WorldView.read(from: db, now: tickTime)
            let graph = MeshGraph(positions: view.starPositions)
            return (
                PrunePredicate.analyse(view: view, graph: graph),
                Brain.meshNeighbours(of: "MIDWAY", view: view, graph: graph)
            )
        }
        #expect(analysis.declined == nil)
        #expect(
            analysis.reclaimable == [ReclaimableRelay(deviceCode: "REL_SPUR", system: "SPUR")],
            "prune really does offer SPUR up — the guard is not covering for a pinned relay"
        )
        #expect(
            hopLinks == ["SPUR"],
            "and SPUR really is MIDWAY's only way onto the mesh — SOL is 8.6 ly away"
        )

        let decision = await tick(database, uuid: .incrementing)
        let row = try await launchedRun(database, decision)

        #expect(row.targets == ["MIDWAY"], "grow's chain exits the mesh at SPUR, so the hop is MIDWAY")
        #expect(
            row.sourceRelayCode == nil,
            "REL_SPUR is 5 ly away and spare, but it is the only thing MIDWAY can link to — print"
        )
    }

    // MARK: - What the tick TELLS the operator

    /// The why-view's feed (`brain-robustness-bar` clause 8). Everything above
    /// asserts on the ROW the brain writes; this asserts on what it SAYS, which
    /// is a separate surface with its own way of being silently empty — `BrainWhy`
    /// renders prune out of `BrainReport.prune`, so a report that never carried
    /// it would leave the whole prune surface dark while every test above stayed
    /// green.
    @Test func theReportCarriesTheReclaimTakenAndTheSpareLeftStanding() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedReclaimWorld(db, spares: [.deadend, .outback])
        }

        let report = await tickReport(database, uuid: .incrementing)
        let prune = try #require(report.prune)

        #expect(prune.declined == nil)
        #expect(prune.reclaimed?.deviceCode == "R_A")
        #expect(prune.reclaimed?.fromSystem == "DEADEND")
        #expect(prune.reclaimed?.toSystem == "VEGA", "the plant site the relay is going to")
        #expect(prune.reclaimed.map { ($0.distanceLY * 100).rounded() / 100 } == 7.07)
        // OUTBACK's relay is spare too and was left where it stands — the
        // surfaced-calm half of clause 6, and the reclaimed one is NOT
        // double-counted here.
        #expect(prune.spare.map(\.deviceCode) == ["R_C"])
        #expect(prune.pinnedCount == 1, "REL_SOL carries the anchor's own road")
    }

    /// **The in-flight window, through the real seam.** A source relay stays
    /// deployed and `relaying` for the whole outbound leg of the run coming to
    /// fetch it, so `PrunePredicate` — stateless, and answering a question
    /// about the mesh rather than about the fleet's plans — keeps returning it
    /// as reclaimable for every one of the hundreds of ticks that takes. The
    /// report must not hand that to the why-view as an available relay, or
    /// prune's one action is described correctly for a single tick and
    /// misdescribed for the rest of its lifetime.
    ///
    /// One world exercising all three partitions at once: `R_B` (PROXIMA) is
    /// already being fetched by a run in force, so this tick sources the next
    /// nearest (`R_A`, DEADEND) and `R_C` (OUTBACK, 40 ly out) is left genuinely
    /// spare. `inFlightSources` is the SAME authority the sourcing side uses,
    /// which is why the two halves cannot disagree about who owns `R_B`.
    @Test func aRelayAnotherRunIsFetchingIsReportedAsClaimedNotSpare() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedReclaimWorld(
                db, carriers: ["V1", "V2"], hosts: ["V1", "V2"],
                spares: [.deadend, .proxima, .outback]
            )
            try seedRelayRun(
                db, id: "AAA-in-force", deviceCode: "V2", targets: ["ALTAIR"], sourceRelayCode: "R_B"
            )
        }

        let report = await tickReport(database, uuid: .incrementing)
        let prune = try #require(report.prune)

        // The premise: prune itself still offers all three up. If it did not,
        // this test would pass without the partition doing any work.
        let analysis = try await database.read { db -> PruneAnalysis in
            let view = try WorldView.read(from: db, now: tickTime)
            return PrunePredicate.analyse(view: view, graph: MeshGraph(positions: view.starPositions))
        }
        #expect(analysis.reclaimable.map(\.deviceCode) == ["R_A", "R_B", "R_C"])

        #expect(prune.reclaimed?.deviceCode == "R_A", "R_B is spoken for, so DEADEND is the nearest free spare")
        #expect(
            prune.claimed.map(\.deviceCode) == ["R_B"],
            "the run in force is already flying to collect R_B"
        )
        #expect(
            prune.spare.map(\.deviceCode) == ["R_C"],
            "and only OUTBACK's relay is genuinely available to the next grow"
        )
    }

    /// The report is not a launch-only surface. A tick that reclaimed nothing
    /// must still say what prune saw, or an operator only ever learns the shape
    /// of their mesh on the ticks that change it — and "a spare relay sitting
    /// there" is precisely the fact that has no other surface.
    @Test func anIdleTickStillReportsWhatPruneSaw() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            // No carrier at the hub, so the tick idles rather than launching.
            try seedReclaimWorld(db, carriers: [], hosts: [], spares: [.deadend, .outback])
        }

        let report = await tickReport(database, uuid: .incrementing)
        #expect(report.decision == .idle(reason: "no free carrier at \(growHubLocation)"))

        let prune = try #require(report.prune)
        #expect(prune.declined == nil)
        #expect(prune.reclaimed == nil)
        #expect(prune.spare.map(\.deviceCode) == ["R_A", "R_C"])
    }

    /// A tick that CHOSE a reclaim and then deferred must not report one. The
    /// note an operator reads is a statement about what HAPPENED — the relay is
    /// still standing exactly where it was — and the same discipline that makes
    /// a failed write degrade to `.idle` rather than `.dispatch` applies to the
    /// prune half of the report.
    @Test func aDeferredLaunchReportsNoReclaim() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedReclaimWorld(db, spares: [.deadend])
        }

        let report = await tickReport(
            database, uuid: .incrementing,
            // The authoritative confirm-read does not land, so the launch defers.
            refresher: DeviceRefreshClient { _, _ in nil }
        )
        #expect(report.decision.isDeferral, "got \(report.decision)")

        let prune = try #require(report.prune)
        #expect(prune.reclaimed == nil, "nothing was reclaimed — nothing launched")
        #expect(prune.spare.map(\.deviceCode) == ["R_A"], "and the spare is still standing")
    }

    /// A world prune cannot judge reports the REFUSAL, not an empty spare list.
    /// The two are byte-identical in `PruneAnalysis.reclaimable`, which is the
    /// whole reason `declined` exists — and the report has to carry it through
    /// or the why-view is back to guessing.
    @Test func aDeclinedAnalysisReachesTheReportAsADecline() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedReclaimWorld(db, spares: [.deadend])
            // A meshed system the census cannot place — the same hole
            // `declinedPruneAnalysisSourcesAPrintRatherThanAGuess` drills.
            try seedRelay(db, code: "R_GHOST", location: "GHOST-1")
        }

        let report = await tickReport(database, uuid: .incrementing)
        let prune = try #require(report.prune)

        #expect(prune.declined == .censusIncomplete(systems: ["GHOST"]))
        #expect(prune.spare.isEmpty, "a refusal offers nothing up")
        #expect(prune.reclaimed == nil)
    }
}
