//
//  MissionStepMachine.swift
//  Replicould — DirectiveEngine
//
//  A mission is a pure step machine: (directive state, world snapshot) → ONE
//  action. The engine owns every side effect — dispatching, writing rows,
//  waiting — and mission logic owns none, so the stall matrix (directives
//  design spec §8) is a table of plain function calls over fixtures.
//
//  No machines ship in this stage: Survey Run is Stage 4, Relay Run is Stage 5.
//  The engine's registry is empty in production and populated by fakes in tests.
//

import Foundation
import GameModels
import GameServices
import UniverseModels

/// What a mission wants to happen next. Exactly one per evaluation — a machine
/// that needs two things in a row expresses the second on the next tick, which
/// is what keeps every step recoverable after a relaunch (spec §11).
public enum MissionAction: Equatable, Sendable {
    /// POST a command, then move to `nextStep`. The engine routes it through
    /// `CommandGovernor`, so a deferral is invisible to the machine — it is
    /// simply asked again.
    case dispatch(kind: OperationKind, deviceCode: String, params: CommandParams, nextStep: String)
    /// Nothing to do yet — something server-side is still in progress. Expected
    /// and cheap; the engine takes no action at all.
    case wait
    /// Move to `nextStep` with no command at all. The machine's way of saying
    /// "this step's work was already done" — a target already reached, a
    /// directive already configured — without a pointless POST.
    case advanceStep(nextStep: String)
    /// Record the AMI controller this run is driving, then move on. The
    /// ownership handshake `Directive.controllerCode` exists for: it is what
    /// badges and locks the controller's built-in row while the mission runs.
    case assignController(deviceCode: String, nextStep: String)
    /// Re-read `locations/{star}`, persist it, then move to `nextStep`. The
    /// engine owns the I/O; the machine sees the fresh counts on its next
    /// evaluation. Presence-gated (403 away from the system), so only ever
    /// asked for after arrival.
    case refreshSystem(designation: String, nextStep: String)
    /// Re-read `GET /v1/locations` — the whole stockpile census in one request —
    /// persist it, then ask the machine once more against the fresh
    /// `WorldSnapshot.footprints`.
    ///
    /// **Resolved by the engine, reusing the SAME `reAsk` collapse
    /// `.refreshDevices` uses** (`DirectiveEngineCore.resolveFootprintRefresh`)
    /// — NOT a bare "refresh then move" the way this case worked before
    /// 2026-08-03. That earlier shape self-looped unbounded: a persistently
    /// unreadable census (a location genuinely never appearing in the
    /// response, or the refresh request itself always failing) made a
    /// same-step re-entry (`nextStep` equal to the current step) hammer the
    /// live API at the engine's full 5s tick rate forever, because
    /// `DirectiveExecutor.move` re-stamps `stepStartedAt` unconditionally on
    /// every re-entry — the same trap `same-step-dispatch-needs-tracked-op`
    /// documents for `.simple` verb dispatches, just for a refresh action
    /// instead of a dispatch.
    ///
    /// Two real fallbacks exist for when the re-ask still wants a refresh,
    /// because this case serves missions with different tolerances:
    /// - `thenStall` non-nil (e.g. `RelayRun.acquire`'s `.printStockShort`):
    ///   collapse to `.stall(thenStall)`, exactly like `.refreshDevices`. Use
    ///   this whenever the census gates something irreversible (a spend) —
    ///   a persistently-failing refresh must escalate through
    ///   `BrainDisposition.retry`'s bounded-retry-then-escalate, never retry
    ///   forever.
    /// - `thenStall` nil (`HaulRun.survey`): the resolver falls back to
    ///   `.advanceStep(nextStep: nextStep)` instead of `.wait` — preserving
    ///   the original "a transient failure must cost one cycle rather than
    ///   stranding a continuous run" contract for a caller whose `nextStep`
    ///   is always a DIFFERENT step, so it was never at risk of the self-loop
    ///   trap above and doesn't need to change behaviour to be safe.
    ///
    /// `nextStep` is that fallback destination — used only when `thenStall`
    /// is nil AND the re-ask still wants a refresh (or the post-refresh world
    /// read itself fails). A caller that always escalates may still name a
    /// sensible self-referential `nextStep` for documentation's sake; it will
    /// simply never be reached.
    case refreshFootprint(nextStep: String, thenStall: DirectiveAttentionReason?)
    /// "Before I believe this, read it." The engine re-reads each named device
    /// authoritatively — plus whatever those devices report stowed aboard them,
    /// because containment is a two-ended fact and one end alone can't settle it
    /// — then asks the machine again against the fresh snapshot. If the machine
    /// still wants a refresh, the engine stalls with `thenStall` instead.
    ///
    /// This exists because a `WorldSnapshot` is a read of local SQLite, and those
    /// rows are kept current by `.low` confirm-reads that the read-budget floor
    /// may defer indefinitely. Without this, a mission could not tell "the vessel
    /// is genuinely unstaged" from "we have not been allowed to look recently",
    /// and it stalled on the second as if it were the first — the run that
    /// prompted this went `noSurveyControllerAboard` on a controller the server
    /// had already re-stowed, and no amount of Retry could clear it, because
    /// Retry re-runs a pure function over the identical stale snapshot.
    ///
    /// The reads are `.high`, so they bypass the TTL and the budget floor: this
    /// is issued only where the alternative is a dead stop that needs a human.
    /// Exactly ONE refresh-and-re-ask per evaluation — never a loop.
    ///
    /// **Name every device the answer depends on.** The engine expands each
    /// named device into whatever that CARRIER reports stowed aboard it, but a
    /// carrier's `stowed_devices` blob is not a reliable inverse of the
    /// children's own `stowedInDeviceCode` columns — a real vessel's blob listed
    /// one unrelated device while six drones claimed to be aboard it. Relying on
    /// the expansion to reach a row you are judging is how a check ends up
    /// permanently unsatisfiable.
    ///
    /// `thenStall: nil` means "if the re-ask still wants a refresh, just wait".
    /// That is the right fallback whenever the unresolved state is *expected*
    /// rather than wrong — a recall genuinely still in flight is not a fault,
    /// and stalling on it would demand a human for something that fixes itself.
    case refreshDevices(deviceCodes: [String], thenStall: DirectiveAttentionReason?)
    /// The same demand, scoped to a whole system instead of a device list:
    /// `GET devices?location=<designation>` in ONE request, reconciled, then the
    /// machine is asked again exactly as `.refreshDevices` does.
    ///
    /// Use this to ask "who is PRESENT at this place" — one request, and one that
    /// does not grow with the fleet. In-transit devices are included: a
    /// travelling device reports `location: null` yet the server still matches it
    /// to the system (probed live 2026-07-27).
    ///
    /// **It cannot answer anything about a STOWED device, and must never gate on
    /// one.** Stowing clears a device's location, which drops it out of the
    /// location index entirely: with six drones stowed aboard a vessel,
    /// `GET devices?location=ESELLUSAU` returned exactly ONE row — the vessel
    /// (probed live 2026-07-29). The unfiltered fleet list returned all six with
    /// their stow columns intact, so this is a property of the scope, not of
    /// staleness. A gate whose success condition is "stowed" therefore has its
    /// evidence erased by the very thing it waits for, and since the absent rows
    /// are never written, any "when did we last look" clock keyed on their
    /// `updatedAt` never advances either — the probe re-fires forever. That is
    /// the shape of the recall stall this case used to cause; it now names its
    /// drones with `.refreshDevices` instead, which reads each row directly.
    ///
    /// So: this case for presence, `.refreshDevices` for containment.
    case refreshDevicesInSystem(designation: String, thenStall: DirectiveAttentionReason?)
    /// The same demand as `.refreshDevices`, scoped to a TAG instead of a device
    /// list: `GET devices/tags/{tag}` in ONE request, reconciled, then the
    /// machine is asked again.
    ///
    /// Prefer this wherever a mission owns a tagged fleet. `.refreshDevices`
    /// costs one request per named device and can only refresh rows the mission
    /// already knows to name; a tag read is one request whatever the fleet size
    /// and returns members the local rows had not yet associated with the run.
    ///
    /// Unlike `.refreshDevicesInSystem` it CAN answer questions about stowed
    /// devices — a tag filter never touches `location`, so stowing does not
    /// erase the row from the scope. That is precisely the gate
    /// `.refreshDevicesInSystem` cannot serve: verified live 2026-07-30, a fleet
    /// tagged `auto:survey` was caught mid-flight with six drones and a
    /// controller stowed aboard a travelling vessel — all eight devices reported
    /// `location: null`, yet the tag query returned every one of them with
    /// `stowedInDeviceCode` intact.
    ///
    /// **Never follow this with a prune.** Only devices carrying `tag` are
    /// visible in the response — every untagged device is absent by
    /// construction — so treating that absence as "device gone" would delete
    /// the fleet.
    ///
    /// Bounded to one round, exactly like the other refresh cases: if the
    /// re-asked machine wants another refresh, the engine stalls with
    /// `thenStall` — or waits, when that is nil.
    case refreshFleet(tag: String, thenStall: DirectiveAttentionReason?)
    /// Replace `deviceCode`'s ENTIRE tag set with `tags`, then move to
    /// `nextStep` regardless of outcome. Modeled on `.refreshSystem`: I/O
    /// best-effort, then a plain step move — there is nothing to re-ask the
    /// machine about, so unlike `.refreshDevices`/`.refreshFleet` this never
    /// routes through a second evaluation.
    ///
    /// `DevicesClient.updateTags` is DECLARATIVE — it replaces the whole set —
    /// so `tags` must be the device's FULL remaining set, computed by the
    /// machine from the row it already read. Sending just the tag being
    /// dropped, or `[]`, would silently wipe every other tag the operator put
    /// on the device.
    ///
    /// Best-effort by contract, same reasoning as `.refreshSystem`: this exists
    /// to detach housekeeping (a relay that just became permanent
    /// infrastructure, say) from a fleet tag, and a transient PATCH failure
    /// must never strand a run whose real work already succeeded. The engine
    /// still confirm-reads the device afterward so the local row doesn't sit
    /// stale, mirroring the tag editor's own PATCH-then-refresh (B4).
    case setDeviceTags(deviceCode: String, tags: [String], nextStep: String)
    /// Pause and surface. The engine sets `needsAttention` plus the typed reason
    /// and stops evaluating until the user resolves it. Never auto-retried at
    /// the mission layer (spec §8).
    case stall(DirectiveAttentionReason)
    /// The queue is empty and this is a CONTINUOUS run: pick the next system
    /// from the census, append it to `targets`, and carry on. The engine owns
    /// the read and the write; the machine sees the extended queue when it is
    /// re-asked.
    ///
    /// Resolved by `DirectiveEngineCore` rather than the executor, like
    /// `.refreshDevices`, because it needs I/O plus a second call into the
    /// machine.
    ///
    /// It differs from the refresh cases in one way that matters: they cannot
    /// change the directive ROW, so they re-ask with the same `Directive` value.
    /// This one appends to `targets`, so its re-asked action must be applied to
    /// the freshly-read row — applying it to the pre-write value rolls the
    /// append straight back (see `DirectiveEngineCore.Resolution`).
    ///
    /// Bounded to one round: a second `.extendQueue` from the re-ask means the
    /// planner found nothing left, which resolves to `.done`.
    case extendQueue(centre: String)
    /// This target is finished; move to the next one.
    case advanceTarget
    /// The whole run is finished.
    case done
}

