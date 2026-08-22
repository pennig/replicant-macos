//
//  CommandClient.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The action-dispatch template: insert an optimistic `Operation`, POST,
//  confirm on success (active/enqueued; prints queue instead of
//  superseding), then read the device authoritatively. A 4xx rejects the
//  optimistic op and leaves any prior op untouched. No auto-retry.
//
//  Family-agnostic spine — per-family bodies live in `CommandClient+<Family>.swift`.

import API
import Dependencies
import Foundation
import GameModels
import GameSession
import OpenAPIRuntime
import OSLog
import SQLiteData
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Command")

public struct CommandClient: Sendable {
    /// Fire a command at a device. Never throws — the result is reported as a
    /// `CommandOutcome` (and also recorded on the operation row), so the caller
    /// can surface a rejection/failure while the UI still mostly observes tables.
    public var dispatch: @Sendable (_ kind: OperationKind, _ deviceCode: String, _ params: CommandParams) async -> CommandOutcome

    /// Same as `dispatch`, but attributes the written `Operation` row to the
    /// dispatching directive step when `owner` is non-nil. `dispatch` calls
    /// this with `owner: nil`.
    public var dispatchOwned: @Sendable (
        _ kind: OperationKind, _ deviceCode: String, _ params: CommandParams, _ owner: CommandOwner?
    ) async -> CommandOutcome

    /// Preview a `travel` command via `dry_run`: ask the server to plot the
    /// route without dispatching the device, so the user can confirm the
    /// itinerary first. Never throws — the result is a `TravelPreviewOutcome`.
    /// Stages no optimistic op and takes no device read; nothing about game
    /// state changes.
    public var previewTravel: @Sendable (_ deviceCode: String, _ destination: String) async -> TravelPreviewOutcome
}

/// What happened when a command was dispatched. `accepted` means the server took
/// it (the op is now active/enqueued); `rejected` is a server 4xx (busy/illegal,
/// with the server's message); `failed` is a transport/encoding error.
public enum CommandOutcome: Sendable, Equatable {
    /// The server took the command. `operationID` is the tracked op's id for
    /// long-running actions (travel/mine/print), or `nil` for immediate ones
    /// (scan/census/lifecycle) which create no operation row.
    case accepted(operationID: String?)
    case rejected(String)
    case failed(String)

    /// The user-facing message for a non-accepted outcome, if any.
    public var failureMessage: String? {
        switch self {
        case .accepted: return nil
        case let .rejected(message), let .failed(message): return message
        }
    }
}

// MARK: - Live implementation

extension CommandClient: DependencyKey {
    public static let liveValue: CommandClient = {
        let dispatchOwned = makeDispatchOwned()
        return CommandClient(
            dispatch: { kind, deviceCode, params in
                await dispatchOwned(kind, deviceCode, params, nil)
            },
            dispatchOwned: dispatchOwned,
            previewTravel: { deviceCode, destination in
                await previewTravelLive(deviceCode: deviceCode, destination: destination)
            }
        )
    }()

    /// Built once and shared by `dispatch`/`dispatchOwned` in `liveValue` — never
    /// `Self.liveValue.dispatchOwned`, which would recurse through the static.
    private static func makeDispatchOwned() -> @Sendable (
        _ kind: OperationKind, _ deviceCode: String, _ params: CommandParams, _ owner: CommandOwner?
    ) async -> CommandOutcome {
        { kind, deviceCode, params, owner in
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.deviceRefresher) var deviceRefresher
            @Dependency(\.defaultDatabase) var database
            @Dependency(\.date) var date
            @Dependency(\.uuid) var uuid

            // Build the request body up front — a missing/invalid parameter or an
            // unsupported command fails fast, before any optimistic row is staged.
            let body: Operations.PostV1DevicesDeviceCode.Input.Body
            do {
                body = try makeBody(kind: kind, params: params)
            } catch {
                let reason = describe(error)
                logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): \(reason, privacy: .public)")
                return .failed(reason)
            }

