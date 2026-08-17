//
//  BrainGrowTests.swift
//  Replicould — DirectiveEngine
//
//  Task 16: the brain stops observing and starts acting. A tick that finds
//  unmeshed value, a print hub on the mesh, and a free carrier LAUNCHES a
//  Relay Run — the first row the brain has ever written.
//
//  The suites below split along the seam that matters:
//
//  - "Brain — grow launch" drives the REAL seam (`DirectiveEngineCore
//    .tickBrain()`, or the `Brain.evaluateOnce()` its body is one line of)
//    against a real `GameDatabase`, and asserts on rows. Nothing here is a
//    fixture stand-in for the engine.
//  - "Brain — reserved devices" exercises the reservation rules as the pure
//    function they are. Three of the four rules (`deviceCode`,
//    `controllerCode`, `fleetTag`) are ALSO proven end-to-end below, because
//    a reservation nobody consumes is worthless; the fourth (transitive
//    stow) cannot be, since stowing clears `location` and a carrier with no
//    location is already filtered out by co-location before reservation is
//    ever consulted — so it is proven at the unit level only, and the launch
//    tests say so where it matters.
//
//  On `TestClock`: the task brief's sketch drove `engine.start()` +
//  `clock.advance`. `BrainLoopTests.theTimerLoopItselfTicksOnSchedule`
//  already records — empirically, with the run-to-run tick counts to show
//  for it — that advancing `TestClock` past the brain loop's real database
//  read is not reproducible. So the ticks here are driven directly, exactly
//  as `BrainLoopTests.manualTicksWriteNothingAndCountExactly` drives them:
//  `tickBrain()` IS the loop body, and the loop's wiring to the clock is
//  that file's job, already proven, not re-proven flakily here.
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

/// **`uuid` is threaded explicitly, and neither helper defaults it, on
/// purpose.** `UUIDGenerator.incrementing` is a COMPUTED property: every
/// access constructs a fresh generator starting again at
/// `00000000-0000-0000-0000-000000000000`. A helper that re-entered
/// `withDependencies { $0.uuid = .incrementing }` per call would therefore
/// mint the same id on every tick — and since `directives.id` is a `TEXT
/// PRIMARY KEY`, a genuine second launch would hit a constraint failure,
/// land in `Brain`'s catch, and return `.idle(reason: "launch failed")` with
/// the row count unchanged. Every "did not double-launch" assertion in this
/// file would then be incapable of failing no matter which guard was removed
/// (review found exactly that). One generator per TEST, shared across its
/// ticks, is what makes a second launch produce a second row.
///
/// **On `deviceRefresher`.** Every launch here has to clear Task 18's confirm
/// -fresh gate, which spends a `.high` confirm-read on the carrier immediately
/// before committing. `confirmingRefresher` answers from the local fleet table
/// — the "nothing moved between ranking and the commit" world, which is what
/// every test in this file already means when it says the carrier was free.
/// What happens when that answer comes back different (or not at all) is
/// `BrainConfirmFreshTests`' subject, not this file's.
private func tick(_ database: any DatabaseWriter, core: DirectiveEngineCore, uuid: UUIDGenerator) async {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(tickTime)
        $0.uuid = uuid
        $0.deviceRefresher = confirmingRefresher(database)
    } operation: {
        await core.tickBrain()
    }
}

/// Drive one brain tick and keep its decision — the same call `tickBrain()`
/// makes, one layer down, for the assertions that are about WHY a tick did
/// what it did rather than about the row it wrote. See `tick` on `uuid`.
private func decide(_ database: any DatabaseWriter, uuid: UUIDGenerator) async -> BrainDecision {
    await withDependencies {
        $0.defaultDatabase = database
        $0.date = .constant(tickTime)
        $0.uuid = uuid
        $0.deviceRefresher = confirmingRefresher(database)
    } operation: {
        await Brain(now: tickTime).evaluateOnce()
    }
}

/// Row counts for every table a tick could conceivably have written, read in
/// ONE transaction so the assertions describe a single consistent moment.
private struct Counts: Sendable {
    let directives: Int
    let logEntries: Int
    let operations: Int
    let assays: Int
}

private func relayRuns(_ database: any DatabaseWriter) async throws -> [Directive] {
    try await database.read { db in
        try Directive.where { $0.kind.eq(DirectiveKind.relayRun) }.order { $0.id }.fetchAll(db)
    }
}

