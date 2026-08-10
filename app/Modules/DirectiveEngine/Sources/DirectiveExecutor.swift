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
            switch await commandGovernor.dispatch(kind, deviceCode, params) {
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
                    updated.stepStartedAt = date.now
                    updated.updatedAt = date.now
                    await commit(updated, [
                        entry(directive, .stepStarted, "Step: \(nextStep)",
                              step: nextStep, operationID: nil,
                              id: uuid().uuidString, at: date.now),
                        entry(directive, .commandDispatched, dispatchSummary(kind, deviceCode, params),
                              step: nextStep, operationID: operationID,
                              id: uuid().uuidString, at: date.now),
                    ])
                    return true

                case let .rejected(message), let .failed(message):
                    await stall(directive, reason: .commandRejected, detail: message)
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
            await move(directive, to: nextStep, controllerCode: directive.controllerCode)
            return true

        case let .refreshBody(system, body, nextStep):
            // Best-effort by contract, same reasoning as `.refreshSystem` above.
            @Dependency(\.locationsClient) var locationsClient
            try? await locationsClient.hydrateBody(systemDesignation: system, bodyDesignation: body)
            await move(directive, to: nextStep, controllerCode: directive.controllerCode)
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
            await move(directive, to: nextStep, controllerCode: directive.controllerCode)
            return true

        case let .refreshDevices(_, thenStall), let .refreshDevicesInSystem(_, thenStall),
             let .refreshFleet(_, thenStall), let .refreshFootprint(_, thenStall):
            // The engine resolves all four before they ever reach the executor
            // (each needs a second world read and a second call into the
            // machine). Reaching here means that resolution was bypassed, so
            // honour the carried fallback rather than silently dropping the
            // action — this case performs no read of its own.
            guard let thenStall else { return true }
            logger.notice("directive \(directive.id, privacy: .public): unresolved refresh — stalling with \(thenStall.rawValue, privacy: .public)")
            await stall(directive, reason: thenStall, detail: nil)
            return false

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
            await commit(updated, [
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
    /// `.opCompleted` entry is skipped, and the engine runs one executor per
    /// directive, so there is no second writer to race.
    ///
    /// Known gap, accepted: a directive that leaves `.running` before its last
    /// dispatched op closes gets no entry for that op, because `evaluateOnce`
    /// returns early for a non-running row. A resumed stall lands the entry late
    /// rather than never; only a stall abandoned forever, or a mission whose
    /// final op closes after `.done`, stays silent.
    static func recordCompletedOps(for directive: Directive, world: WorldSnapshot) async {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid

        // Op ids already accounted for. Reads `auditLog`, not the windowed
        // `log`, so an old dispatch this pass still needs stays resolvable.
        let alreadyLogged = Set(world.auditLog.compactMap { entry in
            entry.kind == .opCompleted ? entry.operationID : nil
        })

        var entries: [DirectiveLogEntry] = []
        for dispatch in world.auditLog where dispatch.kind == .commandDispatched {
            guard let operationID = dispatch.operationID,
                  !alreadyLogged.contains(operationID),
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
    /// `stepStartedAt` is re-stamped UNCONDITIONALLY, with no same-step
    /// exception, so a step that dispatches with `nextStep` equal to its own
    /// step restarts its own deadline every tick and can never time out.
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
        claimedRelayCode: String? = nil
    ) async {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid
        var updated = directive
        updated.step = nextStep
        updated.controllerCode = controllerCode
        // Nil leaves an existing claim standing: every other transition passes
        // nil, and none of them means "the run has let go of its relay".
        if let claimedRelayCode { updated.claimedRelayCode = claimedRelayCode }
        updated.stepStartedAt = date.now
        updated.updatedAt = date.now
        await commit(updated, [
            entry(directive, .stepStarted, "Step: \(nextStep)",
                  step: nextStep, operationID: nil, deviceCode: deviceCode,
                  id: uuid().uuidString, at: date.now),
        ])
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
        await commit(updated, [
            entry(directive, .stalled, summary,
                  step: directive.step, operationID: nil,
                  id: uuid().uuidString, at: date.now),
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
        at occurredAt: Date
    ) -> DirectiveLogEntry {
        DirectiveLogEntry(
            id: id, directiveID: directive.id, deviceCode: deviceCode, kind: kind,
            summary: summary, step: step, operationID: operationID,
            eventID: nil, occurredAt: occurredAt
        )
    }

    /// The single write site: `directive` and its `entries` land in one
    /// transaction, so a mission is never observed half-advanced.
    ///
    /// Reported rather than thrown — an executor must not take the engine down
    /// over a transient write failure; the next tick re-evaluates from whatever
    /// the row still says.
    private static func commit(_ directive: Directive, _ entries: [DirectiveLogEntry]) async {
        @Dependency(\.defaultDatabase) var database
        do {
            try await database.write { db in
                try Directive.upsert { directive }.execute(db)
                for entry in entries {
                    try DirectiveLogEntry.insert { entry }.execute(db)
                }
            }
        } catch {
            logger.error("directive \(directive.id, privacy: .public) write failed: \(error)")
        }
    }
}