            // Immediate commands POST once and write one terminal `Operation`
            // row; a terminating command also closes any open op it stops.
            if completion(for: kind) == .immediate {
                let status: OperationStatus
                let message: String?
                do {
                    let output = try await gameClient().postV1DevicesDeviceCode(
                        path: .init(deviceCode: deviceCode), body: body
                    )
                    switch output {
                    case let .ok(ok):
                        logger.info("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): accepted (immediate)")
                        if terminatingCommands.contains(kind.rawValue) {
                            await Reconciler().completeOpenOperation(
                                on: deviceCode, source: .poll, eventTime: nil, result: nil
                            )
                        }
                        let responseJSON = (try? ok.body.json).map(jsonValue(from:)) ?? .object([:])
                        if kind == .scan {
                            await recordScanSightings(from: responseJSON)
                        }
                        // Post-command confirm-read through the coordinator (B4):
                        // reconcile happens inside its task, and the read stamps
                        // `lastReadAt`, so the command's near-certain SSE echo a
                        // beat later is TTL-suppressed instead of read again.
                        let readDevice = await deviceRefresher.refresh(deviceCode, .high)
                        if kind == .depositResources, let location = readDevice?.location {
                            await refreshOpenLocationEvents(at: location)
                        }
                        await refreshAffectedDevices(in: responseJSON, excluding: deviceCode)
                        status = .completed
                        message = nil
                    case let .badRequest(response):
                        let reason = errorMessage(response.body)
                        logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): rejected (400) — \(reason, privacy: .public)")
                        status = .rejected
                        message = reason
                    case let .forbidden(response):
                        let reason = errorMessage(response.body)
                        logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): rejected (403) — \(reason, privacy: .public)")
                        status = .rejected
                        message = reason
                    case let .notFound(response):
                        let reason = errorMessage(response.body)
                        logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): rejected (404) — \(reason, privacy: .public)")
                        status = .rejected
                        message = reason
                    case let .default(statusCode, _):
                        let reason = "Server error (\(statusCode))."
                        logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): \(reason, privacy: .public)")
                        status = .failed
                        message = reason
                    case .created:
                        // 201 is only returned by `replicate`, which dispatches via
                        // `ReplicantsClient` — not through here — so treat it as unexpected.
                        logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): unexpected 201")
                        status = .failed
                        message = "Unexpected server response."
                    @unknown default:
                        status = .failed
                        message = "Unexpected server response."
                    }
                } catch {
                    status = throwStatus(error)
                    logger.error("dispatch \(kind.rawValue, privacy: .public): \(status.rawValue, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                    message = error.localizedDescription
                }

                let stamp = date.now
                var detail: JSONValue = .object(["params": params.json])
                if let message { detail = detail.adding("message", .string(message)) }
                let record = Operation(
                    id: uuid().uuidString, entityCode: deviceCode, kind: kind.rawValue,
                    status: status,
                    source: .optimistic,
                    startedAt: stamp, completesAt: nil, lastConfirmedAt: stamp,
                    detail: detail,
                    directiveID: owner?.directiveID, step: owner?.step, paramsDigest: params.dedupKey
                )
                try? await database.write { db in try Operation.insert { record }.execute(db) }

                switch status {
                case .completed: return .accepted(operationID: nil)
                case .rejected:  return .rejected(message ?? "The command was rejected.")
                default:         return .failed(message ?? "Unexpected server response.")
                }
            }

            // Tracked commands (travel/mine/print): full optimistic lifecycle.
            let opID = uuid().uuidString
            let started = date.now

            // 1) Optimistic insert — instant UI. `optimistic` sits outside the
            //    active-uniqueness index, so it never conflicts with a prior op.
            let optimistic = Operation(
                id: opID, entityCode: deviceCode, kind: kind.rawValue,
                status: .optimistic,
                source: OperationSource.optimistic,
                startedAt: started, completesAt: nil, lastConfirmedAt: started,
                detail: .object(["params": params.json]),
                directiveID: owner?.directiveID, step: owner?.step, paramsDigest: params.dedupKey
            )
            try? await database.write { db in try Operation.insert { optimistic }.execute(db) }
            logger.info("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): optimistic op \(opID, privacy: .public)")

            // 2) POST the command.
            do {
                let output = try await gameClient().postV1DevicesDeviceCode(
                    path: .init(deviceCode: deviceCode), body: body
                )

                switch output {
                case let .ok(ok):
                    let response = try ok.body.json
                    // 3) Confirm. The op's status + deadline follow the command's
                    //    completion class: travel is self-describing (a deadline →
                    //    active); mining is continuous (active, no deadline — runs
                    //    until stopped); print is enqueued (completes later via a
                    //    stream event).
                    let confirmed: OperationStatus
                    let completesAt: Date?
                    switch completion(for: kind) {
                    case .deadline:   confirmed = .active;    completesAt = parseDeadline(from: response)
                    case .continuous: confirmed = .active;    completesAt = nil
                    case .enqueued:   confirmed = .enqueued;  completesAt = nil
                    case .immediate:  confirmed = .completed; completesAt = nil  // unreachable
                    }
                    let resultJSON = jsonValue(from: response)
                    let confirmedAt = date.now

                    try? await database.write { db in
                        // Travel/mining act on one target at a time and replace
                        // the old op; prints queue instead and are never superseded.
                        if kind != .print {
                            let openOps = try Operation
                                .where {
                                    $0.entityCode.eq(deviceCode)
                                        && $0.status.in(OperationStatus.liveCases)
                                        && $0.kind.neq(OperationKind.print.rawValue)
                                }
                                .fetchAll(db)
                            for var other in openOps where other.id != opID {
                                other.status = .superseded
                                other.lastConfirmedAt = confirmedAt
                                try Operation.upsert { other }.execute(db)
                            }
                        }

                        if var op = try Operation.where({ $0.id.eq(opID) }).fetchOne(db) {
                            op.status = confirmed
                            op.source = OperationSource.poll
                            op.completesAt = completesAt
                            op.lastConfirmedAt = confirmedAt
                            op.detail = .object(["params": params.json, "result": resultJSON])
                            try Operation.upsert { op }.execute(db)
                        }
                    }
                    logger.info("dispatch \(opID, privacy: .public): confirmed \(confirmed.rawValue, privacy: .public)\(completesAt.map { " · completes \($0.ISO8601Format())" } ?? "", privacy: .public)")

                    // 4) One authoritative post-command device read (§1 settled
                    //    decision): the command response is a result, not a full
                    //    device snapshot, so this refreshes status/location/detail.
                    //    Funneled through the coordinator (B4) so the read stamps
                    //    `lastReadAt` and the command's SSE echo a beat later is
                    //    TTL-suppressed (reconcile happens inside its task).
                    //    For a deadline op whose response withheld the ETA (e.g.
                    //    `search`, whose countdown lives in the device's `scan`
                    //    block), back-fill `completesAt` from the fresh snapshot so
                    //    the progress bar and deadline scheduler have a deadline.
                    if let device = await deviceRefresher.refresh(deviceCode, .high) {
                        if completesAt == nil, let derived = device.activityDeadline {
                            try? await database.write { db in
                                if var op = try Operation.where({ $0.id.eq(opID) }).fetchOne(db),
                                   op.status == .active,
                                   op.completesAt == nil {
                                    op.completesAt = derived
                                    try Operation.upsert { op }.execute(db)
                                }
                            }
                        }
                    }
                    return .accepted(operationID: opID)

                case let .badRequest(response):
                    let reason = errorMessage(response.body)
                    logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public) [\(opID, privacy: .public)]: rejected (400) — \(reason, privacy: .public)")
                    await finish(opID, as: .rejected, reason: reason, at: date.now, database: database)
                    return .rejected(reason)
                case let .forbidden(response):
                    let reason = errorMessage(response.body)
                    logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public) [\(opID, privacy: .public)]: rejected (403) — \(reason, privacy: .public)")
                    await finish(opID, as: .rejected, reason: reason, at: date.now, database: database)
                    return .rejected(reason)
                case let .notFound(response):
                    let reason = errorMessage(response.body)
                    logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public) [\(opID, privacy: .public)]: rejected (404) — \(reason, privacy: .public)")
                    await finish(opID, as: .rejected, reason: reason, at: date.now, database: database)
                    return .rejected(reason)
                case let .default(statusCode, _):
                    let reason = "Server error (\(statusCode))."
                    logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public) [\(opID, privacy: .public)]: \(reason, privacy: .public)")
                    await finish(opID, as: .failed, reason: reason, at: date.now, database: database)
                    return .failed(reason)
                case .created:
                    // 201 is only returned by `replicate` (dispatched via `ReplicantsClient`),
                    // never by a tracked command — treat as unexpected.
                    logger.warning("dispatch \(opID, privacy: .public): unexpected 201")
                    await finish(opID, as: .failed, reason: "Unexpected server response.", at: date.now, database: database)
                    return .failed("Unexpected server response.")
                @unknown default:
                    logger.error("dispatch \(opID, privacy: .public): unexpected server response")
                    await finish(opID, as: .failed, reason: "Unexpected server response.", at: date.now, database: database)
                    return .failed("Unexpected server response.")
                }
            } catch {
                // Not a server rejection, so the caller still hears `.failed`;
                // only the ROW distinguishes never-sent from unreadable-reply.
                let status = throwStatus(error)
                logger.error("dispatch \(opID, privacy: .public): \(status.rawValue, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                await finish(opID, as: status, reason: error.localizedDescription, at: date.now, database: database)
                return .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Completion classification

    /// How a command reports completion — derived from live probing of the API
    /// (see IMPLEMENTATION_PLAN §10). Drives the confirmed `Operation` status and
    /// whether dispatch tracks an op at all.
    private enum Completion {
        case deadline    // travel — self-describing with `arrives_at` → active
        case continuous  // mining — `mining_started`, no deadline; runs until stopped
        case enqueued    // print — queued; completes via a later stream event
        case immediate   // scan/census/lifecycle — synchronous answer, no tracked op
    }

    private static func completion(for kind: OperationKind) -> Completion {
        switch kind {
        case .travel:     return .deadline
        case .mine:       return .continuous
        case .print:      return .enqueued
        case .surveyScan: return .deadline
        default:          return deadlineCommands.contains(kind.rawValue) ? .deadline : .immediate
        }
    }

    // MARK: Body routing

    /// Map a kind + params onto the generated `oneOf` command body. Each case is
    /// one line into its family's builder (`CommandClient+<Family>.swift`);
    /// parameter-less lifecycle commands route through `simpleBody`.
    private static func makeBody(
        kind: OperationKind,
        params: CommandParams
    ) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        switch kind {
        case .travel:           return try travelBody(params)
        case .mine:             return try mineBody(params)
        case .retarget:         return try retargetBody(params)
        case .print:            return try printBody(params)
        case .dequeuePrint:     return try dequeuePrintBody(params)
        case .scan:             return systemScanBody()
        case .surveyScan:       return surveyScanBody()
        case .census:           return censusBody()
        case .adopt:            return try adoptBody(params)
        case .release:          return try releaseBody(params)
        case .attach:           return try attachBody(params)
        case .detach:           return try detachBody(params)
        case .collectResources: return try collectResourcesBody(params)
        case .depositResources: return try depositResourcesBody(params)
        case .stow:             return stowBody(params)
        case .setDirective:     return try setDirectiveBody(params)
        case .configure:        return try configureBody(params)
        case .message:          return try messageBody(params)
        case .repair:           return try repairBody(params)
        case .changeOwner:      return try changeOwnerBody(params)
        default:
            guard let body = simpleBody(for: kind.rawValue) else { throw CommandError.unsupported(kind) }
            return body
        }
    }

    // MARK: Response plumbing (shared across families)

    /// The deadline a self-describing command reports, from the known
    /// completion-time fields of the shared response.
    ///
    /// The travel pair goes through `Device.travelDeadline`, which knows that
    /// `final_arrives_at` is the *whole route's* end (so it outranks the
    /// current leg's `arrives_at`, or a multi-leg trip completes a leg early)
    /// but only while it is actually later — a stale route end left over from a
    /// previous journey must not stamp a deadline already in the past.
    private static func parseDeadline(
        from response: Components.Schemas.AppSchemasDevicesDeviceCommandResponseSchema
    ) -> Date? {
        let travel = Device.travelDeadline(
            routeEnd: response.finalArrivesAt.flatMap(parseTimestamp),
            legEnd: response.arrivesAt.flatMap(parseTimestamp)
        )
        return travel ?? response.completesAt.flatMap(parseTimestamp)
    }

    /// A user-facing message for a body-construction failure.
    private static func describe(_ error: Error) -> String {
        switch error {
        case let CommandError.missingParameter(name): return "Missing required parameter: \(name)."
        case let CommandError.invalidParameter(name, value): return "Invalid \(name): “\(value)”."
        case let CommandError.unsupported(kind): return "Command not supported: \(kind.rawValue)."
        default: return error.localizedDescription
        }
    }

    /// How to record a thrown dispatch: `.failed` only when the request provably
    /// never reached the server, `.unknown` once it answered. `ClientError.response`
    /// is nil exactly until a response is received, so a body the schema cannot
    /// decode lands here having already taken effect
    /// (memory: failed-means-never-sent.md).
    static func throwStatus(_ error: Error) -> OperationStatus {
        (error as? ClientError)?.response == nil ? .failed : .unknown
    }

    private static func finish(
        _ opID: String,
        as status: OperationStatus,
        reason: String,
        at confirmedAt: Date,
        database: any DatabaseWriter
    ) async {
        try? await database.write { db in
            guard var op = try Operation.where({ $0.id.eq(opID) }).fetchOne(db) else { return }
            op.status = status
            op.lastConfirmedAt = confirmedAt
            op.detail = .object(["error": .string(reason)])
            try Operation.upsert { op }.execute(db)
        }
    }

    static func errorMessage(_ body: Operations.PostV1DevicesDeviceCode.Output.BadRequest.Body) -> String {
        (try? body.json.error) ?? "The command was rejected."
    }
    static func errorMessage(_ body: Operations.PostV1DevicesDeviceCode.Output.Forbidden.Body) -> String {
        (try? body.json.error) ?? "Not permitted."
    }
    static func errorMessage(_ body: Operations.PostV1DevicesDeviceCode.Output.NotFound.Body) -> String {
        (try? body.json.error) ?? "Device not found."
    }

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Re-encode a generated response into a `JSONValue` for `Operation.detail`.
    private static func jsonValue(from value: some Encodable) -> JSONValue {
        guard
            let data = try? jsonEncoder.encode(value),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .object([:]) }
        return json
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()

    private static func parseTimestamp(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: isoWithFraction) { return date }
        if let date = try? Date(string, strategy: isoPlain) { return date }
        return nil
    }
}