@Suite("Brain — grow launch")
struct BrainGrowTests {
    /// The headline: a world with a meshed hub, a free carrier, and a one-hop
    /// salvage target produces a `.running` Relay Run aimed at that system —
    /// and a second tick does not launch a second one.
    ///
    /// Every field of the launched row is asserted, not just its existence:
    /// the row IS the interface to `RelayRun`, and a run launched on the
    /// wrong step (or with a `sourceRelayCode` set, which would send
    /// `acquire` down its unbuilt reclaim branch and wait forever) is a
    /// silent no-op that "a relayRun row exists" would happily pass.
    ///
    /// The no-double-launch half is deliberately NOT the reservation proof —
    /// with one candidate in the world, the in-flight-target guard would
    /// explain it just as well. `aRunningRunReservesItsCarrierEvenForADifferentTarget`
    /// below isolates reservation itself.
    @Test func brainLaunchesRelayRunForTheTopGrowCandidate() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db) }
        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))

        await tick(database, core: core, uuid: uuid)

        let launched = try await relayRuns(database)
        #expect(launched.count == 1)
        let row = try #require(launched.first)
        #expect(row.status == .running)
        #expect(row.deviceCode == "V1")
        #expect(row.targets == ["VEGA"])
        #expect(row.targetIndex == 0)
        #expect(
            row.sourceRelayCode == nil,
            "nothing in this world is reclaimable and no replicant rides in V1 — so this grow prints"
        )
        #expect(row.step == RelayRun().firstStep)
        #expect(row.controllerCode == nil)
        #expect(row.fleetTag == nil, "ownership is the carrier alone — a Relay Run leases no fleet")
        #expect(row.roamCentre == nil, "a Relay Run is one-shot; a roam centre would ask it to extend its queue")
        #expect(row.returnToOrigin, "the carrier comes home so the next run can use it")
        #expect(row.originDesignation == "SOL")
        #expect(row.attentionReason == nil)
        #expect(row.stepStartedAt == tickTime)
        #expect(row.createdAt == tickTime)

        await tick(database, core: core, uuid: uuid)

        let afterSecondTick = try await relayRuns(database)
        #expect(afterSecondTick.count == 1, "a second tick must not double-launch")
        #expect(afterSecondTick.first?.id == row.id, "and must not replace the row it already wrote")
    }

    /// The reservation proof. Two equidistant salvage systems, ONE carrier:
    /// tick one launches at the richer (VEGA), and tick two finds ALTAIR
    /// entirely unclaimed and still launches nothing — because the only
    /// carrier is now owned by a running directive.
    ///
    /// This is what the headline test's second tick cannot show. Here the
    /// in-flight-target guard is provably not the cause: ALTAIR is not any
    /// run's target, and the decision names the carrier as the reason. Delete
    /// the reservation from `Brain.plan` and this test launches a second
    /// Relay Run on V1 — verified by mutation, not assumed.
    @Test func aRunningRunReservesItsCarrierEvenForADifferentTarget() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in
            try seedGrowableWorld(db, carriers: ["V1"], salvage: ["VEGA": 3_200, "ALTAIR": 100])
        }

        let first = await decide(database, uuid: uuid)
        guard case let .dispatch(goal, ranked) = first else {
            Issue.record("expected a dispatch, got \(first)")
            return
        }
        #expect(goal.kind == .tendMesh)
        #expect(goal.target == "VEGA", "equidistant candidates tie through the cheapest-chain fields, so magnitude decides")
        #expect(ranked.map(\.firstHop) == ["VEGA", "ALTAIR"], "the whole ranked field rides along for the why-view")

        let second = await decide(database, uuid: uuid)
        #expect(
            second == .idle(
                reason: """
                    no free carrier at SOL-3 — V1 is held by relay run \
                    00000000-0000-0000-0000-000000000000 (running)
                    """
            ),
            "ALTAIR is unclaimed and still ranked — only the carrier being reserved can stop this tick"
        )
        #expect(try await relayRuns(database).count == 1)
    }

    /// The other half of the same coin: a spare carrier does NOT license a
    /// second run at a system a run is already flying to. Two carriers, one
    /// value system — the first tick takes V1, and the second finds V2 free
    /// but every candidate already in flight.
    ///
    /// Without this guard the brain would print a second relay (370 units,
    /// ~800 s) for a hop it is already meshing, every tick until the first
    /// run lands. Delete the in-flight-target filter and this test sees two
    /// rows.
    @Test func anInFlightTargetIsNotLaunchedTwiceEvenWithASpareCarrier() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in
            try seedGrowableWorld(db, carriers: ["V1", "V2"], salvage: ["VEGA": 3_200])
        }

        let first = await decide(database, uuid: uuid)
        guard case .dispatch = first else {
            Issue.record("expected a dispatch, got \(first)")
            return
        }

        let second = await decide(database, uuid: uuid)
        #expect(second == .idle(reason: "every grow candidate is already in flight"))
        let launched = try await relayRuns(database)
        #expect(launched.count == 1)
        #expect(launched.first?.deviceCode == "V1", "the spare carrier must be left alone, not handed the same target")
    }

    /// A carrier another run names as its CONTROLLER is not free either.
    /// Reservation is over device CODES, whichever column names them — a
    /// directive driving V1 as its controller is as much its owner as one
    /// carrying it as its `deviceCode`.
    @Test func aCarrierNamedAsAnotherRunsControllerIsNotFree() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in
            try seedGrowableWorld(db)
            try seedDirective(db, id: "OTHER", deviceCode: "SOMEVESSEL", controllerCode: "V1")
        }

        #expect(
            await decide(database, uuid: uuid)
                == .idle(reason: "no free carrier at SOL-3 — V1 is held by salvage run OTHER (running)")
        )
        #expect(try await relayRuns(database).isEmpty)
    }

    /// …and so is a carrier wearing a running run's fleet tag. A tag is how a
    /// Haul Run names its whole working set, so a device carrying it is
    /// already committed even though no column points at it.
    @Test func aCarrierCarryingARunningRunsFleetTagIsNotFree() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [])
            // BOTH tags: `auto:tendMesh` is what makes V1 a carrier the brain
            // would otherwise fly, which is the only way this test can prove the
            // fleet-tag reservation is what stops it. Tagged for tendMesh alone
            // it would be free; tagged for haul alone it would never be a
            // candidate, and the assertion would pass for the wrong reason.
            try seedDevice(db, code: "V1", location: growHubLocation, tags: ["auto:haul", Brain.carrierTag.string])
            try seedDirective(db, id: "HAUL", kind: .haulRun, deviceCode: "SOMEVESSEL", fleetTag: "auto:haul")
        }

        #expect(
            await decide(database, uuid: uuid)
                == .idle(reason: "no free carrier at SOL-3 — V1 is held by haul run HAUL (running)")
        )
        #expect(try await relayRuns(database).isEmpty)
    }

    /// **A hull holding another run's cargo is not free.** V1 is named by no
    /// directive at all — right type, at the hub, idle — but a running Salvage
    /// Run owns `KIT`, and `KIT` is stowed inside V1. Flying V1 away takes
    /// somebody else's device with it, which is the bounded-blast-radius
    /// clause, so V1 must not be picked.
    ///
    /// This is the gap review found: a downward-only stow walk returns
    /// `{KIT}` and leaves the hull around it allocatable. The shape is normal
    /// in this codebase — `reservesTheControllerAndEveryDeviceWearingTheFleetTag`
    /// seeds a stowed tagged device for the same reason.
    @Test func aVesselHoldingAnotherRunsDeviceIsNotFree() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in
            try seedGrowableWorld(db)
            try seedDevice(db, code: "KIT", type: "mining_drone", stowedIn: "V1")
            try seedDirective(db, id: "SALVAGE", deviceCode: "KIT")
        }

        // The sentence names the run that actually owns the hull — reached
        // through the upward stow edge, not through any column pointing at V1.
        #expect(
            await decide(database, uuid: uuid)
                == .idle(reason: "no free carrier at SOL-3 — V1 is held by salvage run SALVAGE (running)")
        )
        #expect(try await relayRuns(database).isEmpty)
    }

    /// A finished run holds nothing. The mirror of the tests above: the same
    /// world, the same directive naming V1 — but `.completed`, so the carrier
    /// is free and the launch goes ahead. Without this, every "reserved →
    /// idle" test above would still pass if `owningStatuses` were widened to
    /// every status, which would freeze the brain permanently after one run.
    @Test func aCompletedRunReleasesItsCarrier() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in
            try seedGrowableWorld(db)
            try seedDirective(db, id: "DONE", status: .completed, deviceCode: "V1")
        }

        guard case let .dispatch(goal, _) = await decide(database, uuid: uuid) else {
            Issue.record("a completed run must not reserve its carrier")
            return
        }
        #expect(goal.target == "VEGA")
        #expect(try await relayRuns(database).count == 1)
    }

    /// The sketch's first arm, filled: no unmeshed value at all. A mesh, a
    /// hub, and an idle carrier — everything a launch needs except something
    /// worth reaching — and the tick idles, writing nothing.
    @Test func idlesWhenThereIsNoUnmeshedValue() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db, salvage: [:]) }

        #expect(await decide(database, uuid: uuid) == .idle(reason: "no grow or prune work"))
        #expect(try await relayRuns(database).isEmpty)
    }

    /// The sketch's second arm, filled: value in reach and no carrier to send.
    /// The hub is there, the salvage is there, the chain is one hop — and the
    /// brain idles rather than launching a run against a device that does not
    /// exist.
    @Test func idlesWhenValueIsInReachButNoCarrierIsFree() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db, carriers: []) }

        #expect(await decide(database, uuid: uuid) == .idle(reason: "no free carrier at SOL-3"))
        #expect(try await relayRuns(database).isEmpty)
    }

    /// A carrier mid-errand is not a free carrier. `status: "travelling"`
    /// belongs to no directive, so reservation cannot see it — but launching
    /// onto a vessel that is already flying somewhere would have `RelayRun`
    /// print a relay at a hub the carrier is leaving.
    @Test func aBusyCarrierIsNotFree() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [])
            try seedDevice(db, code: "V1", location: growHubLocation, status: "travelling")
        }

        #expect(
            await decide(database, uuid: uuid)
                == .idle(reason: "no free carrier at SOL-3 — V1 is travelling")
        )
        #expect(try await relayRuns(database).isEmpty)
    }

    /// A carrier that is not standing WITH the print hub is not a carrier for
    /// this composition. `RelayRun.acquire` requires a print-capable device at
    /// the carrier's own location — the clone materialises at the printer —
    /// so launching one elsewhere would stall `unreachableDevice` on its first
    /// evaluation.
    @Test func aCarrierParkedAwayFromTheHubIsNotFree() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in
            try seedGrowableWorld(db, carriers: [])
            try seedDevice(db, code: "V1", location: "SOL-4")
        }

        #expect(await decide(database, uuid: uuid) == .idle(reason: "no free carrier at SOL-3"))
        #expect(try await relayRuns(database).isEmpty)
    }

    /// No print hub at all — the relay has nowhere to come from, so there is
    /// nothing to launch however rich the target. (An off-mesh hub reads the
    /// same way: no theatre is recognised unless the hub's system is meshed.)
    @Test func idlesWithNoPrintHubOnTheMesh() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in
            try seedGrowableWorld(db)
            try Device.delete().where { $0.deviceCode.eq("HUB1") }.execute(db)
        }

        #expect(await decide(database, uuid: uuid) == .idle(reason: "no operational theatre"))
        #expect(try await relayRuns(database).isEmpty)
    }

    /// An idling brain writes NOTHING, in any table it could reach — not just
    /// `directives`. The brain's whole safety case is that it is a pure
    /// selector with two permitted writes, so this asserts across every table
    /// `WorldView.read` touches plus the two the executor owns: a row-for-row
    /// device comparison (a stray `updatedAt` stamp would fail it), and
    /// emptiness for the tables a launch or a mission step would have written.
    @Test func anIdlingBrainWritesNothingAtAll() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db, salvage: [:]) }
        let devicesBefore = try await database.read { db in try Device.all.order { $0.deviceCode }.fetchAll(db) }
        let starsBefore = try await database.read { db in try Star.all.order { $0.designation }.fetchAll(db) }

        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        await tick(database, core: core, uuid: uuid)
        await tick(database, core: core, uuid: uuid)

        let counts = try await database.read { db in
            Counts(
                directives: try Directive.all.fetchCount(db),
                logEntries: try DirectiveLogEntry.all.fetchCount(db),
                operations: try Operation.all.fetchCount(db),
                assays: try SiteAssay.all.fetchCount(db)
            )
        }
        #expect(counts.directives == 0, "an idling brain must create no directive")
        #expect(counts.logEntries == 0, "…and no timeline entry")
        #expect(counts.operations == 0, "…and dispatch no command")
        #expect(counts.assays == 0, "…and invent no value row")
        let devicesAfter = try await database.read { db in try Device.all.order { $0.deviceCode }.fetchAll(db) }
        #expect(devicesAfter == devicesBefore, "an idling brain must not touch a device row it read")
        let starsAfter = try await database.read { db in try Star.all.order { $0.designation }.fetchAll(db) }
        #expect(starsAfter == starsBefore, "…nor a census row")
    }

    /// A launching brain writes exactly ONE row and nothing else. The
    /// complement of the test above: creating a directive is a permitted
    /// write, hand-editing devices or back-dating a timeline is not, and the
    /// brain must not do the executor's job on the way past.
    @Test func aLaunchingBrainWritesTheDirectiveRowAndNothingElse() async throws {
        let database = try GameDatabase.bootstrap()
        let uuid = UUIDGenerator.incrementing
        try await database.write { db in try seedGrowableWorld(db) }
        let devicesBefore = try await database.read { db in try Device.all.order { $0.deviceCode }.fetchAll(db) }
        let assaysBefore = try await database.read { db in try SiteAssay.all.order { $0.id }.fetchAll(db) }
        let starsBefore = try await database.read { db in try Star.all.order { $0.designation }.fetchAll(db) }

        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        await tick(database, core: core, uuid: uuid)

        let counts = try await database.read { db in
            Counts(
                directives: try Directive.all.fetchCount(db),
                logEntries: try DirectiveLogEntry.all.fetchCount(db),
                operations: try Operation.all.fetchCount(db),
                assays: try SiteAssay.all.fetchCount(db)
            )
        }
        #expect(counts.directives == 1)
        #expect(counts.logEntries == 0, "the timeline is the executor's to write, not the brain's")
        #expect(counts.operations == 0, "the brain never commands a device — only the executor does")
        // The wider net matters MORE on this path than on the idle one: this
        // is the tick that actually writes, so it is the tick that could write
        // something extra.
        #expect(counts.assays == 1, "…and must not consume, deplete, or invent a value row")
        let devicesAfter = try await database.read { db in try Device.all.order { $0.deviceCode }.fetchAll(db) }
        #expect(devicesAfter == devicesBefore, "launching must not stamp anything onto the carrier")
        let assaysAfter = try await database.read { db in try SiteAssay.all.order { $0.id }.fetchAll(db) }
        #expect(assaysAfter == assaysBefore, "…row-for-row, not merely the same count")
        let starsAfter = try await database.read { db in try Star.all.order { $0.designation }.fetchAll(db) }
        #expect(starsAfter == starsBefore, "…nor a census row")
    }
}

