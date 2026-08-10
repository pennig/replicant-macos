//
//  MissionStepMachine.swift
//  Replicould — DirectiveEngine
//
//  A mission is a pure step machine: (directive state, world snapshot) → ONE
//  action. The engine owns every side effect — dispatching, writing rows,
//  waiting — and mission logic owns none.
//

import Foundation
import GameModels
import GameServices
import UniverseModels

/// What a mission wants to happen next. Exactly one per evaluation — a machine
/// that needs two things in a row expresses the second on the next tick.
public enum MissionAction: Equatable, Sendable {
    /// POST a command, then move to `nextStep`. The engine routes it through
    /// `CommandGovernor`, so a deferral is invisible to the machine — it is
    /// simply asked again.
    case dispatch(kind: OperationKind, deviceCode: String, params: CommandParams, nextStep: String)
    /// Nothing to do yet — something server-side is still in progress. The engine
    /// takes no action at all, and this is the only action that does not re-stamp
    /// `stepStartedAt`, so a step deadline accumulates only under `.wait`.
    case wait
    /// Move to `nextStep` with no command — this step's work was already done.
    case advanceStep(nextStep: String)
    /// Record the AMI controller this run is driving in `Directive.controllerCode`,
    /// then move to `nextStep`. That badges and locks the controller's built-in row.
    case assignController(deviceCode: String, nextStep: String)
    /// Record the relay this run has taken possession of in
    /// `Directive.claimedRelayCode`, then move to `nextStep`. Carries no lease:
    /// it fixes which relay the run means, nothing about who may command it.
    case claimRelay(deviceCode: String, nextStep: String)
    /// Re-read `locations/{star}`, persist it, then move to `nextStep`. Best-effort:
    /// the endpoint 403s for a system the census has never marked explored, and the
    /// engine swallows that — a stale cache only costs the machine one evaluation.
    case refreshSystem(designation: String, nextStep: String)
    /// Re-read one body (`LocationsClient.hydrateBody`), persist it, then move to
    /// `nextStep`. Best-effort like `.refreshSystem` — and the only read that can
    /// observe a DELISTED salvage site, which the star-level payload never carries.
    case refreshBody(system: String, body: String, nextStep: String)
    /// Re-read the whole stockpile census, persist it, then ask the machine
    /// again against the fresh `world.footprints`. Resolved by the engine.
    ///
    /// - `thenStall` non-nil: an unresolved re-ask collapses to `.stall`.
    /// - `thenStall` nil: it falls back to `.advanceStep(nextStep:)`.
    case refreshFootprint(nextStep: String, thenStall: DirectiveAttentionReason?)
    /// Re-read each named device authoritatively — plus whatever those devices
    /// report stowed aboard them — then ask the machine again against the fresh
    /// snapshot. Reads are `.high`, bypassing the TTL and read-budget floor.
    /// Exactly one refresh-and-re-ask per evaluation, never a loop.
    ///
    /// Name every device the answer depends on: a carrier's `stowed_devices` is
    /// not a reliable inverse of its children's `stowedInDeviceCode`, so relying
    /// on expansion to reach a row you are judging can leave a check permanently
    /// unsatisfiable.
    ///
    /// - `thenStall` nil: an unresolved re-ask waits instead of stalling.
    case refreshDevices(deviceCodes: [String], thenStall: DirectiveAttentionReason?)
    /// The same demand scoped to a whole system: `GET devices?location=<designation>`
    /// in ONE request, reconciled, then the machine is asked again. In-transit
    /// devices are included.
    ///
    /// It answers PRESENCE only. Stowing clears a device's location, dropping it
    /// out of the location index entirely, so this cannot see a stowed device and
    /// must never gate on one. Use `.refreshDevices` for containment.
    ///
    /// - `thenStall` nil: an unresolved re-ask waits instead of stalling.
    case refreshDevicesInSystem(designation: String, thenStall: DirectiveAttentionReason?)
    /// The same demand scoped to a TAG: `GET devices/tags/{tag}` in ONE request,
    /// reconciled, then the machine is asked again. One request whatever the fleet
    /// size, and it returns members the local rows had not yet associated with the
    /// run. Unlike `.refreshDevicesInSystem` it CAN answer questions about stowed
    /// devices — a tag filter never touches `location`, so stowing does not erase
    /// the row from the scope.
    ///
    /// **Never follow this with a prune.** Only devices carrying `tag` appear in
    /// the response, so treating that absence as "device gone" deletes the fleet.
    ///
    /// - `thenStall` nil: an unresolved re-ask waits instead of stalling.
    case refreshFleet(tag: String, thenStall: DirectiveAttentionReason?)
    /// Replace `deviceCode`'s ENTIRE tag set with `tags`, then move to `nextStep`
    /// regardless of outcome — best-effort I/O and a plain step move, never a
    /// second evaluation. The engine confirm-reads the device afterward.
    ///
    /// `DevicesClient.updateTags` is DECLARATIVE, so `tags` must be the device's
    /// FULL remaining set, computed by the machine from the row it already read.
    /// Sending just the tag being dropped, or `[]`, wipes every other tag.
    case setDeviceTags(deviceCode: String, tags: [String], nextStep: String)
    /// Pause and surface. The engine sets `needsAttention` plus the typed reason
    /// and stops evaluating until the user resolves it. Never auto-retried.
    /// `detail` names the specific subject (a body designation, a server message).
    case stall(DirectiveAttentionReason, detail: String?)
    /// The queue is empty and this is a CONTINUOUS run: pick the next system from
    /// the census around `centre`, append it to `targets`, and carry on. Resolved by
    /// `DirectiveEngineCore`, which owns the read and the write.
    ///
    /// This one changes the directive ROW, so its re-asked action must be applied
    /// to the freshly-read row or the append rolls straight back (see
    /// `DirectiveEngineCore.Resolution`). Bounded to one round: a second
    /// `.extendQueue` resolves to `.done`.
    case extendQueue(centre: String)
    /// This target is finished; move to the next one.
    case advanceTarget
    /// The whole run is finished.
    case done
}

