//
//  BrainGrowLifecycleE2ETests.swift
//  Replicould — DirectiveEngine
//
//  Task 25: the whole grow lifecycle, driven through the REAL stack.
//
//  This is the gate the plan asks for by name. `SalvageTargetPlanner` once
//  shipped fully unit-green with ZERO production callers and nobody noticed,
//  and the lesson was written down as a rule: a pure-unit ranker test does not
//  satisfy the bar. So nothing above the command wire is stubbed here.
//
//  **Where the fake seam sits: at the network, and nowhere else.** Three
//  dependencies are scripted, and all three are things that would otherwise
//  reach replicant.space:
//
//    • `@Dependency(\.commandClient)` — the command wire (`ScriptedServer`),
//    • `@Dependency(\.locationsClient.footprint)` — the `GET /v1/locations`
//      read the reserve rail consults (the client's own persistence,
//      `refreshFootprint()`, is the real one),
//    • `@Dependency(\.deviceRefresher)` — the authoritative device read, via
//      `confirmingRefresher`, the same stand-in the rest of the brain suite
//      uses.
//
//  Everything above them is the production article:
//
//    • `Brain` (ranking, the confirm-fresh gate, the launch write),
//    • `DirectiveEngineCore.tickBrain()` / `.evaluateOnce(directiveID:)`
//      (the real plan loop body and the real per-directive executor, including
//      the four refresh resolvers and their re-ask bound),
//    • `MissionRegistry.machines` — the REGISTERED `RelayRun`, not a hand-built
//      one, so an unregistered machine fails this file,
//    • `DirectiveExecutor` (step moves, timeline entries, stalls),
//    • and the real `CommandGovernor`, via `CommandGovernorClient.liveValue` —
//      the actions-budget gate and the per-device in-flight claim both run.
//
//  `ScriptedServer` stands in for the server AND for the sync that folds its
//  answers back into SQLite: it records each command, applies that command's
//  real-world effect to the device rows, and keeps the `Operation` bookkeeping
//  `CommandClient` would have kept — which is where the `.simple`-verb
//  distinction lives. `travel`/`print` are TRACKED (an `Operation` row, open
//  until it completes); `stow`/`deploy`/`activate` are `.simple` and carry no
//  operation row at all, so the machine's split dispatch/poll steps are
//  exercised for real rather than papered over.
//
//  **On driving ticks.** `BrainLoopTests.theTimerLoopItselfTicksOnSchedule`
//  already records — empirically — that advancing `TestClock` past the brain
//  loop's real database read is not reproducible, and that the loop's wiring to
//  the clock is proven there instead. So ticks here are driven directly, the
//  same way `BrainGrowTests` drives them: one virtual 5-second step per
//  iteration, `tickBrain()` then one `evaluateOnce` per running row — the two
//  loops `start()` runs side by side. A `TestClock` is installed regardless so
//  nothing can sleep for real.
//

import API
import Dependencies
import Foundation
import GameDatabase
import GameModels
import GameServices
import GameSession
import Sharing
import SQLiteData
import Testing
import UniverseModels
import Utils

@testable import DirectiveEngine

// MARK: - The world

/// The tick the run starts on. Device rows are seeded AT this instant, not at
/// the epoch: `RelayRun.acquire` refuses to trust a hub row older than
/// `hubFreshness` (5 min), so an epoch-stamped fleet would spend the whole test
/// in a refresh-then-stall loop instead of printing.
private let liftoff = Date(timeIntervalSince1970: 1_000_000)

/// The engine's own cadence, and this file's virtual clock step.
private let tickSeconds: TimeInterval = 5

/// Where the autofactory and the carrier both stand — inside the meshed `SOL`
/// system, which is what makes `WorldView.hubLocation` non-nil.
private let hubLocation = "SOL-3"

/// The system this lifecycle meshes, and the poorer one behind it that proves
/// the brain re-ranks rather than merely stopping.
private let target = "VEGA"
private let runnerUp = "ALTAIR"

/// The code the hub's print names as the new relay — the clone `printing`
/// waits for. Numbered by print, because a world that prints twice must not
/// hand back the same device twice.
private func cloneCode(forPrint index: Int) -> String { "RLY900\(index)" }
private let firstClone = cloneCode(forPrint: 1)