@Suite("Brain — reserved devices")
struct BrainReservationTests {
    private func fleet(_ devices: [Device]) -> [String: Device] {
        Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Rules 1 and 2: the mission's carrier, and everything transitively
    /// stowed inside it — a controller aboard the vessel, and a drone aboard
    /// THAT controller. The two-level nesting is the point: a one-level walk
    /// would reserve the controller and leave the drone allocatable, which is
    /// exactly how a staged mining kit gets taken apart mid-mission.
    ///
    /// This rule is unreachable through the launch seam — stowing clears
    /// `location`, so a transitively-stowed device is filtered out by
    /// co-location before reservation is ever consulted — so it is proven
    /// here, where it can be.
    @Test func reservesTheCarrierAndEverythingTransitivelyStowedInside() {
        let devices = fleet([
            deviceFixture(code: "V1", location: "SOL-3"),
            deviceFixture(code: "CTRL", type: "ami_controller", stowedIn: "V1"),
            deviceFixture(code: "DRONE", type: "survey_drone", stowedIn: "CTRL"),
            deviceFixture(code: "FREE", location: "SOL-3"),
            deviceFixture(code: "ELSEWHERE", type: "survey_drone", stowedIn: "OTHERVESSEL"),
        ])
        let reserved = Brain.reservedDevices(
            directives: [directiveFixture(id: "D1", deviceCode: "V1")], devices: devices
        )
        #expect(reserved == ["V1", "CTRL", "DRONE"])
    }

    /// The UPWARD closure: an owned device reserves the hull it rides in, and
    /// (through the downward edge, from that hull) everything else aboard it.
    ///
    /// `V` is named by no directive; only `X` inside it is owned. A
    /// downward-only walk returns `{X}`, leaving `V` allocatable — which is
    /// exactly how a Relay Run would fly away with another mission's device in
    /// the hold. `SIBLING` proves the closure keeps going rather than stopping
    /// at the hull: whatever `V` carries goes where `V` goes.
    @Test func anOwnedDeviceReservesTheHullItRidesInAndItsOtherCargo() {
        let devices = fleet([
            deviceFixture(code: "V", location: "SOL-3"),
            deviceFixture(code: "X", type: "mining_drone", stowedIn: "V"),
            deviceFixture(code: "SIBLING", type: "survey_drone", stowedIn: "V"),
            deviceFixture(code: "UNRELATED", location: "SOL-3"),
        ])
        let reserved = Brain.reservedDevices(
            directives: [directiveFixture(id: "D1", deviceCode: "X")], devices: devices
        )
        #expect(reserved == ["X", "V", "SIBLING"])
    }

    /// Adoption, read from BOTH ends — the shape `AMIFleet.adoptedDrones`
    /// already uses, and for the recorded reason: `controlled_devices` ships
    /// only in the single-device payload and a routine fleet sync erases it
    /// (`controlled-devices-detail-only`), so the drone's own
    /// `controllerDeviceCode` column is the reliable end and the controller's
    /// list is the bonus. A DEPLOYED drone (stowed nowhere, so invisible to
    /// the stow walk) adopted by a reserved controller is still owned.
    @Test func aReservedControllerReservesTheDronesItHasAdopted() {
        var controller = deviceFixture(code: "AMI1", type: "ami_controller", location: "SOL-3")
        controller.detail = .object(["controlled_devices": .array([.object(["device_code": .string("BLOB-ONLY")])])])
        let devices = fleet([
            deviceFixture(code: "V1", location: "SOL-3"),
            controller,
            deviceFixture(code: "DEPLOYED", type: "survey_drone", location: "SOL-3-1"),
            deviceFixture(code: "BLOB-ONLY", type: "survey_drone", location: "SOL-3-2"),
            deviceFixture(code: "SOMEONE-ELSES", type: "survey_drone", location: "SOL-3-3"),
        ])
        // The column end, which is the one that survives a fleet sync.
        var adopted = devices["DEPLOYED"]!
        adopted.controllerDeviceCode = "AMI1"
        var byCode = devices
        byCode["DEPLOYED"] = adopted

        let reserved = Brain.reservedDevices(
            directives: [directiveFixture(id: "D1", deviceCode: "V1", controllerCode: "AMI1")],
            devices: byCode
        )
        #expect(reserved == ["V1", "AMI1", "DEPLOYED", "BLOB-ONLY"])
    }

    /// Rules 3 and 4: the controller the mission drives, and every device
    /// wearing its fleet tag — including one that is stowed (which is the
    /// whole reason a Haul Run resolves its working set by tag rather than by
    /// location).
    @Test func reservesTheControllerAndEveryDeviceWearingTheFleetTag() {
        let devices = fleet([
            deviceFixture(code: "V1", location: "SOL-3"),
            deviceFixture(code: "AMI1", type: "ami_controller", location: "SOL-3"),
            deviceFixture(code: "HAULER", type: "transport_drone", tags: ["auto:haul"]),
            deviceFixture(code: "STOWED-HAULER", type: "transport_drone", tags: ["auto:haul"], stowedIn: "SOMEWHERE"),
            deviceFixture(code: "UNTAGGED", type: "transport_drone", tags: ["auto:salvage"]),
        ])
        let reserved = Brain.reservedDevices(
            directives: [
                directiveFixture(id: "D1", deviceCode: "V1", controllerCode: "AMI1", fleetTag: "auto:haul"),
            ],
            devices: devices
        )
        #expect(reserved == ["V1", "AMI1", "HAULER", "STOWED-HAULER"])
    }

    /// Only an IN-FORCE directive owns anything. `paused` and `needsAttention`
    /// still do — the mission is halted, not finished, and its fleet is still
    /// staged where it left it — while `completed`/`cancelled` release
    /// everything. Both halves are asserted from one fleet so a rule that
    /// simply returned "everything" or "nothing" fails whichever half it got
    /// wrong.
    @Test func onlyInForceDirectivesReserveAnything() {
        let devices = fleet(["PAUSED", "STALLED", "RUNNING", "DONE", "CANCELLED"].map {
            deviceFixture(code: $0, location: "SOL-3")
        })
        let reserved = Brain.reservedDevices(
            directives: [
                directiveFixture(id: "P", status: .paused, deviceCode: "PAUSED"),
                directiveFixture(id: "S", status: .needsAttention, deviceCode: "STALLED"),
                directiveFixture(id: "R", status: .running, deviceCode: "RUNNING"),
                directiveFixture(id: "C", status: .completed, deviceCode: "DONE"),
                directiveFixture(id: "X", status: .cancelled, deviceCode: "CANCELLED"),
            ],
            devices: devices
        )
        #expect(reserved == ["PAUSED", "STALLED", "RUNNING"])
    }

    /// A stow cycle — impossible in a healthy fleet, arbitrarily possible in
    /// rows synced from a server we do not control — must terminate. The walk
    /// only re-enters a code it has never reserved, so a cycle closes rather
    /// than looping; without that guard this test hangs the whole suite rather
    /// than failing, which is precisely why it is worth having.
    @Test func aCorruptStowCycleTerminates() {
        let devices = fleet([
            deviceFixture(code: "A", stowedIn: "B"),
            deviceFixture(code: "B", stowedIn: "A"),
        ])
        let reserved = Brain.reservedDevices(
            directives: [directiveFixture(id: "D1", deviceCode: "A")], devices: devices
        )
        #expect(reserved == ["A", "B"])
    }

    /// No directives at all reserves nothing — the state the brain starts
    /// life in, and the one every launch test above depends on.
    @Test func anEmptyLedgerReservesNothing() {
        #expect(
            Brain.reservedDevices(
                directives: [], devices: fleet([deviceFixture(code: "V1", location: "SOL-3")])
            ).isEmpty
        )
    }
}