public enum CommandError: Error, Equatable {
    case missingParameter(String)
    case invalidParameter(String, String)
    case unsupported(OperationKind)
}

// MARK: - Test / preview implementation

extension CommandClient: TestDependencyKey {
    /// Unimplemented by default so a test that dispatches without stubbing it
    /// fails loudly (a quiet stub let "forgot to stub" tests pass silently —
    /// V3.6-T5). Tests that exercise dispatch use the live value over a
    /// stubbed `gameClient`.
    public static let testValue = CommandClient(
        dispatch: unimplemented("CommandClient.dispatch", placeholder: .failed("unimplemented")),
        dispatchOwned: unimplemented("CommandClient.dispatchOwned", placeholder: .failed("unimplemented")),
        previewTravel: unimplemented("CommandClient.previewTravel", placeholder: .failed("unimplemented"))
    )

    /// Previews keep the old inert behavior — a preview that taps a command
    /// button should quietly "accept", not surface a runtime-issue banner.
    public static let previewValue = CommandClient(
        dispatch: { _, _, _ in .accepted(operationID: "preview-op") },
        dispatchOwned: { _, _, _, _ in .accepted(operationID: "preview-op") },
        previewTravel: { _, _ in .plan(TravelPlan()) }
    )
}

extension DependencyValues {
    public var commandClient: CommandClient {
        get { self[CommandClient.self] }
        set { self[CommandClient.self] = newValue }
    }
}
