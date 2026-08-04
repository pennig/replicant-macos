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
//  visible in the detail pane's timeline (V3.9 blocker 5: the audit trail IS the
//  browsing UI). Each action commits exactly once, so a mission can never be
//  observed half-advanced.
//

import Dependencies
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "DirectiveEngine")

enum DirectiveExecutor {
    /// Apply one action. Returns whether the directive is still runnable — a
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
            // Something server-side is still in progress. Deliberately writes
            // nothing: a wait that logged would bury the timeline in noise.
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
                        entry(directive, .commandDispatched, "Dispatched \(kind.rawValue) to \(deviceCode)",
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
            // scoped to ONE controller rather than to the whole pass. No
            // other `move(...)` call site passes this, so every other
            // `.stepStarted` entry keeps writing `deviceCode: nil` exactly as
            // before.
            await move(directive, to: nextStep, controllerCode: deviceCode, deviceCode: deviceCode)
            return true

        case let .refreshSystem(designation, nextStep):
            // Best-effort by contract: the endpoint 403s away from the system,
            // and a stale cache just means the confirming step waits. Stalling
            // on a transient read would strand a mission that is fine.
            @Dependency(\.locationsClient) var locationsClient
            try? await locationsClient.hydrateSystem(designation: designation)
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
                // the server, exactly as the tag editor does after its own PATCH
                // (`DevicesClient.updateTags`'s doc: the follow-up read is the
                // caller's job). A failed read here is not itself an error —
                // the PATCH already landed; the next poll or SSE echo catches
                // the row up.
                _ = await deviceRefresher.refresh(deviceCode, .high)
            } catch {
                logger.notice("directive \(directive.id, privacy: .public): tag update for \(deviceCode, privacy: .public) failed: \(error) — advancing anyway")
            }
            await move(directive, to: nextStep, controllerCode: directive.controllerCode)
            return true

        case let .refreshDevices(_, thenStall), let .refreshDevicesInSystem(_, thenStall),
             let .refreshFleet(_, thenStall), let .refreshFootprint(_, thenStall):
            // The engine resolves this one before it ever reaches the executor
            // (it needs a second world read and a second call into the machine —
            // see `DirectiveEngineCore.resolveFootprintRefresh` for the
            // `.refreshFootprint` case specifically, added 2026-08-03 after an
            // earlier "refresh then move" shape here self-looped unbounded on a
            // persistently-unreadable census). Reaching here means that
            // resolution was bypassed, so honour the carried fallback rather
            // than silently dropping the action.
            guard let thenStall else { return true }
            logger.notice("directive \(directive.id, privacy: .public): unresolved refresh — stalling with \(thenStall.rawValue, privacy: .public)")
            await stall(directive, reason: thenStall, detail: nil)
            return false

        case .extendQueue:
            // The engine resolves this before it ever reaches the executor (it
            // needs a census read and a second call into the machine). Reaching
            // here means that resolution was bypassed, which is a programming
            // error rather than a world state — so say so loudly and leave the
            // row alone. The next tick re-evaluates and will say the same thing,
            // which is recoverable (the user can cancel) and visible in the log,
            // where silently returning `.done` would look like a finished run.
            logger.error("directive \(directive.id, privacy: .public): unresolved extendQueue reached the executor — leaving the row untouched")
            return true

        case let .stall(reason):
            await stall(directive, reason: reason, detail: nil)
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

    /// Write an `.opCompleted` entry for every op this directive dispatched that
    /// has since reached a terminal state and doesn't already have one.
    ///
    /// **Audit only — this must never change a directive's status, step or target.**
    /// It appends log rows and nothing else, which is what makes it safe to run on
    /// every tick ahead of the machine. Mission progress continues to key off the
    /// `directive.completed` entry and the machine's own conditions; if this pass
    /// were deleted tomorrow, execution would be byte-identical and only the
    /// timeline would go quiet again. Keep that property.
    ///
    /// Without it a long op reads as an unexplained gap: the timeline shows
    /// "Dispatched travel to X" and then nothing until the next step starts, which
    /// on a multi-hour leg is most of what the user is watching.
    ///
    /// Fires for ANY terminal status, not just `.completed`. The log kind is named
    /// for the common case, but a `failed`/`rejected`/`superseded` op closing is
    /// exactly as much of a gap-ender, and the summary names which it was. The
    /// alternative — logging only clean completions — would leave a failed op as a
    /// permanent silent hole, the very thing this closes.
    ///
    /// Idempotent through the log itself: an op id already carrying an
    /// `.opCompleted` entry is skipped, and the engine runs one executor per
    /// directive, so there is no second writer to race.
    ///
    /// Known gap, accepted: a directive that leaves `.running` before its last
    /// dispatched op closes gets no entry for that op, because `evaluateOnce`
    /// returns early for a non-running row. In practice a stall is resumed
    /// (retry/skip/resume all return it to `.running`) and the entry lands late
    /// rather than never; only a stall abandoned forever, or a mission whose final
    /// op closes after `.done`, stays silent — and neither is being watched.
    static func recordCompletedOps(for directive: Directive, world: WorldSnapshot) async {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid

        // Op ids already accounted for, so a closed op is logged exactly once.
        let alreadyLogged = Set(world.log.compactMap { entry in
            entry.kind == .opCompleted ? entry.operationID : nil
        })

        var entries: [DirectiveLogEntry] = []
        for dispatch in world.log where dispatch.kind == .commandDispatched {
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

    /// "travel completed" / "travel failed" — the op's kind plus how it ended, so a
    /// terminal-but-unsuccessful op doesn't read as a clean finish.
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

    /// Append timeline entries WITHOUT touching the directive row — the audit
    /// pass's write path. Deliberately not `commit`: upserting the row here could
    /// clobber a concurrent status change with this pass's older copy, and the
    /// pass has no business moving the mission anyway.
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

    /// Move to a step, optionally claiming a controller, with the matching
    /// timeline entry. `stepStartedAt` is re-stamped: it is the reference point
    /// for the issue-time-relative completion guard.
    ///
    /// `deviceCode` defaults to nil and is separate from `controllerCode`
    /// (which every caller sets, usually to `directive.controllerCode`
    /// unchanged): it exists so the ONE caller claiming a NEW controller this
    /// tick (`.assignController`) can stamp the timeline entry with who was
    /// claimed, without every other transition's entries picking up a
    /// leftover value.
    private static func move(
        _ directive: Directive,
        to nextStep: String,
        controllerCode: String?,
        deviceCode: String? = nil
    ) async {
        @Dependency(\.date) var date
        @Dependency(\.uuid) var uuid
        var updated = directive
        updated.step = nextStep
        updated.controllerCode = controllerCode
        updated.stepStartedAt = date.now
        updated.updatedAt = date.now
        await commit(updated, [
            entry(directive, .stepStarted, "Step: \(nextStep)",
                  step: nextStep, operationID: nil, deviceCode: deviceCode,
                  id: uuid().uuidString, at: date.now),
        ])
    }

    /// Pause and surface (design spec §8) — a typed reason, never a retry at
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

    /// `deviceCode` defaults to nil, matching every call site except
    /// `move`'s own — see `move`'s doc comment for why only that path sets it.
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

    /// The single write site: the row and its timeline entries land in one
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