@Suite("Brain — the launch rationale")
struct BrainRationaleTests {
    private func candidate(
        firstHop: String = "VEGA",
        tier: ValueTier = .salvage,
        magnitude: Double = 3_200,
        relaysRemaining: Int = 1,
        served: [String] = ["VEGA"]
    ) -> GrowCandidate {
        GrowCandidate(
            firstHop: firstHop, completesNow: relaysRemaining == 1,
            relaysRemaining: relaysRemaining, bestTier: tier, magnitudeAtTier: magnitude,
            hopDistance: 5, servedTargets: served, designation: firstHop
        )
    }

    /// The brief's own example, verbatim. A rationale must be a graph fact a
    /// human can check against the map — never a score.
    @Test func namesTheSystemTheMagnitudeAndTheHopCount() {
        #expect(Brain.rationale(for: candidate()) == "meshing VEGA — 3,200 units, 1 hop")
    }

    /// A hop planted for value somewhere else says where the value is, since
    /// "meshing POLARISUM" alone would look like a hop toward nothing.
    @Test func namesTheServedSystemWhenTheValueIsBeyondTheHop() {
        let multi = candidate(
            firstHop: "POLARISUM", tier: .event, magnitude: 1, relaysRemaining: 2, served: ["VEGA"]
        )
        #expect(Brain.rationale(for: multi) == "meshing POLARISUM — 1 live event at VEGA, 2 hops")
    }