extension MissionAction {
    /// A detail-less stall, so the common construction site stays `.stall(reason)`.
    public static func stall(_ reason: DirectiveAttentionReason) -> MissionAction {
        .stall(reason, detail: nil)
    }
}

/// Everything a mission's target planner may read, gathered by the engine in one
/// database round so the planner itself stays a pure function.
public struct RoamContext: Equatable, Sendable {
    /// The census row for the run's roam centre, or nil when the census has never
    /// heard of that designation.
    public let centre: Star?
    /// Where the vessel is right now, or nil when it is stowed or in transit —
    /// both of which clear `location`.
    public let vessel: Position?
    /// The whole census.
    public let stars: [Star]
    /// Stored per-site assay totals, whole table. The only record of a site's
    /// ORIGINAL units; the catalogue blob never carries them.
    public let assays: [SiteAssay]
    /// Every device row. Mesh membership is derived from these (see
    /// `SalvageTargetPlanner.meshSystems(in:)`), never from `ftlLinks`.
    public let devices: [Device]
    /// Every system this run has already aimed at — `Directive.targets`, append-only.
    public let attempted: Set<String>

    public init(
        centre: Star?,
        vessel: Position?,
        stars: [Star],
        assays: [SiteAssay],
        devices: [Device],
        attempted: Set<String>
    ) {
        self.centre = centre
        self.vessel = vessel
        self.stars = stars
        self.assays = assays
        self.devices = devices
        self.attempted = attempted
    }
}

/// What a mission's planner decided when its queue ran dry.
public enum RoamPlan: Equatable, Sendable {
    /// Aim at this system next.
    case target(String)
    /// Nothing reachable right now, but more may appear. Idle and re-ask later.
    case idle
    /// Nothing left, and nothing more is coming. Finish the run.
    case exhausted
}

/// One mission kind's procedure.
public protocol MissionStepMachine: Sendable {
    /// The directive kind this machine runs.
    var kind: DirectiveKind { get }
    /// The step a freshly-started target begins on. The engine writes it when
    /// advancing the queue, so the machine owns its own step vocabulary.
    var firstStep: String { get }
    /// The single next action. MUST be pure: no I/O, no clock reads (use
    /// `world.now`), no randomness.
    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction
    /// Where this run goes next when `.extendQueue` asks. MUST be pure, exactly
    /// like `nextAction` — the engine gathers the context and owns every read.
    /// Deliberately has NO default implementation: a machine that forgot to answer
    /// would otherwise silently finish, or silently idle, every continuous run.
    func plan(_ context: RoamContext) -> RoamPlan
}
