//
//  DirectiveExecutor.swift
//  Replicould — DirectiveEngine
//
//  Applying one `MissionAction` to the database. Split out from the engine so
//  the state transitions — the part a bug would corrupt rows with — are a plain
//  function over (directive, action) rather than something tangled in task
//  lifecycle.
//
//  Every transition also appends the `DirectiveLogEntry` rows that make the step
//  visible in the detail pane's timeline. Each action commits exactly once, so a
//  mission can never be observed half-advanced.
//

import Dependencies
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

/// The write half of the engine: every directive-row transition and every
/// timeline entry the engine makes goes through here.
enum DirectiveExecutor {
    /// How many `.failed` dispatches a step tolerates before stalling
    /// `.commandFailed` — a `.rejected` (4xx) never gets a retry.
    static let failedDispatchBudget = 3

    /// Verbs where a repeat is not idempotent (queues/dequeues by position,
    /// or moves a fixed quantity) — stall on the first `.failed`, no retry.
    static let nonRetryableKinds: Set<OperationKind> = [
        .print, .dequeuePrint, .collectResources, .depositResources,
    ]

    /// Apply `action` to `directive`, using `machine` for the step vocabulary a
    /// target change needs. Returns whether the directive is still runnable — a
    /// stall or a completion retires its executor.
    @discardableResult
    static func apply(
        _ action: MissionAction,
        to directive: Directive,
        machine: any MissionStepMachine
    ) async -> Bool {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid

        switch action {
        case .wait:
            // Writes nothing: a wait that logged would bury the timeline in
            // noise, and this is the one action that leaves `stepStartedAt`
            // alone so a step deadline can accumulate.
            return true

        case let .dispatch(kind, deviceCode, params, nextStep):
            @Dependency(\.commandGovernor) var commandGovernor
            let owner = CommandOwner(directiveID: directive.id, step: directive.step, since: directive.stepStartedAt)
            // Read before dispatching: a `.failed` that leaves the count where it
            // was never reached the server, and no repeat of it can (see below).
            let failuresBefore = await failedDispatches(for: directive)
            switch await commandGovernor.dispatchOwned(kind, deviceCode, params, owner) {
            case let .deferred(reason):
                // Not a failure: the governor will let it through on a later
                // tick, so the step is late rather than lost. No state change.
                logger.debug("directive \(directive.id, privacy: .public): \(kind.rawValue, privacy: .public) deferred (\(reason.rawValue, privacy: .public))")
                return true

            case let .dispatched(outcome):
                switch outcome {
                case let .accepted(operationID):
                    var updated = directive
                    updated.step = nextStep
                    // Same-step keeps its stamp, as in `move`: the stamp bounds
                    // both the step deadline and the governor's dedup window.
                    if nextStep != directive.step { updated.stepStartedAt = date.now }
                    updated.updatedAt = date.now
                    await commit(updated, [
                        entry(directive, .stepStarted, "Step: \(nextStep)",
                              step: nextStep, operationID: nil,
                              id: uuid().uuidString, at: date.now),
                        entry(directive, .commandDispatched, dispatchSummary(kind, deviceCode, params),
                              step: nextStep, operationID: operationID,
                              id: uuid().uuidString, at: date.now,
                              commandKind: kind.rawValue, targetDeviceCode: deviceCode),
                    ])
                    return true

                case let .rejected(message):
                    await stall(directive, reason: .commandRejected, detail: message)
                    return false

                case let .failed(message):
                    guard !Self.nonRetryableKinds.contains(kind) else {
                        await stall(directive, reason: .commandFailed, detail: message)
                        return false
                    }
                    // Counts THIS dispatch's own just-written row too, so `<=`
                    // yields exactly `failedDispatchBudget` retries.
                    let failures = await failedDispatches(for: directive)
                    guard failures > failuresBefore else {
                        // No row to show for the attempt: a malformed request, or
                        // a write that failed. Repeating it changes neither.
                        logger.notice("directive \(directive.id, privacy: .public): \(kind.rawValue, privacy: .public) failed without an operation row — \(message, privacy: .public)")
                        await stall(directive, reason: .commandFailed, detail: message)
                        return false
                    }
                    if failures <= Self.failedDispatchBudget {
                        logger.notice("directive \(directive.id, privacy: .public): \(kind.rawValue, privacy: .public) failed (\(failures)/\(Self.failedDispatchBudget)) — \(message, privacy: .public) — will retry")
                        return true
                    }
                    await stall(directive, reason: .commandFailed, detail: message)
                    return false
                }
            }

        case let .advanceStep(nextStep):
            await move(directive, to: nextStep, controllerCode: directive.controllerCode)
            return true

        case let .assignController(deviceCode, nextStep):
            logger.info("directive \(directive.id, privacy: .public) claims controller \(deviceCode, privacy: .public)")
            // Stamps the claimed device onto the `.stepStarted` entry too
            // (`move`'s `deviceCode:`), not just onto the row's
            // `controllerCode` column — this is what lets a re-entry budget
            // derived from the timeline (`HaulRun.dispatchAttemptCount`) be
            // scoped to ONE controller rather than to the whole pass.
            await move(directive, to: nextStep, controllerCode: deviceCode, deviceCode: deviceCode)
            return true

        case let .enrolBots(deviceCodes, nextStep):
            logger.info("directive \(directive.id, privacy: .public) enrols bots \(deviceCodes.joined(separator: ","), privacy: .public)")
            await move(
                directive, to: nextStep, controllerCode: directive.controllerCode,
                botCodes: deviceCodes
            )
            return true

        case let .claimRelay(deviceCode, nextStep):
            logger.info("directive \(directive.id, privacy: .public) claims relay \(deviceCode, privacy: .public)")
            await move(
                directive, to: nextStep, controllerCode: directive.controllerCode,
                deviceCode: deviceCode, claimedRelayCode: deviceCode
            )
            return true

        case let .refreshSystem(designation, nextStep):
            // Best-effort by contract: the endpoint 403s for a system the census
            // has never marked explored, and a failed hydrate leaves `nextStep`
            // judging a stale cache — which each mission already handles itself,
            // with a bounded retry or a stall. Stalling on a transient read here
            // would strand a mission that is fine.
            @Dependency(\.locationsClient) var locationsClient
            try? await locationsClient.hydrateSystem(designation: designation)
            await move(
                directive, to: nextStep, controllerCode: directive.controllerCode,
                restamp: nextStep != directive.step
            )
            return true

        case let .scanSystem(designation, nextStep):
            // Best-effort by contract, same reasoning as `.refreshSystem` above.
            // The endpoint scans the replicant's OWN system, so it is only correct
            // to call with one standing in `designation` — none means no scan.
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.locationsClient) var locationsClient
            let scanner = try? await database.read { db in
                try Replicant.where { $0.currentStar.eq(designation) }.fetchOne(db)
            }
            if let code = scanner?.replicantCode, !code.isEmpty {
                try? await locationsClient.scanAndPersist(replicantCode: code)
            } else {
                logger.notice("directive \(directive.id, privacy: .public): no replicant in \(designation, privacy: .public) to scan with")
            }
            await move(
                directive, to: nextStep, controllerCode: directive.controllerCode,
                restamp: nextStep != directive.step
            )
            return true

        case let .refreshBody(system, body, nextStep):
            // Best-effort by contract, same reasoning as `.refreshSystem` above.
            @Dependency(\.locationsClient) var locationsClient
            try? await locationsClient.hydrateBody(systemDesignation: system, bodyDesignation: body)
            await move(
                directive, to: nextStep, controllerCode: directive.controllerCode,
                restamp: nextStep != directive.step
            )
            return true

        case let .setDeviceTags(deviceCode, tags, nextStep):
            // Best-effort by contract, same reasoning as `.refreshSystem` above:
            // the real work this action follows (a relay planted and meshing)
            // already succeeded, and the tag is housekeeping — a failed PATCH
            // must log and advance rather than strand the run. Unlike
            // `.refreshSystem` the failure IS logged: `updateTags` can reject
            // (`TagUpdateError`) as well as fail transiently, and a rejection is
            // worth a trace even though it must never stall the mission.
            @Dependency(\.devicesClient) var devicesClient
            @Dependency(\.deviceRefresher) var deviceRefresher
            do {
                try await devicesClient.updateTags(deviceCode, tags)
                // Confirm-read through the coordinator so the local row matches
                // the server: `DevicesClient.updateTags` leaves the follow-up
                // read to its caller. A failed read here is not itself an error
                // — the PATCH already landed; the next poll or SSE echo catches
                // the row up.
                _ = await deviceRefresher.refresh(deviceCode, .high)
            } catch {
                logger.notice("directive \(directive.id, privacy: .public): tag update for \(deviceCode, privacy: .public) failed: \(error) — advancing anyway")
            }
            await move(
                directive, to: nextStep, controllerCode: directive.controllerCode,
                restamp: nextStep != directive.step
            )
            return true

        case let .refreshDevices(_, thenStall), let .refreshDevicesInSystem(_, thenStall),
             let .refreshFleet(_, thenStall), let .refreshFootprint(_, thenStall),
             let .refreshEvents(thenStall):
            // The engine resolves all five before they ever reach the executor
            // (each needs a second world read and a second call into the
            // machine). Reaching here means that resolution was bypassed, so
            // honour the carried fallback rather than silently dropping the
            // action — this case performs no read of its own.
            guard let thenStall else { return true }
            logger.notice("directive \(directive.id, privacy: .public): unresolved refresh — stalling with \(thenStall.rawValue, privacy: .public)")
            await stall(directive, reason: thenStall, detail: nil)
            return false

        case let .completeEvent(_, designation, _):
            // The engine owns the POST and the ledger re-read. Advancing here
            // would move the run on an uncommitted event, so leave the row be.
            logger.notice("directive \(directive.id, privacy: .public): unresolved event commit for \(designation, privacy: .public) — leaving the row untouched")
            return true

        case .extendQueue:
            // The engine resolves this before it ever reaches the executor (it
            // needs a census read and a second call into the machine). Reaching
            // here is a programming error rather than a world state, so it must
            // log loudly and leave the row alone: returning `.done` would read
            // as a finished run, where an untouched row stays cancellable.
            logger.error("directive \(directive.id, privacy: .public): unresolved extendQueue reached the executor — leaving the row untouched")
            return true

        case let .stall(reason, detail):
            await stall(directive, reason: reason, detail: detail)
            return false

        case .advanceTarget:
            var updated = directive
            updated.targetIndex += 1
            updated.step = machine.firstStep
            updated.stepStartedAt = date.now
            updated.updatedAt = date.now
            let summary = updated.currentTarget.map { "Target: \($0)" } ?? "Queue exhausted"
            await commit(updated, [
                entry(directive, .stepStarted, summary,
                      step: machine.firstStep, operationID: nil,
                      id: uuid().uuidString, at: date.now),
            ])
            return true

        case .done:
            var updated = directive
            updated.status = .completed
            updated.attentionReason = nil
            updated.updatedAt = date.now
            await commitLifecycle(updated, [
                entry(directive, .directiveCompleted, "\(directive.kind.title) completed",
                      step: nil, operationID: nil,
                      id: uuid().uuidString, at: date.now),
            ])
            logger.info("directive \(directive.id, privacy: .public) completed")
            return false
        }
    }

    // MARK: The `.opCompleted` audit pass

    /// Write an `.opCompleted` entry for every op `directive` dispatched that
    /// `world` shows has since reached a terminal state and doesn't already
    /// have one.
    ///
    /// **Audit only — this must never change a directive's status, step or
    /// target.** It appends log rows and nothing else, which is what makes it
    /// safe to run on every tick ahead of the machine; mission progress keys off
    /// the `directive.completed` entry and the machine's own conditions instead.
    ///
    /// Fires for ANY terminal status, not just `.completed`: a
    /// `failed`/`rejected`/`superseded` op closing ends exactly as much of a
    /// timeline gap, and the summary names which it was.
    ///
    /// Idempotent through the log itself — an op id already carrying an
    /// `.opCompleted` entry is skipped. Reading the worklist at tick time makes
    /// this a narrow-window guarantee, not a structural one: worst case is a duplicate row.
    ///
    /// Known gap, accepted: a directive that leaves `.running` before its last
    /// dispatched op closes gets no entry for that op, because `evaluateOnce`
    /// returns early for a non-running row. A resumed stall lands the entry late
    /// rather than never; only a stall abandoned forever, or a mission whose
    /// final op closes after `.done`, stays silent.
    static func recordCompletedOps(for directive: Directive, world: WorldSnapshot) async {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid

        // Reads `auditLog` (SQL-matched, unwindowed), not `log`. See
        // `app/.claude/memory/dispatched-operations-two-set-union.md`.
        var entries: [DirectiveLogEntry] = []
        for dispatch in world.auditLog where dispatch.kind == .commandDispatched {
            guard let operationID = dispatch.operationID,
                  let operation = world.dispatchedOperations[operationID],
                  operation.status.isTerminal
            else { continue }

            // Sort the entry where the op actually closed, not where we noticed.
            // `lastConfirmedAt` is the reconciler's stamp for the row's current
            // state, so for a terminal op it is approximately the closing moment.
            // Clamped into (dispatch, now] so the pair can never render out of
            // order, however the stamps landed.
            let closedAt = min(max(operation.lastConfirmedAt, dispatch.occurredAt), world.now)
            entries.append(
                DirectiveLogEntry(
                    id: uuid().uuidString,
                    directiveID: directive.id,
                    deviceCode: nil,
                    kind: .opCompleted,
                    summary: summary(for: operation),
                    step: dispatch.step,
                    operationID: operationID,
                    eventID: nil,
                    occurredAt: closedAt
                )
            )
        }

        guard !entries.isEmpty else { return }
        await appendEntries(entries, directiveID: directive.id)
        logger.debug("directive \(directive.id, privacy: .public): logged \(entries.count) completed op(s)")
    }

    /// "travel completed" / "travel failed" — `operation`'s kind plus how it
    /// ended, so a terminal-but-unsuccessful op doesn't read as a clean finish.
    private static func summary(for operation: GameModels.Operation) -> String {
        switch operation.status {
        case .completed:  return "\(operation.kind) completed"
        case .failed:     return "\(operation.kind) failed"
        case .rejected:   return "\(operation.kind) rejected"
        case .superseded: return "\(operation.kind) superseded"
        case .unknown:    return "\(operation.kind) ended (status unknown)"
        case .optimistic, .enqueued, .active: return "\(operation.kind) closed"
        }
    }

    /// Append `entries` WITHOUT touching directive `directiveID`'s row — the
    /// audit pass's write path. Deliberately not `commit`: upserting the row
    /// here could clobber a concurrent status change with this pass's older
    /// copy, and the pass has no business moving the mission anyway.
    private static func appendEntries(_ entries: [DirectiveLogEntry], directiveID: String) async {
        @Dependency(\.defaultDatabase) var database
        do {
            try await database.write { db in
                for entry in entries {
                    try DirectiveLogEntry.insert { entry }.execute(db)
                }
            }
        } catch {
            logger.error("directive \(directiveID, privacy: .public) audit write failed: \(error)")
        }
    }

    /// Move `directive` to `nextStep`, setting its controller to
    /// `controllerCode`, with the matching timeline entry.
    ///
    /// `restamp` defaults to true; a same-step read passes false, leaving
    /// `stepStartedAt` alone so the deadline keeps accumulating — and (per
    /// `restamp || nextStep != directive.step`) logging nothing, like `.wait`.
    ///
    /// `deviceCode` defaults to nil and is separate from `controllerCode`
    /// (which every caller sets, usually to `directive.controllerCode`
    /// unchanged): it stamps the timeline entry with who was claimed, and only
    /// the one caller claiming a NEW controller this tick passes it, so no other
    /// transition's entries pick up a leftover value.
    private static func move(
        _ directive: Directive,
        to nextStep: String,
        controllerCode: String?,
        deviceCode: String? = nil,
        claimedRelayCode: String? = nil,
        botCodes: [String]? = nil,
        restamp: Bool = true
    ) async {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid
        var updated = directive
        updated.step = nextStep
        updated.controllerCode = controllerCode
        // Nil leaves an existing claim standing: every other transition passes
        // nil, and none of them means "the run has let go of its relay".
        if let claimedRelayCode { updated.claimedRelayCode = claimedRelayCode }
        // Same contract as the relay claim: nil means "unchanged". Enrolment is
        // the only writer, and it never shrinks the roster.
        if let botCodes { updated.botCodes = botCodes }
        if restamp { updated.stepStartedAt = date.now }
        updated.updatedAt = date.now
        let entries = restamp || nextStep != directive.step
            ? [entry(directive, .stepStarted, "Step: \(nextStep)",
                     step: nextStep, operationID: nil, deviceCode: deviceCode,
                     id: uuid().uuidString, at: date.now)]
            : []
        await commit(updated, entries)
    }

    /// Count of `.failed` `Operation` rows this step has already accrued —
    /// `directive`'s own budget window, never one a re-stamp can slide.
    private static func failedDispatches(for directive: Directive) async -> Int {
        @Dependency(\.defaultDatabase) var database
        return (try? await database.read { db in
            try Operation
                .where {
                    $0.directiveID.eq(directive.id)
                        && $0.step.eq(directive.step)
                        && $0.status.eq(OperationStatus.failed)
                        && $0.startedAt >= Date.FastISO8601Representation(queryOutput: directive.stepStartedAt)
                }
                .fetchCount(db)
        }) ?? 0
    }

    /// Pause and surface: put `directive` into `.needsAttention` with typed
    /// `reason` and optional `detail` on the timeline entry. Never a retry at
    /// the mission layer.
    private static func stall(
        _ directive: Directive,
        reason: DirectiveAttentionReason,
        detail: String?
    ) async {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid
        var updated = directive
        updated.status = .needsAttention
        updated.attentionReason = reason
        updated.updatedAt = date.now
        let summary = detail.map { "\(reason.rawValue): \($0)" } ?? reason.rawValue
        await commitLifecycle(updated, [
            entry(directive, .stalled, summary,
                  step: directive.step, operationID: nil,
                  id: uuid().uuidString, at: date.now, detail: detail),
        ])
        logger.notice("directive \(directive.id, privacy: .public) stalled: \(summary, privacy: .public)")
    }

    /// Names `params`'s salient field after an em dash when it has one;
    /// degrades to the plain "Dispatched kind to device" text, no dangling
    /// separator, when it doesn't.
    private static func dispatchSummary(
        _ kind: OperationKind, _ deviceCode: String, _ params: CommandParams
    ) -> String {
        let base = "Dispatched \(kind.rawValue) to \(deviceCode)"
        guard let detail = params.summaryDetail else { return base }
        return "\(base) — \(detail)"
    }

    /// Build one unpersisted timeline entry of `kind` reading `summary`, owned
    /// by `directive`, stamped `id` at `occurredAt`, and attributed to `step`,
    /// `operationID` and `deviceCode`.
    ///
    /// `deviceCode` defaults to nil, matching every call site except `move`'s
    /// own — see `move`'s doc comment for why only that path sets it.
    private static func entry(
        _ directive: Directive,
        _ kind: DirectiveLogKind,
        _ summary: String,
        step: String?,
        operationID: String?,
        deviceCode: String? = nil,
        id: String,
        at occurredAt: Date,
        commandKind: String? = nil,
        targetDeviceCode: String? = nil,
        detail: String? = nil
    ) -> DirectiveLogEntry {
        DirectiveLogEntry(
            id: id, directiveID: directive.id, deviceCode: deviceCode, kind: kind,
            summary: summary, step: step, operationID: operationID,
            eventID: nil, occurredAt: occurredAt, commandKind: commandKind,
            targetDeviceCode: targetDeviceCode, detail: detail
        )
    }

    /// `directive`'s progress columns and its `entries`, in one transaction, so
    /// a mission is never observed half-advanced. Never `status`; see
    /// `app/.claude/memory/directive-commit-column-ownership.md`.
    private static func commit(_ directive: Directive, _ entries: [DirectiveLogEntry]) async {
        @Dependency(\.defaultDatabase) var database
        do {
            try await database.write { db in
                try Directive.where { $0.id.eq(directive.id) }
                    .update {
                        $0.step = #bind(directive.step)
                        $0.stepStartedAt = #bind(directive.stepStartedAt)
                        $0.targetIndex = #bind(directive.targetIndex)
                        $0.controllerCode = #bind(directive.controllerCode)
                        $0.claimedRelayCode = #bind(directive.claimedRelayCode)
                        $0.botCodes = #bind(directive.botCodes)
                        $0.updatedAt = #bind(directive.updatedAt)
                    }
                    .execute(db)
                try append(entries, db)
            }
        } catch {
            logger.error("directive \(directive.id, privacy: .public) write failed: \(error)")
        }
    }

    /// `directive`'s status transition and its `entries`, refused together when
    /// the row has left `.running` since the tick read it — the operator's pause
    /// outranks a transition decided before it landed.
    private static func commitLifecycle(_ directive: Directive, _ entries: [DirectiveLogEntry]) async {
        @Dependency(\.defaultDatabase) var database
        do {
            try await database.write { db in
                let applied = try Directive
                    .where { $0.id.eq(directive.id) && $0.status.eq(DirectiveStatus.running) }
                    .update {
                        $0.status = #bind(directive.status)
                        $0.attentionReason = #bind(directive.attentionReason)
                        $0.updatedAt = #bind(directive.updatedAt)
                    }
                    .returning { $0.id }
                    .fetchAll(db)
                guard !applied.isEmpty else {
                    logger.notice("directive \(directive.id, privacy: .public): \(directive.status.rawValue, privacy: .public) refused — the row has left running")
                    return
                }
                try append(entries, db)
            }
        } catch {
            logger.error("directive \(directive.id, privacy: .public) write failed: \(error)")
        }
    }

    private static func append(_ entries: [DirectiveLogEntry], _ db: Database) throws {
        for entry in entries {
            try DirectiveLogEntry.insert { entry }.execute(db)
        }
    }
}