    /// Each tier reports its own kind of magnitude — belts as belts, events as
    /// events — because "3 units" for a belt count would be a lie the operator
    /// could not check.
    @Test func eachTierNamesItsOwnMagnitude() {
        #expect(Brain.rationale(for: candidate(tier: .richBelt, magnitude: 2)).contains("2 rich belts"))
        #expect(Brain.rationale(for: candidate(tier: .moderateBelt, magnitude: 1)).contains("1 moderate belt"))
        #expect(Brain.rationale(for: candidate(tier: .sparseBelt, magnitude: 3)).contains("3 sparse belts"))
        #expect(Brain.rationale(for: candidate(tier: .event, magnitude: 2)).contains("2 live events"))
    }

    /// A hop serving a crowd names the first two and counts the rest, rather
    /// than growing a log line without bound.
    @Test func aCrowdedHopNamesTheFirstTwoAndCountsTheRest() {
        let crowded = candidate(relaysRemaining: 2, served: ["ALTAIR", "RIGEL", "SIRIUS", "TAU"])
        #expect(Brain.rationale(for: crowded) == "meshing VEGA — 3,200 units at ALTAIR, RIGEL +2 more, 2 hops")
    }

    /// A nonsense magnitude renders as nonsense rather than TRAPPING. `Int(_:
    /// Double)` traps on NaN and on anything past `Int.max`, this number is
    /// summed from server-supplied assay totals, and the call site is a
    /// 5-second background loop — so the failure mode being guarded is the
    /// whole process dying over a log line, which no test could catch after
    /// the fact.
    @Test func anImpossibleMagnitudeDoesNotTrap() {
        #expect(Brain.rationale(for: candidate(magnitude: .nan)).contains("units"))
        #expect(Brain.rationale(for: candidate(magnitude: .infinity)).contains("units"))
        #expect(Brain.rationale(for: candidate(magnitude: 1e30)).contains("units"))
    }
}

