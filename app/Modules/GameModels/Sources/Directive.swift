//
//  Directive.swift
//  Replicould — Directives feature
//
//  A custom directive (a multi-step mission the app executes) and the shared
//  audit trail both directive kinds write to. Built-in AMI directives get NO
//  row here on purpose: the server owns that state and it is already carried on
//  the `Device` row (`ami_directive`), so mirroring it locally would invent a
//  drift bug. `DirectiveLogEntry` is the one thing both kinds share — hence its
//  optional `directiveID` (custom) / `deviceCode` (built-in) pair.
//
//  Both tables are account-scoped and wiped on logout (see
//  `ReplicantApp.registerSessionCleanup`).
//

import Foundation
import SQLiteData

/// Which baked-in procedure a custom directive runs.
public enum DirectiveKind: String, Codable, Equatable, Sendable, CaseIterable, QueryBindable {
    case surveyRun
    case relayRun
    case salvageRun
    case haulRun
    /// Keeps idle FTL relays standing at the print hub, ahead of demand.
    /// Owned by the HUB device, not a carrier — a print needs no vessel.
    case restockRun
    case mineFleetPrint
    case mineRun
    /// A convoy fulfilling one location event: deliver, commit, plant a beacon.
    case eventRun
    /// Stands up the convoy's replicant courier: print a container, replicate
    /// into the spare matrix, stow it aboard.
    case eventCourierPrint

    /// The list row's label, e.g. "Survey Run".
    public var title: String {
        switch self {
        case .surveyRun: "Survey Run"
        case .relayRun: "Relay Run"
        case .salvageRun: "Salvage Run"
        case .haulRun: "Haul Run"
        case .restockRun: "Relay Restock"
        case .mineFleetPrint: "Mine Fleet Print"
        case .mineRun: "Mine Run"
        case .eventRun: "Event Run"
        case .eventCourierPrint: "Event Courier Print"
        }
    }
}

/// A custom directive's lifecycle state. `needsAttention` is the pause-and-surface
/// stall state — the engine never improvises or auto-retries at the mission layer.
public enum DirectiveStatus: String, Codable, Equatable, Sendable, CaseIterable, QueryBindable {
    case running
    case needsAttention
    case paused
    case completed
    case cancelled

    /// running + needsAttention + paused — a resumable directive whose log a
    /// live or later-resumed mission may still read (see `DirectiveLogRetention`).
    public static let openCases: [DirectiveStatus] = [.running, .needsAttention, .paused]

    /// completed + cancelled — a run that owns no device, so it is the only
    /// kind `Directive.purgeFinished` may destroy.
    public static let finishedCases: [DirectiveStatus] = [.completed, .cancelled]

    /// The pane's label. Without this the detail view renders the raw case name
    /// ("needsAttention") straight at the user.
    public var displayName: String {
        switch self {
        case .running: "Running"
        case .needsAttention: "Needs Attention"
        case .paused: "Paused"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        }
    }
}

