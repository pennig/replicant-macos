//
//  BotPhase.swift
//  Replicould — DirectiveEngine
//
//  The service-bot lifecycle: deploy on arrival, arm, hold while they repair,
//  recall before departing. One copy, serving every bot-carrying mission.
//

import Foundation
import GameModels
import GameServices
import OSLog
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

/// One leg of the service-bot lifecycle, as a pure value.
struct BotPhase: Equatable, Sendable {
    /// Each case is one mission step. The confirm legs are separate because
    /// `deploy` and `recall` are immediate verbs carrying no operation row.
    enum Phase: Equatable, Sendable {
        case deploy, confirmDeploy
        case arm, confirmArm
        case awaitRepair
        case recall, confirmRecall
    }

    /// Grace before the first read of a just-ordered command.
    static let probeDelay: TimeInterval = 10
    /// Floor between reads of one row while polling.
    static let probeInterval: TimeInterval = 30
    /// How long a deploy or arm may go unconfirmed.
    static let confirmDeadline: TimeInterval = 10 * 60
    /// How long the run holds while bots repair.
    static let repairDeadline: TimeInterval = 20 * 60
    /// How long a recall may go unconfirmed before the run refuses to leave.
    /// A recall whose own arrival is still ahead outruns this; `recallCeiling`
    /// is that extension's bound.
    static let recallDeadline: TimeInterval = 20 * 60
    /// The ceiling on `recallDeadline`'s extension while a bot is demonstrably
    /// still cruising home. A liveness backstop for an ETA that never arrives,
    /// not an estimate of how long a cruise takes.
    static let recallCeiling: TimeInterval = 2 * 60 * 60
    /// Dispatch rounds one loop may spend. Read off the log, because the
    /// confirm leg re-stamps `stepStartedAt` on every hop.
    static let dispatchRounds = 6

    /// The vessel the bots ride and are judged around.
    let vesselCode: String
    /// The fleet whose bots answer — `RepairFleet.answers`.
    let owner: FleetTag?
    /// The run's target system, for the branches a nil vessel location cannot
    /// answer from a location query.
    let system: String?
    let phase: Phase
    /// This phase's own dispatch/confirm step pair, for the log budget.
    let dispatchStep: String
    let confirmStep: String
    /// Names the run in the operator log: "survey run", "salvage run".
    let runNoun: String
    /// Where the mission goes when the deploy loop gives up with bots already out.
    let unrepairedStep: String

    init(
        vesselCode: String, owner: FleetTag?, system: String?, phase: Phase,
        dispatchStep: String, confirmStep: String, runNoun: String, unrepairedStep: String
    ) {
        self.vesselCode = vesselCode
        self.owner = owner
        self.system = system
        self.phase = phase
        self.dispatchStep = dispatchStep
        self.confirmStep = confirmStep
        self.runNoun = runNoun
        self.unrepairedStep = unrepairedStep
    }

    func next(_ ctx: StepContext) -> StepResult {
        guard let vessel = ctx.world.device(vesselCode) else { return .noSubject }
        switch phase {
        case .deploy: return deploy(vessel, ctx)
        case .confirmDeploy: return confirmDeploy(vessel, ctx)
        case .arm: return arm(vessel, ctx)
        case .confirmArm: return confirmArm(vessel, ctx)
        case .awaitRepair: return awaitRepair(vessel, ctx)
        case .recall: return recall(vessel, ctx)
        case .confirmRecall: return confirmRecall(vessel, ctx)
        }
    }

    /// One throttled read of `rows` when any predates the step, or nil when
    /// they are fresh enough to judge. Callers check their deadline FIRST.
    private func probe(_ rows: [Device], _ ctx: StepContext) -> MissionAction? {
        guard rows.contains(where: { !ctx.isFresh($0) }) else { return nil }
        let lastLook = rows.map(\.updatedAt).min() ?? .distantPast
        if ctx.now.timeIntervalSince(lastLook) < Self.probeInterval { return .wait }
        return .refreshDevices(deviceCodes: rows.map(\.deviceCode), thenStall: nil)
    }

    /// The vessel's own row is what makes a system-scoped bot query answerable,
    /// so a nil location is uncertainty — but only where a bot is out to lose.
    private func withoutLocation(
        _ vessel: Device, _ ctx: StepContext, anyOut: Bool,
        deadline: TimeInterval, thenStall: DirectiveAttentionReason
    ) -> StepResult {
        guard anyOut else { return .finished }
        if ctx.elapsed > deadline { return .action(.stall(thenStall)) }
        if ctx.now.timeIntervalSince(vessel.updatedAt) < Self.probeInterval { return .action(.wait) }
        return .action(.refreshDevices(deviceCodes: [vessel.deviceCode], thenStall: nil))
    }

    private func rounds(_ ctx: StepContext) -> Int {
        MissionLogBudget.dispatchRounds(ctx.world, dispatch: dispatchStep, confirm: confirmStep)
    }