@Suite("Brain — why there is no free carrier")
struct BrainCarrierBlockerTests {
    /// **The clause-6 pair, and the reason this function exists.** A carrier
    /// held for three minutes by a healthy run and a carrier held FOREVER by a
    /// stalled mission the brain may not touch used to produce one identical
    /// sentence — "no free carrier at SOL-3" — rendered identically as calm.
    /// The two worlds here differ in exactly one field, the holder's status,
    /// and the gate an operator reads must not be the same string.
    ///
    /// The second world is the live fleet's, in shape: the only
    /// `heaven_vessel` at the print hub is owned by a `salvageRun` sitting in
    /// `.needsAttention` on `awaitingRelayRestock` — waiting for a relay that
    /// only a grow could supply, while holding the carrier that grow needs.
    ///
    /// A healthy holder reads as a calm wait; a halted one the brain escalates
    /// reads as a named escalation. The two must never render alike.
    @Test func aStalledHolderReadsDifferentlyFromAHealthyOne() async throws {
        let healthy = try await gateWithHolder(status: .running, reason: nil)
        let stalled = try await gateWithHolder(status: .needsAttention, reason: .awaitingRelayRestock)

        #expect(healthy == .idle(reason: "no free carrier at SOL-3 — V1 is held by salvage run HOLD (running)"))
        #expect(stalled == .stall(.awaitingRelayRestock))
        #expect(healthy != stalled, "an indefinite growth halt must not read as a three-minute wait")
    }