/// Why a directive stalled into `.needsAttention`. A closed set (design spec
/// §8) — the engine pauses and surfaces rather than improvising, so every
/// stall it can produce has a name here.
public enum DirectiveAttentionReason: String, Codable, Equatable, Sendable, CaseIterable, QueryBindable {
    /// No relay is co-located with the vessel for a Relay Run step.
    case noRelayCoLocated
    /// No survey drone is aboard the vessel for a Survey Run step.
    case noSurveyDroneAboard
    /// No AMI survey controller is stowed aboard the vessel. Staging one is the
    /// player's job — a Survey Run uses what is already aboard and adopted, it
    /// never stows or adopts (adoption is persistent state that would outlive
    /// the mission).
    case noSurveyControllerAboard
    /// The device the step needs is unreachable (offline/unknown state).
    case unreachableDevice
    /// The `locations/{star}` backstop read disagrees with a completion event.
    case surveyIncomplete
    /// The AMI's post-survey recall did not put every adopted drone back aboard
    /// the vessel within the grace window. Departing anyway strands them in the
    /// system just surveyed — which is exactly how six drones were lost at
    /// POLARISUM on 2026-07-26.
    case dronesNotRecovered
    /// The AMI controller accepted `launch` but deployed no devices — the
    /// survey it was supposed to start can never begin.
    case launchDeployedNothing
    /// The server rejected the step's command.
    case commandRejected
    /// A transport error or an undeclared HTTP status kept the last command
    /// from landing, and the bounded in-step retry ran out.
    case commandFailed
    /// No AMI mining controller is stowed aboard the vessel. Staging is the
    /// player's job — a Salvage Run uses what is already aboard and adopted.
    case noMiningControllerAboard
    /// The mining controller has no adopted drone stowed aboard the vessel.
    case noMiningDroneAboard
    /// The vessel is out of FTL relays and the next target needs one. It has
    /// returned to base; stow relays aboard and retry.
    case awaitingRelayRestock
    /// The relay was deployed but never came up — `activate` was rejected, or
    /// no `relay.activated` arrived before the backstop.
    case relayActivationFailed
    /// A Salvage Run reached `configuring` but the target system's catalogue
    /// blob (`SystemDetail`) never arrived — the row is missing, or failed to
    /// decode. Never inferred from a completed survey or a finished mine:
    /// this is specifically "we don't know yet", surfaced only once the
    /// backstop gives up waiting on it, so the run can't mistake absence for
    /// "nothing left" and silently skip a system that may hold real salvage.
    case salvageSystemUnresolved
    /// A `gather_salvage` cycle finished and its drones came home, but the body
    /// it worked is still on offer — even after an authoritative re-read of the
    /// system. Without this the mining loop's only terminator was a single
    /// `salvage.depleted` SSE frame, and a dropped one meant the run re-launched
    /// the same body forever.
    case salvageBodyNotDepleted
    /// The vessel finished travelling to a body but its local row never
    /// refreshed with the new position. The run cannot prove where the vessel
    /// is and must not re-command travel at it.
    case vesselPositionUnconfirmed
    /// No AMI transport controller carries the run's fleet tag, so the Haul Run
    /// has nothing to drive. A configuration error rather than a lull — an empty
    /// *frontier* idles, but an empty *fleet* can never resolve itself.
    case noHaulControllerTagged
    /// The brain's resource-reserve rail vetoed a print: some resource type at
    /// the hub sits below its reserve floor, so the print never went out.
    /// Self-supply (mine/salvage) refills the hub over time, so this clears on
    /// its own as stock recovers — it never needs an operator.
    case printStockShort
    /// The service bots were still working when the repair deadline expired, so
    /// the fleet would otherwise depart mid-repair.
    case repairUnfinished
    /// A deployed service bot never came up on an ACTIVE `service` directive —
    /// `set_directive` was reissued past the retry bound and it still reads
    /// some other directive, or `service` but paused, so it repairs nothing.
    case serviceBotNotArmed
    /// A deployed service bot never made it back aboard before the recall
    /// deadline — distinct from `dronesNotRecovered`, which is the survey
    /// drones' own recall.
    case serviceBotNotRecovered
    /// A service bot the run enrolled is standing in a system the vessel has
    /// already left, where no recall reaches it. Distinct from
    /// `serviceBotNotRecovered` because Skip abandons it rather than helping.
    case serviceBotStranded
    /// The mining controller's `gather_salvage` reads paused while its drones
    /// are still deployed. A paused directive mines nothing and never emits the
    /// completion the run waits on, so the wait would otherwise never end.
    case miningDirectivePaused
    /// The mining controller did not get back aboard the vessel before the run
    /// needed to move on. Its recall leg outlives `directive.completed`, which
    /// tracks the DRONES, so departing now leaves it chasing the vessel.
    case miningControllerNotRecovered
    /// The mine fleet the run was launched for is no longer complete at the hub —
    /// a member was taken, lost, or re-tasked between siting and attachment.
    case mineFleetIncomplete
    /// The convoy delivered its option's devices and resources, but the event's
    /// own progress never reported them met.
    case eventCriteriaUnmet
    /// The server refused the event commit.
    case eventCommitRejected
    /// The courier's container is standing, but no replicant is free to host in
    /// it. Replication is the operator's to perform.
    case awaitingCourierReplication
    /// A print outlived its deadline with nothing the run could order meanwhile
    /// — every printer busy, or the whole bill in flight and not completing.
    /// Usually a queued job blocked on component devices.
    case printBlockedOnComponents
    /// The option's component tree reaches a device type the account holds no
    /// blueprint for, so the payload cannot be built at any price.
    case eventOptionBlueprintMissing
    /// Two or more options are buildable and none is picked, so the run has no
    /// payload to work toward. Only the operator can settle it.
    case eventOptionNotChosen
    /// The option's outstanding resources do not fit the convoy's freighter, and
    /// the run carries exactly one. Detail names the units against the hold.
    case eventLoadExceedsHold