    private func deploy(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        let aboard = RepairFleet.bots(aboard: vessel, in: ctx.world, owner: owner)
        // Enrol BEFORE the first deploy, and only ever add: re-deriving from what
        // is aboard now would drop the one bot that failed to come home.
        let fresh = aboard.map(\.deviceCode).filter { !ctx.directive.botCodes.contains($0) }
        if !fresh.isEmpty {
            return .action(.enrolBots(
                deviceCodes: ctx.directive.botCodes + fresh, nextStep: dispatchStep
            ))
        }
        guard let next = aboard.first else { return .finished }
        if rounds(ctx) > Self.dispatchRounds {
            logger.notice("\(runNoun, privacy: .public) \(ctx.directive.id, privacy: .public): \(next.deviceCode, privacy: .public) will not deploy — proceeding unrepaired")
            return .action(.advanceStep(nextStep: unrepairedStep))
        }
        return .action(.dispatch(
            kind: .simple("deploy"), deviceCode: next.deviceCode,
            params: CommandParams(), nextStep: confirmStep
        ))
    }

    private func confirmDeploy(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        if ctx.elapsed < Self.probeDelay { return .action(.wait) }
        if ctx.elapsed > Self.confirmDeadline {
            logger.notice("\(runNoun, privacy: .public) \(ctx.directive.id, privacy: .public): bot deploy unconfirmed — proceeding unrepaired")
            return .finished
        }
        let aboard = RepairFleet.bots(aboard: vessel, in: ctx.world, owner: owner)
        guard aboard.isEmpty else {
            // A row unread since the deploy was ordered cannot show it landing.
            if let probe = probe(aboard, ctx) { return .action(probe) }
            return .more
        }
        // The arm leg judges the DEPLOYED rows, and nothing has read them since
        // the order — a stale one reads armed and skips repair.
        let deployed = RepairFleet.bots(deployedNear: vessel.location, in: ctx.world, owner: owner)
        if let probe = probe(deployed, ctx) { return .action(probe) }
        return .finished
    }

    private func arm(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        let deployed = RepairFleet.bots(deployedNear: vessel.location, in: ctx.world, owner: owner)
        guard let next = deployed.first(where: { !RepairFleet.isArmed($0) }) else { return .finished }
        if rounds(ctx) > Self.dispatchRounds {
            logger.notice("\(runNoun, privacy: .public) \(ctx.directive.id, privacy: .public): \(next.deviceCode, privacy: .public) will not arm")
            return .action(.stall(.serviceBotNotArmed))
        }
        guard next.currentDirective == "service" else {
            return .action(.dispatch(
                kind: .setDirective, deviceCode: next.deviceCode,
                params: CommandParams(directive: "service"), nextStep: confirmStep
            ))
        }
        return .action(.dispatch(
            kind: .simple("activate"), deviceCode: next.deviceCode,
            params: CommandParams(), nextStep: confirmStep
        ))
    }

    private func confirmArm(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        if ctx.elapsed < Self.probeDelay { return .action(.wait) }
        if ctx.elapsed > Self.confirmDeadline { return .action(.stall(.serviceBotNotArmed)) }
        let deployed = RepairFleet.bots(deployedNear: vessel.location, in: ctx.world, owner: owner)
        // "Everything is armed" is the conclusion that skips repair entirely,
        // so it needs the same proof the mis-armed one does.
        if let probe = probe(deployed, ctx) { return .action(probe) }
        guard deployed.contains(where: { !RepairFleet.isArmed($0) }) else { return .finished }
        return .more
    }

    private func awaitRepair(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        guard let location = vessel.location else {
            return withoutLocation(
                vessel, ctx,
                anyOut: RepairFleet.anyBotDeployed(in: ctx.world, system: system, owner: owner),
                deadline: Self.repairDeadline, thenStall: .repairUnfinished
            )
        }
        let bots = RepairFleet.bots(deployedNear: location, in: ctx.world, owner: owner)
        if bots.isEmpty { return .finished }
        // A fleet nothing is worn enough to hold for leaves without paying the
        // probe delay or a single read.
        if !RepairFleet.needsRepair(RepairFleet.fleet(of: vessel, in: ctx.world, owner: owner)) {
            return .finished
        }
        if ctx.elapsed < Self.probeDelay { return .action(.wait) }
        if ctx.elapsed > Self.repairDeadline { return .action(.stall(.repairUnfinished)) }
        // Bots repair silently server-side; an unread row cannot be trusted to
        // report idle, so treat it as still working until a read says so.
        let stale = bots.contains { !ctx.isFresh($0) }
        if !stale, !bots.contains(where: RepairFleet.isRepairing) { return .finished }
        let lastLook = bots.map(\.updatedAt).min() ?? .distantPast
        if ctx.now.timeIntervalSince(lastLook) < Self.probeInterval { return .action(.wait) }
        return .action(.refreshDevices(deviceCodes: bots.map(\.deviceCode), thenStall: nil))
    }

    // MARK: - The roster