    /// A holder of a kind the brain does NOT manage still produces the sentence,
    /// and still carries the clause saying waiting will not clear it.
    @Test func anUnmanagedKindsStallStillNamesItselfUnresolvable() async throws {
        let held = try await gateWithHolder(
            status: .needsAttention, reason: .noSurveyControllerAboard, kind: .surveyRun
        )
        #expect(
            held == .idle(
                reason: """
                    no free carrier at SOL-3 — V1 is held by survey run HOLD \
                    (needs attention — No survey controller aboard, not the brain's to resolve)
                    """
            )
        )
    }

    /// A halted Relay Run is the brain's OWN, and the sentence must not tell an
    /// operator to go and fix something the stall-response layer is already
    /// working through. Same status, same reason, different kind — and the
    /// "not the brain's to resolve" clause is gone.
    @Test func aBrainManagedStallIsNotBlamedOnTheOperator() async throws {
        let held = try await gateWithHolder(
            status: .needsAttention, reason: .printStockShort, kind: .relayRun
        )
        #expect(
            held == .idle(
                reason: """
                    no free carrier at SOL-3 — V1 is held by relay run HOLD \
                    (needs attention — Resource stock too low to print)
                    """
            )
        )
    }

    /// A paused run holds its carrier for exactly as long as the operator
    /// leaves it paused, which is its own indefinite state and is named.
    @Test func aPausedHolderIsNamedAsPaused() async throws {
        let held = try await gateWithHolder(status: .paused, reason: nil)
        #expect(held == .idle(reason: "no free carrier at SOL-3 — V1 is held by salvage run HOLD (paused)"))
    }

    /// With no carrier standing at the hub there is no holder to name and no
    /// two states to tell apart, so the bare sentence stays the whole fact.
    /// This is the calm case, and it must not acquire a clause it cannot fill.
    @Test func noCandidateAtTheHubKeepsTheBareSentence() throws {
        #expect(
            Brain.carrierBlocker(at: "SOL-3", devices: [:], reserved: [], directives: [])
                == "no free carrier at SOL-3"
        )
    }

    /// Several blocked carriers are named two-at-a-time and the rest counted —
    /// the judgement `Brain.list` makes about served systems, for the same
    /// reason: an unbounded list in a one-line gate helps nobody.
    @Test func extraBlockedCarriersAreCountedNotListed() throws {
        let fleet = ["V1", "V2", "V3", "V4"].map {
            deviceFixture(code: $0, location: "SOL-3", status: "travelling")
        }
        #expect(
            Brain.carrierBlocker(
                at: "SOL-3",
                devices: Dictionary(fleet.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
                reserved: [],
                directives: []
            ) == "no free carrier at SOL-3 — V1 is travelling; V2 is travelling +2 more"
        )
    }

    /// One growable world with a single carrier the named directive owns.
    ///
    /// `retry` is a no-op stub rather than `unimplemented` because a
    /// brain-MANAGED stall is genuinely due one on its first tick — that is the
    /// whole difference these tests are about. The other four verbs stay
    /// `unimplemented`, so the operator-only rule is still armed here.
    private func gateWithHolder(
        status: DirectiveStatus,
        reason: DirectiveAttentionReason?,
        kind: DirectiveKind = .salvageRun
    ) async throws -> BrainDecision {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try seedGrowableWorld(db)
            var holder = directiveFixture(id: "HOLD", kind: kind, status: status, deviceCode: "V1")
            holder.attentionReason = reason
            try Directive.insert { holder }.execute(db)
        }
        var resolution = DirectiveResolutionClient.testValue
        resolution.retry = { _ in }
        return await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(tickTime)
            $0.uuid = .incrementing
            $0.deviceRefresher = confirmingRefresher(database)
            $0.directiveResolution = resolution
        } operation: {
            await Brain(now: tickTime).evaluateOnce()
        }
    }
}