    /// The stall panel's headline.
    public var displayName: String {
        switch self {
        case .noRelayCoLocated: "No relay aboard"
        case .noSurveyDroneAboard: "No survey drone aboard"
        case .noSurveyControllerAboard: "No survey controller aboard"
        case .unreachableDevice: "Device unreachable"
        case .surveyIncomplete: "Survey incomplete"
        case .dronesNotRecovered: "Drones not recovered"
        case .launchDeployedNothing: "Launch deployed nothing"
        case .commandRejected: "Command rejected"
        case .commandFailed: "Command failed"
        case .noMiningControllerAboard: "No mining controller aboard"
        case .noMiningDroneAboard: "No mining drone aboard"
        case .awaitingRelayRestock: "Out of FTL relays"
        case .relayActivationFailed: "Relay didn't come up"
        case .salvageSystemUnresolved: "System data unavailable"
        case .salvageBodyNotDepleted: "Salvage body isn't draining"
        case .vesselPositionUnconfirmed: "Vessel position unconfirmed"
        case .noHaulControllerTagged: "No haul controller tagged"
        case .printStockShort: "Resource stock too low to print"
        case .repairUnfinished: "Repair not finished"
        case .serviceBotNotArmed: "Service bot not armed"
        case .serviceBotNotRecovered: "Service bot not recovered"
        case .serviceBotStranded: "Service bot left behind"
        case .miningDirectivePaused: "Mining directive paused"
        case .miningControllerNotRecovered: "Mining controller not recovered"
        case .mineFleetIncomplete: "Mine fleet incomplete"
        case .eventCriteriaUnmet: "Event objectives not met"
        case .eventCommitRejected: "Event commit rejected"
        case .awaitingCourierReplication: "Courier needs a replicant"
        case .printBlockedOnComponents: "Print blocked on components"
        case .eventOptionBlueprintMissing: "Blueprint not unlocked"
        case .eventOptionNotChosen: "Event option not chosen"
        case .eventLoadExceedsHold: "Load exceeds the freighter's hold"
        }
    }

    /// Whether a stall's `detail` carries a designation code, which the panel
    /// sets in monospace. A device type is prose and must not be, so the one
    /// reason naming device types opts out.
    public var detailIsDesignation: Bool { self != .eventOptionBlueprintMissing }

    /// What the user can do about it. Staging is the player's job — a Survey Run
    /// never stows or adopts — so these name the fix rather than implying the
    /// engine will sort it out on its own.
    public var guidance: String {
        switch self {
        case .noRelayCoLocated:
            "Stow an FTL relay aboard the vessel, then retry."
        case .noSurveyDroneAboard:
            "Stow a survey drone aboard the vessel and adopt it with the controller, then retry."
        case .noSurveyControllerAboard:
            "Stow an AMI survey controller aboard the vessel, then retry."
        case .unreachableDevice:
            "The mission's device is missing from the fleet. Cancel the run, or retry once it's back."
        case .surveyIncomplete:
            "The controller reported finishing, but the system isn't fully scanned. Retry to keep waiting, or skip this target."
        case .dronesNotRecovered:
            "Some survey drones are still out after the recall. Retry once they're stowed aboard, or the vessel will leave without them."
        case .launchDeployedNothing:
            "The controller launched but deployed no drones — check that its adopted drones are stowed aboard the vessel, then retry."
        case .commandRejected:
            "The server refused the last command. Check the device, then retry or skip this target."
        case .commandFailed:
            "The server or the connection failed while sending the last command, and the engine has stopped retrying it. Retry once the service is reachable, or skip this target."
        case .noMiningControllerAboard:
            "Stow an AMI mining controller aboard the vessel, then retry."
        case .noMiningDroneAboard:
            "Stow a mining drone aboard the vessel and adopt it with the controller, then retry."
        case .awaitingRelayRestock:
            "The vessel is at base with no relays left. Stow FTL relays aboard, then retry."
        case .relayActivationFailed:
            "The relay was deployed but never started relaying. Check it at the Lagrange point, then retry or skip this target."
        case .salvageSystemUnresolved:
            "The system's catalogue data never loaded after arrival. Retry to fetch it again, or skip this target."
        case .salvageBodyNotDepleted:
            "A salvage run finished on this body but it still reads as holding salvage. Check the site, then retry to work it again or skip this target."
        case .vesselPositionUnconfirmed:
            "The vessel finished travelling but its position never refreshed. Retry to re-read it, or cancel the run."
        case .noHaulControllerTagged:
            "No AMI transport controller carries the \"\(FleetTag(goal: .haul).string)\" tag. Tag one from the device inspector, then retry."
        case .printStockShort:
            "The hub doesn't have enough of a resource to print without dropping below reserve. It clears on its own as stock recovers — retry once supply catches up."
        case .repairUnfinished:
            "The service bots didn't finish repairing before the deadline. Retry once they've finished, or skip this target."
        case .serviceBotNotArmed:
            "A service bot won't hold an active \"service\" directive. Check it in the device inspector, then retry or skip this target."
        case .serviceBotNotRecovered:
            "A service bot didn't stow before the recall deadline. Retry once it's aboard, or skip this target."
        case .serviceBotStranded:
            "A service bot is in a system the vessel has already left, so no recall reaches it. Fly it back to the vessel yourself, then retry. Don't skip — skipping departs without it again."
        case .miningDirectivePaused:
            "The mining controller's salvage directive is paused, so its deployed drones are idle. Resume it from the device inspector — that recalls the drones — then retry."
        case .miningControllerNotRecovered:
            "The mining controller is still travelling back to the vessel. Retry once it's stowed aboard; departing without it strands it in this system."
        case .mineFleetIncomplete:
            "The \(FleetTag(goal: .mine).string) fleet at the hub is missing members. Re-run Mine Fleet Print to top it up, or re-tag the missing devices, then retry."
        case .eventCriteriaUnmet:
            "Check the event's requirements against what the convoy delivered, then retry."
        case .eventCommitRejected:
            "The server refused the commit. Retry once a replicant is confirmed on site."
        case .awaitingCourierReplication:
            "Stow the empty replicant matrix into the matrix container at the depot, then replicate into it there — the container is the cradle. If you replicated into a matrix elsewhere, move that one into the container instead. Retry once the container holds the new replicant."
        case .printBlockedOnComponents:
            "A print at the depot outlived its deadline and the run had nothing else it could order — most often a queued job waiting on component devices it doesn't have. Retry once that print clears, or cancel the one blocking the queue."
        case .eventOptionBlueprintMissing:
            "The option's build tree needs the blueprints named above and the account holds none of them, so no amount of printing reaches it. Unlock those blueprints, or pick an option that avoids them under Location Events, then retry."
        case .eventOptionNotChosen:
            "The event offers more than one buildable option and none is picked, so the run has no payload to work toward. Pick one under Missions, then retry. Unlocking a blueprint mid-run can reopen a choice the run started with only one answer to."
        case .eventLoadExceedsHold:
            "The option still needs more resource units than the convoy's one cargo freighter can hold, so no single collection reaches it. A run carries one freighter and makes one trip, so this option is out of reach until it does otherwise — pick an option the hold can take under Missions, or cancel the run."
        }
    }
}