    /// Roster members not aboard `vessel`, selected on stow state ONLY. The
    /// absent location term is the point: neither a bot mid-hop nor a bot left
    /// behind can be matched by an in-system query.
    private func owed(_ vessel: Device, _ ctx: StepContext) -> [Device] {
        ctx.directive.botCodes
            .compactMap { ctx.world.device($0) }
            .filter { $0.stowedInDeviceCode != vessel.deviceCode }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// The roster plus whatever the location query finds standing here. A UNION,
    /// never a replacement — the location query is what still reaches a bot an
    /// operator deployed by hand, which is enrolled nowhere.
    private func outstanding(_ vessel: Device, _ location: String, _ ctx: StepContext) -> [Device] {
        var seen = Set<String>()
        return (owed(vessel, ctx) + RepairFleet.botsOut(near: location, in: ctx.world, owner: owner))
            .filter { seen.insert($0.deviceCode).inserted }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// An owed bot in a system the vessel has left, which no recall reaches. A
    /// nil location is a bot in FLIGHT and must never read as stranded — that
    /// would stall every ordinary hop.
    private func stranded(_ owed: [Device], _ vessel: Device) -> Device? {
        guard let here = vessel.location.map(SiteAssay.system(of:)) else { return nil }
        return owed.first { bot in
            guard let there = bot.location.map(SiteAssay.system(of:)) else { return false }
            return there != here
        }
    }

    private func strandStall(_ lost: Device) -> StepResult {
        logger.notice("\(runNoun, privacy: .public): \(lost.deviceCode, privacy: .public) left in \(lost.location ?? "?", privacy: .public)")
        return .action(.stall(
            .serviceBotStranded, detail: "\(lost.deviceCode) at \(lost.location ?? "unknown")"
        ))
    }

    /// `recall`, not `stow`: `stow` needs the bot beside the vessel, and one
    /// that cruised off to repair a drone is not.
    private func recall(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        let owed = owed(vessel, ctx)
        if let lost = stranded(owed, vessel) { return strandStall(lost) }
        guard let location = vessel.location else {
            return withoutLocation(
                vessel, ctx,
                anyOut: !owed.isEmpty
                    || RepairFleet.anyBotOut(in: ctx.world, system: system, owner: owner),
                deadline: Self.recallDeadline, thenStall: .serviceBotNotRecovered
            )
        }
        let out = outstanding(vessel, location, ctx)
        guard let next = out.first else { return .finished }
        // Wait a hop out rather than commanding a device in transit
        // ([[salvage-controller-recall-race]]); the deadline bounds the wait.
        if out.contains(where: { $0.location == nil && $0.stowedInDeviceCode == nil }) {
            if ctx.elapsed > Self.recallDeadline, !Self.stillInbound(out, ctx) {
                return .action(.stall(.serviceBotNotRecovered))
            }
            if let probe = probe(out, ctx) { return .action(probe) }
            return .action(.wait)
        }
        if rounds(ctx) > Self.dispatchRounds { return .action(.stall(.serviceBotNotRecovered)) }
        if RepairFleet.openRecall(for: next.deviceCode, in: ctx.world) != nil {
            if ctx.elapsed > Self.recallDeadline, !Self.stillInbound(out, ctx) {
                return .action(.stall(.serviceBotNotRecovered))
            }
            return .action(.wait)
        }
        return .action(.dispatch(
            kind: .simple("recall"), deviceCode: next.deviceCode,
            params: CommandParams(), nextStep: confirmStep
        ))
    }

    private func confirmRecall(_ vessel: Device, _ ctx: StepContext) -> StepResult {
        if ctx.elapsed < Self.probeDelay { return .action(.wait) }
        let owed = owed(vessel, ctx)
        if let lost = stranded(owed, vessel) { return strandStall(lost) }
        guard let location = vessel.location else {
            return withoutLocation(
                vessel, ctx,
                anyOut: !owed.isEmpty
                    || RepairFleet.anyBotOut(in: ctx.world, system: system, owner: owner),
                deadline: Self.recallDeadline, thenStall: .serviceBotNotRecovered
            )
        }
        let out = outstanding(vessel, location, ctx)
        if out.isEmpty { return .finished }
        // A recall cruises the bot home, so wait out its own arrival time —
        // ahead of the flat deadline, which a long cruise would otherwise trip.
        if Self.stillInbound(out, ctx) { return .action(.wait) }
        if ctx.elapsed > Self.recallDeadline { return .action(.stall(.serviceBotNotRecovered)) }
        if out.contains(where: { !ctx.isFresh($0) }) {
            let lastLook = out.map(\.updatedAt).min() ?? .distantPast
            if ctx.now.timeIntervalSince(lastLook) < Self.probeInterval { return .action(.wait) }
            return .action(.refreshDevices(deviceCodes: out.map(\.deviceCode), thenStall: nil))
        }
        return .more
    }

    /// The latest arrival among the recalls still in flight.
    static func recallArrival(_ out: [Device]) -> Date? {
        out.compactMap(\.activityDeadline).max()
    }

    /// Whether a bot in `out` is demonstrably still cruising home: its own
    /// arrival is ahead and the step is inside `recallCeiling`. Positive
    /// evidence, so it may outrun `recallDeadline` — silence may not.
    static func stillInbound(_ out: [Device], _ ctx: StepContext) -> Bool {
        guard ctx.elapsed <= Self.recallCeiling else { return false }
        guard let arrival = recallArrival(out) else { return false }
        return arrival > ctx.now
    }
}