/// Everything a mission's target planner may read, gathered by the engine in
/// one database round so the planner itself stays a pure function.
///
/// A plain value rather than a set of closures on purpose: a machine that could
/// ask for more data could ask for it *conditionally*, and the whole reason
/// missions are testable as fixtures is that they cannot reach out.
public struct RoamContext: Equatable, Sendable {
    /// The census row for the run's roam centre, or nil when the census has
    /// never heard of that designation.
    public let centre: Star?
    /// Where the vessel is right now, or nil when it is stowed or in transit —
    /// both of which clear `location`, so "unknown" is the honest answer rather
    /// than a stale coordinate.
    public let vessel: Position?
    /// The whole census.
    public let stars: [Star]
    /// Stored per-site assay totals, whole table. Tiny by construction, and the
    /// only record of a site's ORIGINAL units (the catalogue blob never carries
    /// them).
    public let assays: [SiteAssay]
    /// Every device row. Mesh membership is derived from these (see
    /// `SalvageTargetPlanner.meshSystems(in:)`), never from `ftlLinks`.
    public let devices: [Device]
    /// Every system this run has already aimed at — `Directive.targets`, which
    /// is append-only history for exactly this purpose.
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
///
/// The two empty answers are deliberately distinct, because the right response
/// differs by mission. A Survey Run exhausts the census *permanently* — every
/// star scanned is a finish line — while a Salvage Run's frontier is a moving
/// snapshot: the survey roam keeps uncovering salvage (spec §7 measured the
/// catalogue growing during the hour the design was written), and a relay
/// planted elsewhere can bring a previously-unreachable system into range. For
/// that run, "nothing reachable" is a lull, not an ending — and finishing it
/// would contradict both the launcher's copy and the design's own rule that the
/// run never asks the operator for anything (spec §1, and §6's matching "wait —
/// not stall" for the Haul Run).
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
    /// advancing the queue, so the machine owns its own step vocabulary —
    /// which is why `Directive.step` is a bare `String` and not an enum.
    var firstStep: String { get }
    /// The single next action. MUST be pure: no I/O, no clock reads (use
    /// `world.now`), no randomness.
    func nextAction(directive: Directive, world: WorldSnapshot) -> MissionAction
    /// Where this run goes next when `.extendQueue` asks. MUST be pure, exactly
    /// like `nextAction` — the engine gathers the context and owns every read.
    ///
    /// A protocol requirement rather than a `switch directive.kind` in the
    /// engine: a survey roam ranks by unsurveyed-ness in sliding bands and a
    /// salvage run ranks by mesh reachability and assayed units, and those are
    /// as much a part of a mission's procedure as its steps are. `MissionRegistry`
    /// exists precisely so a new mission is one registration rather than an edit
    /// to every place the engine names a kind, and a kind-switch here would put
    /// that coupling straight back. Deliberately has NO default implementation:
    /// a machine that forgot to answer would otherwise silently finish (or
    /// silently idle) every continuous run of its kind.
    func plan(_ context: RoamContext) -> RoamPlan
}