/// The smallest world this lifecycle needs: `SOL` meshed by one live relay, an
/// autofactory and a HEAVEN vessel standing together at `SOL-3`, a stocked
/// census row for that location, and two unmeshed salvage systems 5 ly out.
///
/// `VEGA` is the richer pile, so `GrowRanking` must choose it first; `ALTAIR`
/// exists so the post-lifecycle assertion "VEGA is no longer ranked" is a
/// statement about re-ranking rather than about an empty field.
private func seedGrowWorld(_ db: Database) throws {
    try seedRelay(db, code: "REL1", location: "SOL", updatedAt: liftoff)
    try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
    try seedPrintHub(db, code: "HUB1", location: hubLocation, updatedAt: liftoff)
    try seedDevice(db, code: "V1", type: "heaven_vessel", location: hubLocation, updatedAt: liftoff)

    try seedStar(db, designation: target, x: 5, y: 0, z: 0)
    try seedSalvageAssay(db, id: "SITE-\(target)", system: target, totals: ["metal": 3_200])
    try seedStar(db, designation: runnerUp, x: 0, y: 5, z: 0)
    try seedSalvageAssay(db, id: "SITE-\(runnerUp)", system: runnerUp, totals: ["metal": 100])

    // The reserve rail is armed in production (`BrainCeiling.aggregateSpendFloor`),
    // so the hub must hold real stock or the print is vetoed and nothing else in
    // this file ever happens.
    try seedFootprint(db, location: hubLocation, resources: 999_999, fetchedAt: liftoff)

    // `emplacing` reads the target's catalogue blob for its Lagrange point.
    // Every system's entry point IS an L4 live, which is also where a
    // bare-designation travel lands the carrier — so the emplace hop is free.
    try seedSystemWithEntryPoint(db, designation: target)
}

private func seedFootprint(
    _ db: Database, location: String, resources: Int, fetchedAt: Date
) throws {
    try LocationFootprint.insert {
        LocationFootprint(
            location: location, devices: 1, resources: resources, resourceSites: 0,
            locationEvents: 0, replicants: 0, fetchedAt: fetchedAt
        )
    }.execute(db)
}

private func seedSystemWithEntryPoint(_ db: Database, designation: String) throws {
    let system = StarSystem(
        designation: designation, systemScanned: true, entryPoint: entryPoint(of: designation)
    )
    let row = try SystemDetail(system: system, hydratedAt: liftoff)
    try SystemDetail.insert { row }.execute(db)
}

/// Where a bare-designation travel actually puts a device: the system's entry
/// point, which is an L4 (`travel-system-proxy-codes`). The scripted server
/// resolves destinations through this, so the carrier arrives exactly where
/// `emplacing` expects to find it.
private func entryPoint(of system: String) -> String { "\(system)-1-L4" }

// MARK: - The scripted seam

/// One command as it reached the wire. Only the fields this lifecycle turns on
/// are carried — a full `CommandParams` in the expectation would assert the
/// absence of ten irrelevant fields and read as noise.
private struct SeamCommand: Equatable, Sendable, CustomStringConvertible {
    let verb: String
    let deviceCode: String
    var destination: String?
    var deviceType: String?
    var target: String?

    var description: String {
        var text = "\(verb) → \(deviceCode)"
        if let destination { text += " (destination: \(destination))" }
        if let deviceType { text += " (device_type: \(deviceType))" }
        if let target { text += " (target: \(target))" }
        return text
    }
}

