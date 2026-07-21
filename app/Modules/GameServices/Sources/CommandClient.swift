//
//  CommandClient.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The action-dispatch template (IMPLEMENTATION_PLAN §5.1). Firing a command is
//  one write path: insert an optimistic `Operation` (instant UI via @FetchAll) →
//  POST the command → on success confirm the op (active with a deadline for
//  self-describing actions like travel, or enqueued for ones like print),
//  supersede any prior open op, and take one authoritative post-command device
//  read; on a 4xx, reject the optimistic op (the prior op is left untouched).
//  No auto-retry. The UI never inspects the response — it observes the tables.
//
//  This file is the family-agnostic spine: the dispatch lifecycle, the
//  completion classification, and response/error plumbing. Everything a
//  specific command family owns — its request body, its post-dispatch side
//  effects — lives in that family's `CommandClient+<Family>.swift` file, so a
//  new family is a new file plus one routing line in `makeBody`, not another
//  hundred lines here.
//
//  Lives beside the `Operation` table and `Reconciler` (shared infrastructure)
//  rather than in a feature, so both the Devices feature and tests can drive
//  it. Exposed via `@Dependency(\.commandClient)`.
//

import API
import Dependencies
import Foundation
import GameModels
import GameSession
import OSLog
import SQLiteData
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Command")

public struct CommandClient: Sendable {
    /// Fire a command at a device. Never throws — the result is reported as a
    /// `CommandOutcome` (and also recorded on the operation row), so the caller
    /// can surface a rejection/failure while the UI still mostly observes tables.
    public var dispatch: @Sendable (_ kind: OperationKind, _ deviceCode: String, _ params: CommandParams) async -> CommandOutcome

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
    public static let liveValue = CommandClient(
        dispatch: { kind, deviceCode, params in
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

            // Immediate commands (scan/census reads + status-only lifecycle) are
            // not long-running, so they create no Operation row and never
            // supersede a device's running action. POST, then take the single
            // authoritative device read so status/location refresh. A terminating
            // command (recall/deactivate/decommission) also closes the device's
            // open op, since it stops whatever was running.
            if completion(for: kind) == .immediate {
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
                        return .accepted(operationID: nil)
                    case let .badRequest(response):
                        let reason = errorMessage(response.body)
                        logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): rejected (400) — \(reason, privacy: .public)")
                        return .rejected(reason)
                    case let .forbidden(response):
                        let reason = errorMessage(response.body)
                        logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): rejected (403) — \(reason, privacy: .public)")
                        return .rejected(reason)
                    case let .notFound(response):
                        let reason = errorMessage(response.body)
                        logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): rejected (404) — \(reason, privacy: .public)")
                        return .rejected(reason)
                    case let .default(statusCode, _):
                        let reason = "Server error (\(statusCode))."
                        logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): \(reason, privacy: .public)")
                        return .failed(reason)
                    case .created:
                        // 201 is only returned by `replicate`, which dispatches via
                        // `ReplicantsClient` — not through here — so treat it as unexpected.
                        logger.warning("dispatch \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public): unexpected 201")
                        return .failed("Unexpected server response.")
                    @unknown default:
                        return .failed("Unexpected server response.")
                    }
                } catch {
                    logger.error("dispatch \(kind.rawValue, privacy: .public): failed — \(error.localizedDescription, privacy: .public)")
                    return .failed(error.localizedDescription)
                }
            }

            // Tracked commands (travel/mine/print): full optimistic lifecycle.
            let opID = uuid().uuidString
            let started = date.now

            // 1) Optimistic insert — instant UI. `optimistic` is excluded from
            //    the open-uniqueness index, so this never conflicts with a prior
            //    op that this command might replace.
            let optimistic = Operation(
                id: opID, entityCode: deviceCode, kind: kind.rawValue,
                status: .optimistic,
                source: OperationSource.optimistic,
                startedAt: started, completesAt: nil, lastConfirmedAt: started,
                detail: .object(["params": params.json])
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
                        // Supersede any *other* open op on this device first (so
                        // the open-uniqueness index has room), then confirm this
                        // one. Whole-row upserts keep the typed JSON/optional
                        // columns straightforward.
                        let openOps = try Operation
                            .where {
                                $0.entityCode.eq(deviceCode)
                                    && $0.status.in(OperationStatus.liveCases)
                            }
                            .fetchAll(db)
                        for var other in openOps where other.id != opID {
                            other.status = .superseded
                            other.lastConfirmedAt = confirmedAt
                            try Operation.upsert { other }.execute(db)
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
                    logger.warning("dispatch \(opID, privacy: .public): rejected (400) — \(reason, privacy: .public)")
                    await finish(opID, as: .rejected, reason: reason, at: date.now, database: database)
                    return .rejected(reason)
                case let .forbidden(response):
                    let reason = errorMessage(response.body)
                    logger.warning("dispatch \(opID, privacy: .public): rejected (403) — \(reason, privacy: .public)")
                    await finish(opID, as: .rejected, reason: reason, at: date.now, database: database)
                    return .rejected(reason)
                case let .notFound(response):
                    let reason = errorMessage(response.body)
                    logger.warning("dispatch \(opID, privacy: .public): rejected (404) — \(reason, privacy: .public)")
                    await finish(opID, as: .rejected, reason: reason, at: date.now, database: database)
                    return .rejected(reason)
                case let .default(statusCode, _):
                    let reason = "Server error (\(statusCode))."
                    logger.warning("dispatch \(opID, privacy: .public): \(reason, privacy: .public)")
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
                // Network / encoding error — not a server rejection. No retry.
                logger.error("dispatch \(opID, privacy: .public): failed — \(error.localizedDescription, privacy: .public)")
                await finish(opID, as: .failed, reason: error.localizedDescription, at: date.now, database: database)
                return .failed(error.localizedDescription)
            }
        },
        previewTravel: { deviceCode, destination in
            await previewTravelLive(deviceCode: deviceCode, destination: destination)
        }
    )

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
        default:
            guard let body = simpleBody(for: kind.rawValue) else { throw CommandError.unsupported(kind) }
            return body
        }
    }

    // MARK: Response plumbing (shared across families)

    /// The deadline a self-describing command reports, trying the known
    /// completion-time fields of the shared response in priority order. For
    /// travel, `final_arrives_at` is the *whole route's* end while `arrives_at`
    /// is only the current/first leg — so it must come first, or a multi-leg
    /// trip's deadline lands at the first waypoint and the op completes a leg
    /// early.
    private static func parseDeadline(
        from response: Components.Schemas.AppSchemasDevicesDeviceCommandResponseSchema
    ) -> Date? {
        for field in [response.finalArrivesAt, response.arrivesAt, response.completesAt] {
            if let field, let date = parseTimestamp(field) { return date }
        }
        return nil
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
        previewTravel: unimplemented("CommandClient.previewTravel", placeholder: .failed("unimplemented"))
    )

    /// Previews keep the old inert behavior — a preview that taps a command
    /// button should quietly "accept", not surface a runtime-issue banner.
    public static let previewValue = CommandClient(
        dispatch: { _, _, _ in .accepted(operationID: "preview-op") },
        previewTravel: { _, _ in .plan(TravelPlan()) }
    )
}

extension DependencyValues {
    public var commandClient: CommandClient {
        get { self[CommandClient.self] }
        set { self[CommandClient.self] = newValue }
    }
}