/// How the brain (as an automated operator) responds to a directive that has
/// halted-and-surfaced. The mission layer's halt matrix is unchanged; this is
/// purely the brain's response classification (see brain-executor-seam.md).
public enum BrainDisposition: String, Codable, Sendable, Equatable {
    /// Self-corrects on a re-read — bounded auto-`retry`, budget timeline-derived, then escalate.
    case retry
    /// Needs a power the brain lacks (staging / adoption / replacement / tagging),
    /// or an executor exhausted something it can't self-compose — surface to operator.
    case escalate
    /// An expected operator choice (the HITL seam) — surface as a decision request.
    case decisionRequest
}

public extension DirectiveAttentionReason {
    /// The brain never invents a response; it classifies the reason and drives
    /// only `{retry, cancel}`. `skipTarget`/`pause`/`resume` stay operator-only.
    var brainDisposition: BrainDisposition {
        switch self {
        case .surveyIncomplete, .unreachableDevice, .vesselPositionUnconfirmed,
             .salvageSystemUnresolved, .salvageBodyNotDepleted, .commandRejected,
             .commandFailed, .relayActivationFailed, .printStockShort,
             .eventCommitRejected, .printBlockedOnComponents:
            return .retry
        case .noSurveyControllerAboard, .noSurveyDroneAboard, .noMiningControllerAboard,
             .noMiningDroneAboard, .noRelayCoLocated, .dronesNotRecovered,
             .launchDeployedNothing, .noHaulControllerTagged, .awaitingRelayRestock,
             .repairUnfinished, .serviceBotNotArmed, .serviceBotNotRecovered,
             .serviceBotStranded,
             .miningDirectivePaused, .miningControllerNotRecovered, .mineFleetIncomplete,
             .eventCriteriaUnmet, .awaitingCourierReplication, .eventOptionBlueprintMissing,
             .eventLoadExceedsHold:
            return .escalate
        case .eventOptionNotChosen:
            return .decisionRequest
        }
    }
}