/// The server, and the sync that folds its answers back into SQLite.
///
/// It sits UNDER `CommandGovernor` — the governor's budget gate and its
/// per-device in-flight claim both run before anything here does — and its
/// whole job is to be honest about two things the mission machine is built
/// around:
///
///   1. **Tracked vs `.simple`.** `print` and `travel` create an `Operation`
///      row that stays OPEN until the world catches up, exactly as
///      `CommandClient` writes one; `stow`, `deploy` and `activate` are
///      `.simple` verbs classified `.immediate`, so they create no operation
///      row and answer `.accepted(operationID: nil)`. That is what makes the
///      run's split dispatch/poll steps mean something here.
///   2. **Effects take TIME.** A print materialises its clone later; a travel
///      lands later. Both are queued and applied by `settle(now:)` when the
///      virtual clock reaches them, so the poll steps genuinely poll.
///
/// An unrecognised command is recorded as an Issue and rejected rather than
/// quietly accepted — a lifecycle that started issuing something new must not
/// pass silently.
private actor ScriptedServer {
    private let database: any DatabaseWriter
    private let printDelay: TimeInterval
    private let travelDelay: TimeInterval
    /// The mutation switch for the negative test: with this false the server
    /// takes the `activate` and does nothing about it, exactly as a relay that
    /// never comes up would.
    private let activateTakes: Bool

    private(set) var commands: [SeamCommand] = []
    private var opCounter = 0
    private var printCount = 0
    private var pending: [Effect] = []

    private enum Effect {
        case printCompletes(opID: String, at: Date, location: String, clone: String)
        case arrival(opID: String, deviceCode: String, at: Date, location: String)

        var due: Date {
            switch self {
            case let .printCompletes(_, at, _, _): at
            case let .arrival(_, _, at, _): at
            }
        }
    }

    init(
        database: any DatabaseWriter,
        printDelay: TimeInterval = 60,
        travelDelay: TimeInterval = 30,
        activateTakes: Bool = true
    ) {
        self.database = database
        self.printDelay = printDelay
        self.travelDelay = travelDelay
        self.activateTakes = activateTakes
    }

    /// The `CommandClient` this server answers as. `previewTravel` is left
    /// `unimplemented` — nothing in a Relay Run previews a route, and a quiet
    /// stub would hide it if something started to.
    nonisolated func seam() -> CommandClient {
        var client = CommandClient.testValue
        client.dispatch = { [self] kind, deviceCode, params in
            @Dependency(\.date) var date
            return await dispatch(kind: kind, deviceCode: deviceCode, params: params, now: date.now)
        }
        return client
    }

    private func nextOpID() -> String {
        opCounter += 1
        return "OP-\(opCounter)"
    }

    func dispatch(
        kind: OperationKind, deviceCode: String, params: CommandParams, now: Date
    ) async -> CommandOutcome {
        commands.append(
            SeamCommand(
                verb: kind.rawValue, deviceCode: deviceCode,
                destination: params.destination, deviceType: params.deviceType,
                target: params.target
            )
        )

        switch kind {
        case .print:
            // Tracked, `.enqueued`: the job is in the hub's queue and completes
            // via a later stream event — which is why `printing` polls for the
            // CLONE rather than for the op.
            let opID = nextOpID()
            let location = await deviceRow(deviceCode)?.location ?? hubLocation
            await write { db in
                try Operation.insert {
                    Operation(
                        id: opID, entityCode: deviceCode, kind: OperationKind.print.rawValue,
                        status: .enqueued, source: .poll, startedAt: now, completesAt: nil,
                        lastConfirmedAt: now,
                        detail: .object(["params": .object(["device_type": .string(params.deviceType ?? "")])])
                    )
                }.execute(db)
            }
            printCount += 1
            pending.append(
                .printCompletes(
                    opID: opID, at: now.addingTimeInterval(printDelay), location: location,
                    clone: cloneCode(forPrint: printCount)
                )
            )
            return .accepted(operationID: opID)

        case .travel:
            // Tracked, `.active` with a deadline. A bare system designation is
            // a PROXY for that system's entry point, which is where the device
            // actually lands.
            guard let destination = params.destination else {
                Issue.record("travel dispatched with no destination")
                return .rejected("no destination")
            }
            let landing = destination.contains("-") ? destination : entryPoint(of: destination)
            let opID = nextOpID()
            let arrivesAt = now.addingTimeInterval(travelDelay)
            await write { db in
                try Operation.insert {
                    Operation(
                        id: opID, entityCode: deviceCode, kind: OperationKind.travel.rawValue,
                        status: .active, source: .poll, startedAt: now, completesAt: arrivesAt,
                        lastConfirmedAt: now,
                        detail: .object(["params": .object(["destination": .string(destination)])])
                    )
                }.execute(db)
            }
            // The post-command authoritative read the live client always takes:
            // the device now reads as under way.
            await mutate(deviceCode, at: now) { $0.status = "travelling" }
            pending.append(.arrival(opID: opID, deviceCode: deviceCode, at: arrivesAt, location: landing))
            return .accepted(operationID: opID)

        default:
            return await immediate(verb: kind.rawValue, deviceCode: deviceCode, params: params, now: now)
        }
    }

    /// A `.simple` verb: answered synchronously, NO `Operation` row, and the
    /// commanded device's row refreshed by the one post-command authoritative
    /// read the live `CommandClient` takes.
    private func immediate(
        verb: String, deviceCode: String, params: CommandParams, now: Date
    ) async -> CommandOutcome {
        switch verb {
        case "stow":
            guard let carrier = params.target else {
                Issue.record("stow dispatched with no target carrier")
                return .rejected("no target")
            }
            await mutate(deviceCode, at: now) {
                $0.stowedInDeviceCode = carrier
                // Stowing CLEARS location — the device is cargo, not present
                // anywhere (`location-scope-cannot-see-stowed`).
                $0.location = nil
            }
            return .accepted(operationID: nil)

        case "deploy":
            var landing: String?
            if let hull = await deviceRow(deviceCode)?.stowedInDeviceCode {
                landing = await deviceRow(hull)?.location
            }
            guard let landing else {
                Issue.record("deploy dispatched at \(deviceCode), which is aboard nothing")
                return .rejected("not stowed")
            }
            await mutate(deviceCode, at: now) {
                $0.stowedInDeviceCode = nil
                $0.location = landing
            }
            return .accepted(operationID: nil)

        case "activate":
            if activateTakes {
                await mutate(deviceCode, at: now) { $0.status = "relaying" }
            } else {
                // The server took the command; the relay simply never comes up.
                await mutate(deviceCode, at: now) { _ in }
            }
            return .accepted(operationID: nil)

        default:
            Issue.record("unscripted command \(verb) at \(deviceCode)")
            return .rejected("unscripted command \(verb)")
        }
    }

    /// Apply every scheduled effect the virtual clock has reached. This is the
    /// world moving on between ticks — a print finishing, a carrier arriving —
    /// and the local rows catching up with it.
    func settle(now: Date) async {
        let due = pending.filter { $0.due <= now }
        pending.removeAll { $0.due <= now }
        for effect in due.sorted(by: { $0.due < $1.due }) {
            switch effect {
            case let .printCompletes(opID, at, location, clone):
                await write { db in
                    guard var op = try Operation.where({ $0.id.eq(opID) }).fetchOne(db) else { return }
                    op.status = .completed
                    op.lastConfirmedAt = at
                    // `new_device_code` under `detail.result` is exactly where
                    // `Reconciler.completeOpenOperation` files a completion's
                    // payload, and exactly where `RelayRun.printedRelayCode`
                    // reads it from.
                    op.detail = .object(["result": .object(["new_device_code": .string(clone)])])
                    try Operation.upsert { op }.execute(db)
                }
                // …and the clone itself, folded into the fleet the way
                // `GameSync.deviceRoute` folds it in off `print.completed`.
                await write { db in
                    try seedDevice(
                        db, code: clone, type: SalvageRun.relayDeviceType, location: location,
                        status: "inactive", features: ["cruise", "relay", "stow"], updatedAt: at
                    )
                }

            case let .arrival(opID, deviceCode, at, location):
                await write { db in
                    guard var op = try Operation.where({ $0.id.eq(opID) }).fetchOne(db) else { return }
                    op.status = .completed
                    op.lastConfirmedAt = at
                    try Operation.upsert { op }.execute(db)
                }
                await mutate(deviceCode, at: at) {
                    $0.location = location
                    $0.status = "idle"
                }
            }
        }
    }

    /// Move a device by hand — the operator flying the carrier home, say. Not
    /// a command, so it is deliberately not recorded as one.
    func place(_ deviceCode: String, at location: String, now: Date) async {
        await mutate(deviceCode, at: now) { $0.location = location }
    }

    /// An ordinary background device read landing (`PollCoordinator`'s job in
    /// production) — the row is unchanged but no longer stale.
    func touch(_ deviceCode: String, now: Date) async {
        await mutate(deviceCode, at: now) { _ in }
    }

    /// The `GET /v1/locations` holdings overlay, as the server would answer it.
    ///
    /// Scripted at the READ, not at the persistence: `LocationsClient
    /// .refreshFootprint()` — the real one — is what upserts these rows and
    /// stamps `fetchedAt`, so `RelayRun.acquire`'s stale-census branch and the
    /// engine's `resolveFootprintRefresh` both run for real against it.
    nonisolated func census() -> [String: LocationCounts] {
        [hubLocation: LocationCounts(devices: 2, resources: 999_999)]
    }

    private func deviceRow(_ code: String) async -> Device? {
        try? await database.read { db in try Device.where { $0.deviceCode.eq(code) }.fetchOne(db) }
    }

    /// Every server-side effect lands on the row together with a fresh
    /// `updatedAt` — that stamp is the evidence half of every confirm step
    /// (`confirm-steps-need-fresh-evidence`), so writing one without it would
    /// make those steps unprovable.
    private func mutate(
        _ code: String, at now: Date, _ change: @escaping @Sendable (inout Device) -> Void
    ) async {
        await write { db in
            guard var row = try Device.where({ $0.deviceCode.eq(code) }).fetchOne(db) else { return }
            change(&row)
            row.updatedAt = now
            try Device.upsert { row }.execute(db)
        }
    }

    private func write(_ body: @escaping @Sendable (Database) throws -> Void) async {
        do { try await database.write { db in try body(db) } }
        catch { Issue.record("scripted server write failed: \(error)") }
    }
}