private let growAcrossTheatresNow = Date(timeIntervalSince1970: 5_000)

/// Two theatres, each nearest a different one-hop grow candidate: `HUBX-1`
/// beside `CANDA` (3 ly from mesh source `SOL`), `HUBY-1` beside `CANDB` (6
/// ly) — so ranking orders `CANDA` first while each stays its own nearest theatre.
private func twoTheatreGrowView(
    carrierAtHubX: Device?, carrierAtHubY: Device?
) -> (view: WorldView, hubX: Theatre, hubY: Theatre) {
    let hubX = Theatre(depot: "HUBX-1", system: "HUBX", origin: .derived, readiness: .operational, stock: 0)
    let hubY = Theatre(depot: "HUBY-1", system: "HUBY", origin: .derived, readiness: .operational, stock: 0)
    let devices = [carrierAtHubX, carrierAtHubY].compactMap { $0 }
    let view = WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: [
            "SOL": Position(x: 0, y: 0, z: 0),
            "CANDA": Position(x: 3, y: 0, z: 0),
            "CANDB": Position(x: 6, y: 0, z: 0),
            "HUBX": Position(x: 3, y: 0, z: 1),
            "HUBY": Position(x: 6, y: 0, z: 1),
        ],
        meshSystems: ["SOL"],
        salvageUnits: ["CANDA": 500, "CANDB": 500],
        eventSystems: [],
        theatres: [hubX, hubY],
        now: growAcrossTheatresNow
    )
    return (view, hubX, hubY)
}

@Suite("Brain — grow walks past a blocked candidate")
struct BrainGrowFallthroughTests {
    /// Two candidates, the nearer's theatre carrier-less and the further's
    /// free. The pass must reach past the nearer's blocker to the candidate
    /// whose own theatre can actually send something.
    @Test func aBlockedNearerTheatreFallsThroughToAFurtherCandidate() {
        let (view, _, hubY) = twoTheatreGrowView(
            carrierAtHubX: nil,
            carrierAtHubY: deviceFixture(code: "VY", location: "HUBY-1")
        )

        guard case let .grow(goal, ranked, carrier, hub, origin, _, _) = Brain.plan(view: view, directives: []) else {
            Issue.record("expected a grow")
            return
        }
        #expect(ranked.map(\.firstHop) == ["CANDA", "CANDB"], "CANDA ranks first on hop distance alone")
        #expect(goal.target == "CANDB", "CANDA's own theatre has no carrier, so the pass reaches past it")
        #expect(carrier == "VY")
        #expect(hub == hubY.depot)
        #expect(origin == hubY.system)
    }

    /// Every candidate's theatre is carrier-less: idle names the FIRST
    /// blocked candidate's own `carrierBlocker` — a concrete holder, never a
    /// generic sentence that could describe any hub.
    @Test func allCandidatesCarrierLessIdlesWithTheFirstOnesBlocker() {
        let held = deviceFixture(code: "VX", location: "HUBX-1")
        let busy = deviceFixture(code: "VY", location: "HUBY-1", status: "travelling")
        let (view, hubX, _) = twoTheatreGrowView(carrierAtHubX: held, carrierAtHubY: busy)
        let directives = [directiveFixture(id: "RUN1", kind: .relayRun, status: .running, deviceCode: "VX")]

        let decision = Brain.plan(view: view, directives: directives)
        guard case let .idle(reason, ranked, _) = decision else {
            Issue.record("expected idle")
            return
        }
        #expect(ranked.map(\.firstHop) == ["CANDA", "CANDB"])
        #expect(reason == "no free carrier at \(hubX.depot) — VX is held by relay run RUN1 (running)")
    }

    /// No theatre resolves for EITHER candidate: the loop walks both
    /// no-theatre `continue`s without ever setting `blocked`, landing on the
    /// generic reason for the whole field, not just the first candidate.
    @Test func noTheatreAnywhereIdlesWithTheGenericReasonAcrossTheWholeField() {
        let (base, _, _) = twoTheatreGrowView(carrierAtHubX: nil, carrierAtHubY: nil)
        let view = WorldView(
            devices: base.devices, starPositions: base.starPositions, meshSystems: base.meshSystems,
            salvageUnits: base.salvageUnits, eventSystems: base.eventSystems, theatres: [],
            now: base.now
        )

        let decision = Brain.plan(view: view, directives: [])
        guard case let .idle(reason, ranked, _) = decision else {
            Issue.record("expected idle")
            return
        }
        #expect(ranked.map(\.firstHop) == ["CANDA", "CANDB"])
        #expect(reason == "no operational theatre")
    }
}