/// One custom mission instance. Policy-ready by design: nothing here records
/// whether a click or a future standing policy created the row.
@Table
public struct Directive: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var id: String
    public var kind: DirectiveKind
    public var status: DirectiveStatus
    /// The vessel carrying out the mission.
    public var deviceCode: String
    /// The AMI controller this mission is currently driving, once it has issued
    /// `set_directive` on one. Nil before that step, and after the mission
    /// clears it.
    ///
    /// This is what makes the resulting built-in row's ownership knowable: a
    /// server-run directive on `controllerCode` is the engine's own work, not
    /// something the user should Reconfigure or Clear out from under a step
    /// that is waiting on it. `deviceCode` cannot stand in for this — a Survey
    /// Run's vessel and its controller are two different devices.
    public var controllerCode: String?
    /// The centre of a CONTINUOUS run, or nil for a fixed queue.
    ///
    /// Non-nil is the whole switch: `SurveyRun.preflight` extends the queue
    /// instead of finishing when this is set, so the run surveys outward
    /// indefinitely in bands around this system (see `SurveyRoamPlanner`).
    ///
    /// A designation rather than a coordinate, because the census row is the
    /// authority on where a system is and copying its position here would let
    /// the two drift.
    public var roamCentre: String?
    /// The tag identifying every device this run drives (`auto:salvage`).
    ///
    /// A tag rather than a device list because `GET devices/tags/{tag}` is the
    /// only scope that reports a STOWED device — the state a staged mining kit
    /// spends its whole life in. Nil for kinds that resolve their fleet some
    /// other way (Survey Run reads `stowedInDeviceCode` directly).
    public var fleetTag: String?
    /// A plan hint written once at launch, read by the mission executor to
    /// choose its acquisition branch: nil prints a fresh relay at the hub,
    /// non-nil names the existing relay to reclaim and redeploy instead.
    ///
    /// Deliberately narrow — this is NOT a lease. It carries no ownership and
    /// reserves nothing; the executor still leases only the carrier
    /// `deviceCode`, as it always has. An earlier "committed-devices" lease
    /// field was proposed and rejected — do not let this grow into one.
    public var sourceRelayCode: String?
    /// The relay this run has taken possession of, stamped once it is confirmed
    /// in the carrier's hold. Resolution reads it ahead of every derived lookup,
    /// so what the run is carrying cannot be re-decided by a later print.
    public var claimedRelayCode: String?
    /// Every cargo freighter this convoy leases, in load order, and the SOLE
    /// lease — a convoy of one is a list of one. A payload wider than one hold
    /// takes one freighter per hold; each flies itself, so nothing contains them.
    @Column(as: [String].JSONRepresentation.self) public var freighterCodes: [String]
    /// Every service bot this run has put out, enrolled at its first deploy and
    /// never auto-removed. A recovery obligation, NOT a lease: it reserves
    /// nothing. Contract in `.claude/memory/bot-roster-departure-gate.md`.
    @Column(as: [String].JSONRepresentation.self) public var botCodes: [String]
    /// The device a Fetch Run is collecting. A lease from launch: nothing drags
    /// it in before it is attached, so the brain could otherwise re-task the
    /// payload out from under a plate already flying to collect it. Cleared at
    /// detach, so the device is free the moment it stands at its destination.
    public var payloadCode: String?
    /// The ordered queue of star-system designations still to visit.
    ///
    /// For a continuous run this is append-only HISTORY rather than a plan: the
    /// engine appends each system as it picks it, and `SurveyRoamPlanner` treats
    /// the whole array as "already attempted" so nothing is ever offered twice.
    /// That is what stops a system which can never report itself complete (a
    /// planetless one) from pinning the band forever, and what makes the user's
    /// Skip stick.
    @Column(as: [String].JSONRepresentation.self) public var targets: [String]
    /// How far through `targets` the run is. Equal to `targets.count` when done.
    public var targetIndex: Int
    /// The current step's identifier within the mission's step machine.
    ///
    /// Deliberately a bare `String`, not an enum: each `DirectiveKind` has its
    /// own step vocabulary (Survey Run's steps aren't Relay Run's), so there is
    /// no single closed set to type this against. Do not "fix" this.
    public var step: String
    /// When the current `step` began. Mirrors `Operation.startedAt`: the
    /// completion guard is `eventTime >= stepStartedAt - 5s`, issue-time
    /// relative rather than wall-clock relative, exactly like
    /// `Reconciler.completeOpenOperation` (design spec §5). Cannot be
    /// reconstructed from `DirectiveLogEntry` alone, hence its own column.
    @Column(as: Date.FastISO8601Representation.self) public var stepStartedAt: Date
    /// Append a final leg home when the queue empties. Default off — the common
    /// case is chaining onward, and an unwanted return leg costs fuel and time.
    public var returnToOrigin: Bool
    /// The system the run started from, so `returnToOrigin` has a destination.
    public var originDesignation: String?
    /// Set only while `status == .needsAttention`.
    public var attentionReason: DirectiveAttentionReason?
    /// When the operator cleared this run from the Directives list. Nil means
    /// visible. Purely presentational — the row stays readable to every query
    /// that does not filter on it.
    @Column(as: Date.FastISO8601Representation?.self) public var deletedAt: Date?
    @Column(as: Date.FastISO8601Representation.self) public var createdAt: Date
    /// The last transition, and the retention purge's clock: a terminal row is
    /// destroyed a `purgeWindow` past this, so clearing must not re-stamp it.
    @Column(as: Date.FastISO8601Representation.self) public var updatedAt: Date
    /// The depot of the theatre this row serves. Nil on rows written before the
    /// column existed; `Brain.adoptTheatres` fills those in.
    public var theatreDepot: String?

    public init(
        id: String,
        kind: DirectiveKind,
        status: DirectiveStatus,
        deviceCode: String,
        controllerCode: String? = nil,
        roamCentre: String? = nil,
        fleetTag: String? = nil,
        sourceRelayCode: String? = nil,
        claimedRelayCode: String? = nil,
        targets: [String],
        targetIndex: Int,
        step: String,
        stepStartedAt: Date,
        returnToOrigin: Bool,
        originDesignation: String?,
        attentionReason: DirectiveAttentionReason?,
        deletedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date,
        theatreDepot: String? = nil,
        freighterCodes: [String] = [],
        botCodes: [String] = [],
        payloadCode: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.deviceCode = deviceCode
        self.controllerCode = controllerCode
        self.roamCentre = roamCentre
        self.fleetTag = fleetTag
        self.sourceRelayCode = sourceRelayCode
        self.claimedRelayCode = claimedRelayCode
        self.targets = targets
        self.targetIndex = targetIndex
        self.step = step
        self.stepStartedAt = stepStartedAt
        self.returnToOrigin = returnToOrigin
        self.originDesignation = originDesignation
        self.attentionReason = attentionReason
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.theatreDepot = theatreDepot
        self.freighterCodes = freighterCodes
        self.botCodes = botCodes
        self.payloadCode = payloadCode
    }

    /// Progress through the queue, for the list row's "m/n" readout. Counts
    /// delivery, not the cursor — see `hasDelivered(targetAt:)` for why those
    /// differ on a single-target run.
    public var progress: (completed: Int, total: Int) {
        (targets.indices.count(where: { hasDelivered(targetAt: $0) }), targets.count)
    }

    /// The target currently being worked, or nil when the queue is exhausted.
    public var currentTarget: String? {
        targets.indices.contains(targetIndex) ? targets[targetIndex] : nil
    }

    /// Whether the target at `index` has been delivered.
    ///
    /// **`targetIndex` alone is not the answer, and reading it as though it
    /// were shows a finished run as unfinished.** It is a CURSOR — the target
    /// being worked on now — which is exactly how `currentTarget` resolves it.
    /// A machine only advances that cursor when it moves ON to another target,
    /// so a single-target run has no reason to ever touch it, and `RelayRun`
    /// never does. Such a run completes with `targetIndex == 0`, and `0 < 0` is
    /// false, so a plain cursor comparison draws an empty circle beside a
    /// system that really was meshed.
    ///
    /// Advancing the cursor at the end instead is NOT the fix and would be a
    /// real bug: `RelayRun.settle` and `returnHome` both read `currentTarget`,
    /// which goes nil the moment the cursor passes the end of `targets`.
    ///
    /// So delivery is read off the run's own STATUS, which is what actually
    /// carries "this work is finished". Only `.completed` counts — a cancelled
    /// or failed run stopped wherever its cursor stood and must keep showing
    /// exactly the targets it genuinely reached.
    public func hasDelivered(targetAt index: Int) -> Bool {
        status == .completed || index < targetIndex
    }
}