// MARK: - The driver

/// One virtual tick's worth of observation: where the run stands, and what the
/// brain published about the same instant.
private struct Tick: Sendable {
    let step: String?
    let status: DirectiveStatus?
    let decision: BrainDecision?
    let ranked: [String]
}

/// A healthy actions budget, so the REAL `CommandGovernor` lets commands
/// through. `GameClient.testValue` reports `remaining: 0`, which the governor
/// correctly reads as "defer everything" — that is the governor working, not a
/// fixture to route around, so it is fed a real budget instead of being
/// replaced.
private func fundedGameClient() -> GameClient {
    var client = GameClient.testValue
    client.budget = { _ in RateLimitGovernor.Snapshot(limit: 60, remaining: 60, resetAt: nil) }
    return client
}

/// Drive `count` virtual ticks of BOTH engine loops against the scripted world.
///
/// Per tick: the world moves on (`settle`), the brain plans (`tickBrain`), and
/// every running Relay Run gets one executor evaluation — which is what
/// `DirectiveEngineCore.start()` runs as two concurrent loops in production.
/// The running set is re-read after the brain plans, so a run launched on this
/// tick is evaluated on this tick, exactly as the supervisor would pick it up.
private func drive(
    _ database: any DatabaseWriter,
    core: DirectiveEngineCore,
    server: ScriptedServer,
    uuid: UUIDGenerator,
    reads: LockIsolated<[ConfirmRead]>,
    censusReads: LockIsolated<Int> = LockIsolated(0),
    storage: InMemoryStorage,
    from start: Date,
    ticks count: Int
) async -> [Tick] {
    let clock = TestClock()
    var ticks: [Tick] = []
    for index in 0..<count {
        let now = start.addingTimeInterval(Double(index) * tickSeconds)
        await server.settle(now: now)
        let tick = await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(now)
            $0.uuid = uuid
            $0.continuousClock = clock
            $0.defaultInMemoryStorage = storage
            $0.deviceRefresher = confirmingRefresher(database, reads: reads)
            // The real governor — budget gate and per-device in-flight claim.
            $0.commandGovernor = .liveValue
            $0.gameClient = fundedGameClient()
            // THE COMMAND WIRE. Everything between this and the brain —
            // governor, executor, machine, engine resolvers — is production
            // code.
            $0.commandClient = server.seam()
            // The one scripted READ: the stockpile census the reserve rail
            // consults. `LocationsClient.refreshFootprint()` itself — the
            // persistence, the `fetchedAt` stamp, the `explored` repair — is
            // the real one, and so is the engine resolver that calls it.
            // Everything else on this client stays `unimplemented`.
            $0.locationsClient.footprint = { [censusReads] in
                censusReads.withValue { $0 += 1 }
                return server.census()
            }
        } operation: { () -> Tick in
            @Shared(.brainReport) var report: BrainReport?
            await core.tickBrain()
            let running = (
                try? await database.read { db in
                    try Directive
                        .where { $0.kind.eq(DirectiveKind.relayRun) && $0.status.eq(DirectiveStatus.running) }
                        .order { $0.id }
                        .fetchAll(db)
                }
            ) ?? []
            for directive in running { await core.evaluateOnce(directiveID: directive.id) }
            let row = try? await database.read { db in
                try Directive.where { $0.kind.eq(DirectiveKind.relayRun) }.order { $0.id }.fetchAll(db).last
            }
            return Tick(
                step: row?.step, status: row?.status,
                decision: report?.decision, ranked: report?.ranked.map(\.firstHop) ?? []
            )
        }
        ticks.append(tick)
    }
    return ticks
}

