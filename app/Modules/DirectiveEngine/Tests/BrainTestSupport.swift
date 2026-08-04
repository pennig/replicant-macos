//
//  BrainTestSupport.swift
//  Replicould — DirectiveEngine
//
//  Shared seed helpers for the automation-brain test suite. Every brain task
//  that needs a minimal device/star/assay/event row writes it here rather than
//  hand-rolling a private copy per test file — the fixtures are trivial, but
//  duplicating them across a dozen test files is exactly the kind of drift
//  that lets one file's `Device` init fall out of sync with the real schema.
//
//  Internal to the test target only: production `Sources/` must never carry
//  test fixtures (a review already caught and reversed exactly that mistake on
//  Task 3 — see `DevicePredicatesTests.swift`'s private `Device.fixture`).
//

import Dependencies
import Foundation
import GameModels
import GameServices
import SQLiteData
import UniverseModels
@testable import DirectiveEngine

// MARK: - Device seeds

/// A minimal device row. Defaults read as an idle, undeployed device; override
/// only what a test cares about.
func deviceFixture(
    code: String,
    type: String = "heaven_vessel",
    location: String? = nil,
    status: String = "idle",
    features: [String] = [],
    availableCommands: [String] = [],
    tags: [String] = [],
    stowedIn: String? = nil
) -> Device {
    Device(
        deviceCode: code, deviceType: type, replicantCode: "R1", status: status,
        location: location, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: stowedIn, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: availableCommands,
        features: features, tags: tags, detail: .object([:]),
        updatedAt: Date(timeIntervalSince1970: 0), firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

/// `deviceFixture`, inserted.
func seedDevice(
    _ db: Database,
    code: String,
    type: String = "heaven_vessel",
    location: String? = nil,
    status: String = "idle",
    features: [String] = [],
    availableCommands: [String] = [],
    tags: [String] = [],
    stowedIn: String? = nil
) throws {
    try Device.insert {
        deviceFixture(
            code: code, type: type, location: location, status: status, features: features,
            availableCommands: availableCommands, tags: tags, stowedIn: stowedIn
        )
    }.execute(db)
}

/// An FTL relay meshing its system — `features: ["relay"]` + `statusBase ==
/// "relaying"`, the exact predicate `SalvageTargetPlanner.meshSystems(in:)` and
/// `Device.isActiveRelay` both key off.
func seedRelay(_ db: Database, code: String, location: String, status: String = "relaying") throws {
    try seedDevice(db, code: code, type: "ftl_relay", location: location, status: status, features: ["relay"])
}

/// A print-capable device — `Device.isPrintHub` keys off `enqueue_print` in
/// `availableCommands`, not device type.
func seedPrintHub(_ db: Database, code: String, location: String) throws {
    try seedDevice(
        db, code: code, type: "autofactory", location: location,
        availableCommands: ["enqueue_print"]
    )
}

// MARK: - Replicant seeds

/// One of the account's replicants, standing at `star` and riding in
/// `hostedDeviceCode`.
///
/// Both fields are load-bearing and neither is decoration: `currentStar` is
/// where command authority lives (`PrunePredicate` roots its keep-set on it),
/// and `hostedDeviceCode` is what makes a carrier legal to send on a RECLAIM —
/// the source relay's system leaves the mesh the moment it is deactivated, so
/// only a replicant physically aboard keeps the follow-up `stow` commandable.
func seedReplicant(
    _ db: Database, code: String, star: String?, hostedDeviceCode: String?
) throws {
    try Replicant.insert {
        Replicant(
            replicantCode: code, name: code, createdAt: Date(timeIntervalSince1970: 0),
            currentStar: star, currentStarName: star,
            currentLocation: star.map { "\($0)-1" }, currentLocationName: nil,
            hostedDeviceCode: hostedDeviceCode
        )
    }.execute(db)
}

// MARK: - Directive seeds

/// A directive row as a value, for tests that reason over directives without a
/// database (the reservation rules). Defaults read as a running Salvage Run
/// owning one vessel and nothing else; override only what a test cares about.
func directiveFixture(
    id: String,
    kind: DirectiveKind = .salvageRun,
    status: DirectiveStatus = .running,
    deviceCode: String,
    controllerCode: String? = nil,
    fleetTag: String? = nil,
    targets: [String] = []
) -> Directive {
    Directive(
        id: id, kind: kind, status: status, deviceCode: deviceCode,
        controllerCode: controllerCode, roamCentre: nil, fleetTag: fleetTag,
        sourceRelayCode: nil, targets: targets, targetIndex: 0,
        step: "step", stepStartedAt: Date(timeIntervalSince1970: 0),
        returnToOrigin: false, originDesignation: nil, attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
    )
}

/// `directiveFixture`, inserted.
func seedDirective(
    _ db: Database,
    id: String,
    kind: DirectiveKind = .salvageRun,
    status: DirectiveStatus = .running,
    deviceCode: String,
    controllerCode: String? = nil,
    fleetTag: String? = nil,
    targets: [String] = []
) throws {
    try Directive.insert {
        directiveFixture(
            id: id, kind: kind, status: status, deviceCode: deviceCode,
            controllerCode: controllerCode, fleetTag: fleetTag, targets: targets
        )
    }.execute(db)
}

// MARK: - Relay Run / stall seeds

/// A `.running` Relay Run shaped exactly as `Brain.launch` writes one — the
/// starting point for every stall-response test, so those tests reason about a
/// row the brain could really have produced rather than a hand-typed one.
func seedRelayRun(
    _ db: Database,
    id: String,
    deviceCode: String = "V1",
    step: String = RelayRun().firstStep,
    targets: [String] = ["VEGA"],
    sourceRelayCode: String? = nil,
    at: Date = Date(timeIntervalSince1970: 0)
) throws {
    try Directive.insert {
        Directive(
            id: id, kind: .relayRun, status: .running, deviceCode: deviceCode,
            controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: sourceRelayCode,
            targets: targets, targetIndex: 0, step: step, stepStartedAt: at,
            returnToOrigin: false, originDesignation: "SOL", attentionReason: nil,
            createdAt: at, updatedAt: at
        )
    }.execute(db)
}

/// Halt-and-surface a directive **exactly as `DirectiveExecutor.stall` does**:
/// the row flips to `.needsAttention` carrying its reason, and a `.stalled`
/// timeline entry naming the current step lands beside it.
///
/// Mirroring the executor matters here rather than being tidiness: the brain's
/// retry budget is derived from that timeline, so a fixture that wrote the row
/// without the entry (or the entry without the step) would let a budget test
/// pass against a timeline production never produces. Used both to seed a
/// fresh stall and to re-stall a directive the brain has just retried.
func stallDirective(
    _ db: Database,
    id: String,
    reason: DirectiveAttentionReason,
    entryID: String,
    at: Date
) throws {
    guard var directive = try Directive.where({ $0.id.eq(id) }).fetchOne(db) else { return }
    directive.status = .needsAttention
    directive.attentionReason = reason
    directive.updatedAt = at
    try Directive.upsert { directive }.execute(db)
    try DirectiveLogEntry.insert {
        DirectiveLogEntry(
            id: entryID, directiveID: id, deviceCode: nil, kind: .stalled,
            summary: reason.rawValue, step: directive.step, operationID: nil,
            eventID: nil, occurredAt: at
        )
    }.execute(db)
}

/// One timeline entry, for the tests that need a specific history rather than
/// one built by driving the real transitions.
func seedLogEntry(
    _ db: Database,
    id: String,
    directiveID: String,
    kind: DirectiveLogKind,
    summary: String = "",
    step: String?,
    at: Date
) throws {
    try DirectiveLogEntry.insert {
        DirectiveLogEntry(
            id: id, directiveID: directiveID, deviceCode: nil, kind: kind,
            summary: summary, step: step, operationID: nil, eventID: nil, occurredAt: at
        )
    }.execute(db)
}

// MARK: - Confirm-read seeds

/// One confirm-read the brain asked for.
///
/// The priority is recorded as a FLAG rather than the enum itself:
/// `RefreshPriority` declares no `Equatable` conformance, and a recording that
/// could not tell `.low` from `.high` would leave the gate's whole point — a
/// just-in-time authoritative read, not a TTL-suppressible hint — unprovable.
struct ConfirmRead: Equatable, Sendable {
    let deviceCode: String
    let isHigh: Bool
}

/// A `deviceRefresher` stand-in that answers from the LOCAL fleet table — the
/// "nothing moved between ranking and the commit" world, which is what every
/// launch test means when it says the carrier was free.
///
/// `answering` receives the row the database holds and returns what the SERVER
/// says about it: the row unchanged (nothing moved), a mutated row (something
/// did), or nil (the read failed / was deferred). It is `async` so a test can
/// also mutate the world *inside* the confirm window — which is how the
/// operator-launches-in-the-race-window test is written.
///
/// Every call lands in `reads`, so a test can prove WHEN the brain confirms
/// rather than only what it concluded: a gate that fired on every tick would
/// spend a `.high` read against the live API every five seconds.
///
/// **Deliberately does not write the answer back.** The live client reconciles
/// (that is `PollCoordinator`'s job, not the brain's); a stand-in that stamped
/// `devices.updatedAt` would break the row-for-row "a launching brain writes
/// the directive and nothing else" assertions over a write the brain does not
/// make.
func confirmingRefresher(
    _ database: any DatabaseWriter,
    reads: LockIsolated<[ConfirmRead]> = LockIsolated([]),
    answering: @escaping @Sendable (Device) async -> Device? = { $0 }
) -> DeviceRefreshClient {
    DeviceRefreshClient { code, priority in
        let isHigh: Bool
        switch priority {
        case .high: isHigh = true
        case .low: isHigh = false
        }
        reads.withValue { $0.append(ConfirmRead(deviceCode: code, isHigh: isHigh)) }
        let row = try? await database.read { db in
            try Device.where { $0.deviceCode.eq(code) }.fetchOne(db)
        }
        guard let row = row.flatMap({ $0 }) else { return nil }
        return await answering(row)
    }
}

// MARK: - Star seeds

/// A census star at a given position. Only the fields `WorldView` reads are
/// exposed as parameters; everything else takes an inert default.
func seedStar(_ db: Database, designation: String, x: Double, y: Double, z: Double) throws {
    try Star.insert {
        Star(
            designation: designation, spectralType: "G", color: "yellow",
            positionX: x, positionY: y, positionZ: z, estimatedPlanets: 0,
            explored: false, hasLife: nil, entryPoint: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

// MARK: - SiteAssay seeds

/// A salvage site's assayed totals. `siteType` is fixed to `"salvage"` since
/// that's the only kind the brain's `WorldView.salvageUnits` sums; a future
/// mining-assay seed would be a separate helper, not a parameter here.
func seedSalvageAssay(
    _ db: Database, id: String, system: String,
    totals: [String: Double], depleted: Bool = false
) throws {
    try SiteAssay.insert {
        // `body` isn't read by anything `WorldView` does; `system` is a fine
        // stand-in when a test has no reason to name the hosting body.
        SiteAssay(
            id: id, body: system, system: system,
            siteType: "salvage", totals: totals,
            assayedAt: Date(timeIntervalSince1970: 0), depleted: depleted
        )
    }.execute(db)
}

// MARK: - SystemDetail seeds

/// A `systemDetails` row wrapping a minimal `StarSystem` blob — the fixture
/// `WorldViewBeltsTests` needs. No `StarSystem.seedWithBelt`/`Star.seed`
/// helper exists anywhere in this codebase (the task-11 brief invented one);
/// this is the real shape, built on the actual `SystemDetail(system:
/// hydratedAt:)` encoder so the row's `systemJSON` is genuine, round-trippable
/// JSON, not a hand-typed string. `scanned` stamps `systemScanned` on both the
/// row and the wrapped `StarSystem` in lockstep — `SystemDetail.systemScanned`
/// is a denormalization of exactly that `StarSystem` field
/// (`RawLocation.starSystem()`), so the two must never disagree in a fixture.
func seedSystemDetail(
    _ db: Database, system: String, scanned: Bool, belts: [Belt] = []
) throws {
    let starSystem = StarSystem(designation: system, systemScanned: scanned, belts: belts)
    let row = try SystemDetail(system: starSystem, hydratedAt: Date(timeIntervalSince1970: 0))
    try SystemDetail.insert { row }.execute(db)
}

/// A `systemDetails` row whose `systemJSON` is genuinely undecodable — for
/// proving a single malformed blob degrades locally rather than failing the
/// whole `WorldView.read`. Built from `SystemDetail`'s raw memberwise init
/// (not the `StarSystem`-encoding one, which can't produce broken JSON), so
/// `recon`/`systemScanned` are supplied directly.
func seedMalformedSystemDetail(_ db: Database, system: String) throws {
    try SystemDetail.insert {
        SystemDetail(
            designation: system, systemJSON: "{not valid json", recon: Recon.visited.rawValue,
            systemScanned: true, hydratedAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

// MARK: - Whole-world seeds

/// Where the growable world's print hub and its carriers stand. A location
/// inside the meshed `SOL` system (`SiteAssay.system(of:)` reads everything
/// before the first hyphen), which is what makes `WorldView.hubLocation`
/// non-nil — an off-mesh hub is deliberately invisible to the brain.
let growHubLocation = "SOL-3"

/// The smallest world the brain can actually grow from: `SOL` meshed by a live
/// relay, a print hub with `carriers` HEAVEN vessels parked alongside it, and
/// one unmeshed salvage system per entry in `salvage`.
///
/// **Every salvage system sits at exactly 5 ly from SOL**, on a different axis.
/// That is load-bearing, not decoration: `GrowRanking`'s key compares
/// `relaysRemaining` and then `hopDistance` BEFORE it ever looks at value, so
/// a test that expects the richest pile to rank first would otherwise be
/// decided by whichever system happened to be nearest. With the distances tied
/// exactly (each is a single axis offset of 5, so `sqrt(25)` with no floating
/// point residue) the sort is forced down to field 3 — magnitude — which is
/// what those tests mean to exercise. At most six systems; a seventh would
/// have no equidistant axis left and is not supported.
func seedGrowableWorld(
    _ db: Database,
    carriers: [String] = ["V1"],
    salvage: [String: Double] = ["VEGA": 3_200]
) throws {
    try seedRelay(db, code: "REL1", location: "SOL")
    try seedStar(db, designation: "SOL", x: 0, y: 0, z: 0)
    try seedPrintHub(db, code: "HUB1", location: growHubLocation)
    for code in carriers {
        try seedDevice(db, code: code, type: "heaven_vessel", location: growHubLocation)
    }
    let offsets: [(Double, Double, Double)] = [
        (5, 0, 0), (0, 5, 0), (0, 0, 5), (-5, 0, 0), (0, -5, 0), (0, 0, -5),
    ]
    for (index, entry) in salvage.sorted(by: { $0.key < $1.key }).enumerated() {
        let offset = offsets[index]
        try seedStar(db, designation: entry.key, x: offset.0, y: offset.1, z: offset.2)
        try seedSalvageAssay(
            db, id: "SITE-\(entry.key)", system: entry.key, totals: ["metal": entry.value]
        )
    }
}

// MARK: - Prune worlds

/// A hub-anchored `WorldView` for prune analysis.
///
/// `meshSystems` is DERIVED from the relay device rows via the production
/// predicate (`SalvageTargetPlanner.meshSystems(in:)`), never hand-set: a
/// fixture that could claim a system is meshed with no relay standing in it
/// would let a prune test pass against a world production cannot produce —
/// and prune's whole job is to judge relay device rows against the mesh they
/// create.
///
/// `hub` names the hub's SYSTEM. The resulting `hubLocation` follows
/// `WorldView.hubLocation`'s own rule: a location inside that system, but only
/// when the system is genuinely meshed — `nil` otherwise, which is exactly how
/// an off-mesh hub reaches the brain.
///
/// `surveyed` defaults to every system with a census position — a fully
/// surveyed neighbourhood, which is what a test means unless it is
/// specifically about unknown value. Prune treats an unsurveyed MESHED system
/// as a target (unknown ⇒ pinned), so the default keeps that clause quiet in
/// every test that is not about it.
///
/// `fleet` places non-relay devices (a vessel, a drone) at systems, which pin
/// them the same way value does.
///
/// `replicants` names the systems holding one of the account's replicants —
/// where command AUTHORITY stands, which prune must keep connected. It defaults
/// to empty rather than to `[hub]`: the co-location the old design assumed is
/// exactly what this parameter exists to be able to break, and a default that
/// silently asserted it would make the away-from-the-hub case unwritable.
func prunableWorld(
    positions: [String: Position],
    relays: [String: String],
    hub: String? = "SOL",
    salvage: [String: Double] = [:],
    belts: [String: [BeltInfo]] = [:],
    events: Set<String> = [],
    fleet: [String: String] = [:],
    surveyed: Set<String>? = nil,
    replicants: Set<String> = []
) -> WorldView {
    let relayDevices = relays.sorted { $0.key < $1.key }.map { code, system in
        deviceFixture(
            code: code, type: "ftl_relay", location: "\(system)-1",
            status: "relaying", features: ["relay"]
        )
    }
    let fleetDevices = fleet.sorted { $0.key < $1.key }.map { code, system in
        deviceFixture(code: code, type: "heaven_vessel", location: "\(system)-1")
    }
    let devices = relayDevices + fleetDevices
    let mesh = SalvageTargetPlanner.meshSystems(in: relayDevices)
    return WorldView(
        devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
        starPositions: positions,
        meshSystems: mesh,
        salvageUnits: salvage,
        eventSystems: events,
        hubLocation: hub.flatMap { mesh.contains($0) ? "\($0)-3" : nil },
        beltsBySystem: belts,
        surveyedSystems: surveyed ?? Set(positions.keys),
        replicantSystems: replicants,
        now: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - LocationEvent seeds

/// A live location event ("quest") sited at a location. `status` defaults to
/// `"active"` — the one `LocationEvent.isActive` matches.
func seedLocationEvent(
    _ db: Database, designation: String, location: String, status: String = "active"
) throws {
    try LocationEvent.insert {
        LocationEvent(
            designation: designation, location: location, status: status,
            firstSeenAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }.execute(db)
}

// MARK: - WorldView fixtures

/// Database-free `WorldView` fixtures for brain-logic tests (value ranking,
/// pathfinding) that reason purely over a snapshot and have no need to round
/// -trip through `GameDatabase` the way `WorldViewTests` does. Build one with
/// `.empty(meshSystems:)`, then layer in only the fields a test cares about
/// via `.with(...)`.
extension WorldView {
    /// An otherwise-blank snapshot — every collection empty, no hub, `now`
    /// pinned to the epoch for determinism. `meshSystems` is the one field
    /// worth defaulting at the call site since nearly every brain test names
    /// at least one already-meshed system.
    static func empty(meshSystems: Set<String> = []) -> WorldView {
        WorldView(
            devices: [:],
            starPositions: [:],
            meshSystems: meshSystems,
            salvageUnits: [:],
            eventSystems: [],
            hubLocation: nil,
            beltsBySystem: [:],
            now: Date(timeIntervalSince1970: 0)
        )
    }

    /// Returns a copy with the given fields overlaid; omitted parameters
    /// carry over from `self` unchanged. Only exposes the fields brain tests
    /// have needed so far — extend as later tasks need more.
    func with(
        salvageUnits: [String: Double]? = nil,
        eventSystems: Set<String>? = nil,
        starPositions: [String: Position]? = nil,
        beltsBySystem: [String: [BeltInfo]]? = nil,
        surveyedSystems: Set<String>? = nil
    ) -> WorldView {
        WorldView(
            devices: devices,
            starPositions: starPositions ?? self.starPositions,
            meshSystems: meshSystems,
            salvageUnits: salvageUnits ?? self.salvageUnits,
            eventSystems: eventSystems ?? self.eventSystems,
            hubLocation: hubLocation,
            beltsBySystem: beltsBySystem ?? self.beltsBySystem,
            surveyedSystems: surveyedSystems ?? self.surveyedSystems,
            now: now
        )
    }
}

// MARK: - Decision-only seam

extension Brain {
    /// The tick's `BrainDecision`, discarding the rest of its `BrainReport`.
    ///
    /// **Test-target API, deliberately.** Most of the brain suite asserts on
    /// what a tick DECIDED and has no interest in the ranked field or the
    /// rails, and `#expect(decision == .idle(reason:))` reads better than
    /// `#expect(report.decision == …)` fifteen times over. But production has
    /// exactly one caller of the plan loop — `DirectiveEngineCore.tickBrain()`
    /// — and it wants the whole report, so leaving this one-liner in
    /// `Sources/` would put a symbol there that only tests call.
    ///
    /// This is not a second implementation: it forwards to the real
    /// `report()`, so every test driving it drives the identical production
    /// path, database read and launch included.
    func evaluateOnce() async -> BrainDecision {
        await report().decision
    }
}