/// What a log entry records.
public enum DirectiveLogKind: String, Codable, Equatable, Sendable, CaseIterable, QueryBindable {
    case stepStarted
    case commandDispatched
    case opCompleted
    case directiveCompleted
    /// An `ami.launched` that reported deploying nothing. Recorded only for the
    /// explicit-zero case: a launch with nothing aboard cannot ever produce the
    /// completion the mission is waiting for, so the wait must be cut short.
    case launchDeployedNothing
    case stalled
    case resolved
}

/// One audit-trail entry. Feeds the custom detail pane's live step timeline and
/// the built-in detail pane's completion history.
@Table
public struct DirectiveLogEntry: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var id: String
    /// Set for a custom mission's entry.
    public var directiveID: String?
    /// Set for a built-in AMI directive's entry (keyed by the controller).
    public var deviceCode: String?
    public var kind: DirectiveLogKind
    /// The human-readable line shown in the timeline.
    public var summary: String
    /// Which step (`Directive.step`) this entry belongs to, set for
    /// `.stepStarted` entries. Without this the only way to tell which step a
    /// timeline entry names is string-matching `summary`.
    public var step: String?
    /// The op this entry created or closed, when there is one.
    public var operationID: String?
    /// The SSE event that produced this entry, when there is one.
    public var eventID: String?
    /// The `OperationKind.rawValue` this entry dispatched, for
    /// `.commandDispatched`. The summary names it too, but only for the reader.
    public var commandKind: String?
    /// The device the command went to — NOT `deviceCode`, which keys a
    /// built-in AMI directive's row.
    public var targetDeviceCode: String?
    /// The stall detail, for `.stalled`. The summary carries it too, prefixed
    /// by the reason, but only for the reader.
    public var detail: String?
    @Column(as: Date.FastISO8601Representation.self) public var occurredAt: Date

    public init(
        id: String,
        directiveID: String?,
        deviceCode: String?,
        kind: DirectiveLogKind,
        summary: String,
        step: String?,
        operationID: String?,
        eventID: String?,
        occurredAt: Date,
        commandKind: String? = nil,
        targetDeviceCode: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.directiveID = directiveID
        self.deviceCode = deviceCode
        self.kind = kind
        self.summary = summary
        self.step = step
        self.operationID = operationID
        self.eventID = eventID
        self.commandKind = commandKind
        self.targetDeviceCode = targetDeviceCode
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

// MARK: - Retention

extension Directive {
    /// How long a finished run survives before the purge destroys it. Measured
    /// from `updatedAt` — when the run finished, not when the operator cleared
    /// it, so clearing cannot postpone the purge.
    public static let purgeWindow: TimeInterval = 30 * 24 * 60 * 60

    /// Destroy every terminal run last touched before `cutoff` and its
    /// timeline, in the caller's transaction, returning how many rows went. The
    /// terminal set is deliberately not a parameter: an open run owns devices.
    public static func purgeFinished(before cutoff: Date, in db: Database) throws -> Int {
        let doomed = try Directive
            .where {
                $0.status.in(DirectiveStatus.finishedCases)
                    && $0.updatedAt < Date.FastISO8601Representation(queryOutput: cutoff)
            }
            .fetchAll(db)
            .map(\.id)
        guard !doomed.isEmpty else { return 0 }
        // Entries before the rows they point at: every timeline query is keyed
        // by directive id, so an orphan entry is unreachable forever.
        let scoped = doomed.map(Optional.some)
        try DirectiveLogEntry.where { $0.directiveID.in(scoped) }.delete().execute(db)
        try Directive.where { $0.id.in(doomed) }.delete().execute(db)
        return doomed.count
    }
}

// MARK: - Schema

extension Directive {
    /// Creates the `directives` table. Kept beside the model so the schema
    /// and the type never drift.
    public static let createDirectives = SchemaMigration("Create 'directives' table") { db in
        try #sql(
            """
            CREATE TABLE "directives" (
              "id" TEXT PRIMARY KEY NOT NULL,
              "kind" TEXT NOT NULL,
              "status" TEXT NOT NULL,
              "deviceCode" TEXT NOT NULL DEFAULT '',
              "targets" TEXT NOT NULL DEFAULT '[]',
              "targetIndex" INTEGER NOT NULL DEFAULT 0,
              "step" TEXT NOT NULL DEFAULT '',
              "stepStartedAt" TEXT NOT NULL,
              "returnToOrigin" INTEGER NOT NULL DEFAULT 0,
              "originDesignation" TEXT,
              "attentionReason" TEXT,
              "createdAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL
            ) STRICT
            """
        )
        .execute(db)
    }

    /// A separate migration, not an edit to the one above: the original
    /// shipped 2026-07-25 and is already applied in real databases.
    public static let addControllerCode = SchemaMigration("Add 'controllerCode' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "controllerCode" TEXT
            """
        )
        .execute(db)
    }

    /// A separate migration, not an edit to either above: both have shipped and
    /// are already recorded in real databases, so editing one means it silently
    /// never runs again.
    public static let addRoamCentre = SchemaMigration("Add 'roamCentre' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "roamCentre" TEXT
            """
        )
        .execute(db)
    }

    /// A separate migration, not an edit to any above: all three have shipped
    /// and are recorded in real databases, so editing one means it silently
    /// never runs again.
    public static let addFleetTag = SchemaMigration("Add 'fleetTag' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "fleetTag" TEXT
            """
        )
        .execute(db)
    }

    /// A separate migration, not an edit to any above: all four have shipped
    /// and are recorded in real databases, so editing one means it silently
    /// never runs again.
    public static let addSourceRelayCode = SchemaMigration("Add 'sourceRelayCode' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "sourceRelayCode" TEXT
            """
        )
        .execute(db)
    }

    /// Appended, never folded into the migration above it: that one has shipped
    /// into real databases, so editing it means it silently never runs again.
    public static let addClaimedRelayCode = SchemaMigration("Add 'claimedRelayCode' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "claimedRelayCode" TEXT
            """
        )
        .execute(db)
    }

    /// Appended, never folded into the migration above it: that one has shipped
    /// into real databases, so editing it means it silently never runs again.
    public static let addFreighterCode = SchemaMigration("Add 'freighterCode' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "freighterCode" TEXT
            """
        ).execute(db)
    }

    /// Appended, never folded into the migration above it: that one has shipped
    /// into real databases, so editing it means it silently never runs again.
    public static let addDeletedAt = SchemaMigration("Add 'deletedAt' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "deletedAt" TEXT
            """
        )
        .execute(db)
    }

    /// Appended, never folded into the migration above it: that one has shipped
    /// into real databases, so editing it means it silently never runs again.
    public static let addTheatreDepot = SchemaMigration("Add 'theatreDepot' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "theatreDepot" TEXT
            """
        )
        .execute(db)
    }
}