private func relayRuns(_ database: any DatabaseReader) async throws -> [Directive] {
    try await database.read { db in
        try Directive.where { $0.kind.eq(DirectiveKind.relayRun) }.order { $0.createdAt }.fetchAll(db)
    }
}

private func worldView(_ database: any DatabaseReader, now: Date) async throws -> WorldView {
    try await database.read { db in try WorldView.read(from: db, now: now) }
}

/// Consecutive duplicates collapsed — the run holds a polling step for many
/// ticks, and the ORDER of the steps is what this file is about.
private func stepPath(_ ticks: [Tick]) -> [String] {
    ticks.compactMap(\.step).reduce(into: [String]()) { path, step in
        if path.last != step { path.append(step) }
    }
}

// MARK: - The lifecycle

/// `.serialized` because these tests install `CommandGovernorClient.liveValue`
/// — one process-shared governor with a per-device in-flight claim. Two of
/// these running concurrently could hand each other a `.deferred(.commandInFlight)`
/// on the same device code and make the command sequence timing-dependent.
@Suite("Brain — grow lifecycle end to end", .serialized)
struct BrainGrowLifecycleE2ETests {

    /// The headline. From a standing start the brain ranks, gates, and launches
    /// a Relay Run; the executor prints, stows, travels, emplaces, activates;
    /// the world reflects `relaying`; the target joins `meshSystems`; and the
    /// next brain tick no longer ranks it.
    ///
    /// Every one of those is asserted as an OUTCOME, not as a step visited:
    /// the exact command sequence (so a run that skipped `activate` fails), the
    /// device row's `statusBase`, `WorldView.meshSystems`, and the ranked field
    /// the brain published afterwards.
    @Test func aGrowLaunchRunsAllTheWayToAGrownMesh() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedGrowWorld(db) }
        let server = ScriptedServer(database: database)
        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        let reads = LockIsolated<[ConfirmRead]>([])
        // ONE generator for the whole test: `UUIDGenerator.incrementing` is a
        // computed property, so re-entering `withDependencies` per tick would
        // mint the same id every time and make "did not double-launch" pass
        // vacuously (`BrainGrowTests` records the same trap).
        let uuid = UUIDGenerator.incrementing

        let ticks = await drive(
            database, core: core, server: server, uuid: uuid, reads: reads,
            storage: InMemoryStorage(), from: liftoff, ticks: 60
        )

        // 1. THE COMMANDS. The whole point of driving the real seam: this is
        //    the sequence a live account would have seen, in order, once each.
        //    A lifecycle that never issued `activate` — or issued it twice, the
        //    `.simple`-verb redispatch trap — fails right here.
        let commands = await server.commands
        #expect(commands == [
            SeamCommand(verb: "print", deviceCode: "HUB1", deviceType: SalvageRun.relayDeviceType),
            SeamCommand(verb: "stow", deviceCode: firstClone, target: "V1"),
            SeamCommand(verb: "travel", deviceCode: "V1", destination: target),
            SeamCommand(verb: "deploy", deviceCode: firstClone),
            SeamCommand(verb: "activate", deviceCode: firstClone),
        ], "the run's command sequence, as the governor saw it")

        // 2. THE STEPS, in order and each exactly once — the `.simple` verbs
        //    split into dispatch + poll, so a machine that collapsed one of
        //    those pairs would show a missing step here.
        #expect(stepPath(ticks) == [
            RelayRun.Step.printing,
            RelayRun.Step.stowing,
            RelayRun.Step.confirmingStow,
            RelayRun.Step.travelling,
            RelayRun.Step.emplacing,
            RelayRun.Step.activating,
            RelayRun.Step.confirmingRelay,
            RelayRun.Step.settling,
        ])

        // 3. THE RUN. One row, launched by the brain, finished by the executor.
        let runs = try await relayRuns(database)
        #expect(runs.count == 1, "one launch for one target, however many ticks ran")
        let run = try #require(runs.first)
        #expect(run.status == .completed)
        #expect(run.targets == [target])
        #expect(run.deviceCode == "V1")
        #expect(run.sourceRelayCode == nil, "nothing is reclaimable and no replicant rides V1 — so this grow prints")
        #expect(run.attentionReason == nil, "a clean lifecycle stalls nowhere")

        // 4. THE MESH GREW. Not "the steps were visited" — the actual
        //    deliverable, read the way production reads it (device rows, never
        //    `ftlLinks`: a just-activated relay has produced no link rows yet).
        let relay = try #require(
            await database.read { db in
                try Device.where { $0.deviceCode.eq(firstClone) }.fetchOne(db)
            }
        )
        #expect(relay.statusBase == "relaying")
        #expect(relay.location == entryPoint(of: target))
        #expect(relay.stowedInDeviceCode == nil, "a relay meshes in situ, not from the hold")

        let view = try await worldView(database, now: liftoff.addingTimeInterval(600))
        #expect(view.meshSystems == ["SOL", target], "the mesh is one system bigger than it started")

        // 5. THE BRAIN CONVERGED. The last tick ranked ALTAIR and nothing else:
        //    VEGA is meshed, so `ValueCatalog` no longer offers it. This is the
        //    assertion that fails if the mesh read and the ranking ever stop
        //    agreeing — a run that "completed" without meshing would leave VEGA
        //    ranked forever.
        let last = try #require(ticks.last)
        #expect(last.ranked == [runnerUp], "the meshed target is no longer a grow candidate")
        #expect(
            last.decision == .idle(reason: "no free carrier at \(hubLocation)"),
            "V1 ended the run at \(target), so the next grow waits for a carrier — not for a target"
        )

        // 6. THE CONFIRM-FRESH GATE actually fired, exactly once, at `.high`.
        //    `DeviceRefreshClient.testValue` is INERT (nil, not unimplemented),
        //    so a brain that had lost its gate would defer silently and every
        //    assertion above would still pass on a run that never launched —
        //    except this one.
        #expect(reads.value == [ConfirmRead(deviceCode: "V1", isHigh: true)])
    }

    /// The other half of convergence: the brain does not merely stop, it moves
    /// on. With the carrier back at the hub the next tick launches a run for
    /// the runner-up — and never a second one for the system it already meshed.
    @Test func theNextGrowGoesToTheNextCandidateNotTheMeshedOne() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedGrowWorld(db) }
        let server = ScriptedServer(database: database)
        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        let reads = LockIsolated<[ConfirmRead]>([])
        let uuid = UUIDGenerator.incrementing
        let storage = InMemoryStorage()

        _ = await drive(
            database, core: core, server: server, uuid: uuid, reads: reads,
            storage: storage, from: liftoff, ticks: 60
        )
        #expect(try await relayRuns(database).count == 1)

        // The carrier flies home, and the fleet's ordinary background reads land
        // on the hub — neither is a command, so neither is recorded as one. The
        // hub touch matters: `acquire` will not spend resources on a row older
        // than `RelayRun.hubFreshness`, and five virtual minutes have passed.
        let resumed = liftoff.addingTimeInterval(60 * tickSeconds)
        await server.place("V1", at: hubLocation, now: resumed)
        await server.touch("HUB1", now: resumed)

        // The census, by contrast, IS stale by now — and that is the point:
        // this second launch exercises `acquire`'s stale-census branch and the
        // engine's `resolveFootprintRefresh` for real, ending in a print.
        let censusReads = LockIsolated(0)
        let after = await drive(
            database, core: core, server: server, uuid: uuid, reads: reads,
            censusReads: censusReads, storage: storage, from: resumed, ticks: 2
        )
        #expect(censusReads.value == 1, "one census refresh bought the print, and only one")

        let runs = try await relayRuns(database)
        #expect(runs.count == 2)
        let second = try #require(runs.last)
        #expect(second.targets == [runnerUp], "the meshed system must not be grown at twice")
        #expect(second.status == .running)
        guard case let .dispatch(goal, _)? = after.first?.decision else {
            Issue.record("expected the freed carrier to produce a dispatch, got \(String(describing: after.first?.decision))")
            return
        }
        #expect(goal.kind == .tendMesh)
        #expect(goal.target == runnerUp)
    }

    /// **The failure this file has to be able to see.** Same world, same stack
    /// — but the server takes the `activate` and the relay never comes up.
    ///
    /// It is the mutation the headline test's assertions are calibrated
    /// against: the run visits every step up to `confirmingRelay` and issues
    /// every command, so any test that only checked steps or commands would
    /// still pass. The mesh does not grow, and the brain keeps ranking the
    /// target — which is what the headline asserts and this proves it can lose.
    @Test func aRelayThatNeverComesUpGrowsNoMeshAndTheBrainKeepsRankingTheTarget() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedGrowWorld(db) }
        let server = ScriptedServer(database: database, activateTakes: false)
        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        let reads = LockIsolated<[ConfirmRead]>([])
        let uuid = UUIDGenerator.incrementing

        // Stopped short of `SalvageRun.activationDeadline` (10 min) on purpose:
        // this test is about the mesh not growing, and letting the run stall
        // would drag the brain's stall-response layer in, which is
        // `BrainStallResponseTests`' subject.
        let ticks = await drive(
            database, core: core, server: server, uuid: uuid, reads: reads,
            storage: InMemoryStorage(), from: liftoff, ticks: 40
        )

        let commands = await server.commands
        #expect(commands.map(\.verb) == ["print", "stow", "travel", "deploy", "activate"],
                "every command still went out — the failure is in the world, not in the run")

        let relay = try #require(
            await database.read { db in try Device.where { $0.deviceCode.eq(firstClone) }.fetchOne(db) }
        )
        #expect(relay.statusBase != "relaying")

        let view = try await worldView(database, now: liftoff.addingTimeInterval(600))
        #expect(view.meshSystems == ["SOL"], "the mesh did not grow")

        let last = try #require(ticks.last)
        #expect(last.step == RelayRun.Step.confirmingRelay, "still polling for a relay that never came up")
        #expect(last.status == .running)
        #expect(last.ranked.contains(target), "an unmeshed target stays a grow candidate")
    }

    /// The supervisor half of the wiring, which the driver above deliberately
    /// does not use: a row the BRAIN wrote is picked up by
    /// `reconcileExecutors()` like any other, with no help from this test.
    ///
    /// Without this, "the executor ran it" would rest on the driver calling
    /// `evaluateOnce` itself — which is the engine's own loop body, but not
    /// proof that anything in production would call it for a brain-launched
    /// row.
    @Test func theSupervisorAdoptsTheRowTheBrainLaunched() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in try seedGrowWorld(db) }
        let server = ScriptedServer(database: database)
        let core = DirectiveEngineCore(machines: MissionRegistry.machines, tick: .seconds(5))
        let uuid = UUIDGenerator.incrementing

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(liftoff)
            $0.uuid = uuid
            $0.continuousClock = TestClock()
            $0.defaultInMemoryStorage = InMemoryStorage()
            $0.deviceRefresher = confirmingRefresher(database)
            $0.commandGovernor = .liveValue
            $0.gameClient = fundedGameClient()
            $0.commandClient = server.seam()
        } operation: {
            // `start()` is what claims the supervisor — `reconcileExecutors()`
            // deliberately refuses to spawn anything for a torn-down engine, so
            // this cannot be shortcut. The loops it spawns tick once and then
            // sleep on a `TestClock` that never advances; the assertions below
            // are on state only they and these awaited calls can reach, and
            // both paths agree (one directive, one executor).
            await core.start()
            await core.tickBrain()
            await core.reconcileExecutors()
            #expect(
                await core.executorCount == 1,
                "the supervisor must spawn an executor for the directive the brain just wrote"
            )
            await core.stop()
        }

        let runs = try await relayRuns(database)
        #expect(runs.count == 1)
        #expect(runs.first?.targets == [target])
    }
}