extension DirectiveLogEntry {
    /// Creates the `directiveLogEntries` table and its supporting indexes.
    public static let createDirectiveLogEntries = SchemaMigration("Create 'directiveLogEntries' table") { db in
        try #sql(
            """
            CREATE TABLE "directiveLogEntries" (
              "id" TEXT PRIMARY KEY NOT NULL,
              "directiveID" TEXT,
              "deviceCode" TEXT,
              "kind" TEXT NOT NULL,
              "summary" TEXT NOT NULL DEFAULT '',
              "step" TEXT,
              "operationID" TEXT,
              "eventID" TEXT,
              "occurredAt" TEXT NOT NULL
            ) STRICT
            """
        )
        .execute(db)
        // The timeline reads are always "entries for one directive" or
        // "entries for one device", newest last.
        try #sql(
            """
            CREATE INDEX "directive_log_by_directive"
              ON "directiveLogEntries" ("directiveID", "occurredAt")
            """
        )
        .execute(db)
        try #sql(
            """
            CREATE INDEX "directive_log_by_device"
              ON "directiveLogEntries" ("deviceCode", "occurredAt")
            """
        )
        .execute(db)
        // Replay immunity (design spec §6): the `directive.*` SSE route's
        // only job is writing one of these rows, and a replayed or
        // catch-up-redelivered event must not duplicate the timeline entry.
        // `eventID` is nullable (not every entry comes from an event), so
        // the uniqueness only applies where it's set.
        try #sql(
            """
            CREATE UNIQUE INDEX "directive_log_unique_event"
              ON "directiveLogEntries" ("eventID") WHERE "eventID" IS NOT NULL
            """
        )
        .execute(db)
    }

    /// Appended, never folded into `createDirectiveLogEntries`: that one has
    /// shipped. What a command sent and what it stalled on stop being facts
    /// only the summary prose carries.
    public static let addCommandColumns = SchemaMigration(
        "Add 'commandKind','targetDeviceCode','detail' to 'directiveLogEntries'"
    ) { db in
        try #sql(#"ALTER TABLE "directiveLogEntries" ADD COLUMN "commandKind" TEXT"#).execute(db)
        try #sql(#"ALTER TABLE "directiveLogEntries" ADD COLUMN "targetDeviceCode" TEXT"#).execute(db)
        try #sql(#"ALTER TABLE "directiveLogEntries" ADD COLUMN "detail" TEXT"#).execute(db)
    }

    /// Appended, never folded into `createDirectiveLogEntries`: that one has
    /// shipped. The audit pass asks "which operations did this directive
    /// dispatch?", which `directive_log_by_directive` can only answer by
    /// reading every entry the directive ever wrote. This one covers the
    /// question outright, so the lookup never touches the table.
    public static let addDispatchLookupIndex = SchemaMigration(
        "Add 'directive_log_by_directive_kind' index"
    ) { db in
        try #sql(
            """
            CREATE INDEX "directive_log_by_directive_kind"
              ON "directiveLogEntries" ("directiveID", "kind", "operationID")
            """
        )
        .execute(db)
    }
}

public extension Directive {
    /// Appended, never folded into `addFreighterCode`: that one has shipped. A
    /// payload wider than one hold needs one freighter per hold, so the lease is
    /// a list, and this backfill is what carries the singular rows across.
    static let addFreighterCodes = SchemaMigration("Add 'freighterCodes' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "freighterCodes" TEXT NOT NULL DEFAULT '[]'
            """
        ).execute(db)
        try #sql(
            """
            UPDATE "directives"
               SET "freighterCodes" = json_array("freighterCode")
             WHERE "freighterCode" IS NOT NULL AND "freighterCode" <> ''
            """
        ).execute(db)
    }

    /// The bot roster. Deliberately no backfill — a running directive has no
    /// record of which bots it already put out, and today's stow state names
    /// the ones that came home.
    static let addBotCodes = SchemaMigration("Add 'botCodes' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "botCodes" TEXT NOT NULL DEFAULT '[]'
            """
        ).execute(db)
    }

    /// A Fetch Run's payload lease. Nullable with no default — every other kind
    /// leaves it unset, and "no payload" is a real state rather than a blank.
    static let addPayloadCode = SchemaMigration("Add 'payloadCode' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "payloadCode" TEXT
            """
        ).execute(db)
    }

    /// The mirror, retired: `freighterCodes` is the lease and nothing reads the
    /// singular column. `addFreighterCodes` must stay ahead of this one in the
    /// manifest — it is what moves the rows this drops.
    static let dropFreighterCode = SchemaMigration("Drop 'freighterCode' from 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" DROP COLUMN "freighterCode"
            """
        ).execute(db)
    }
}
