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
//  Lives beside the `Operation` table and `Reconciler` (shared infrastructure)
//  rather than in a feature, so both the (future) Devices feature and tests can
//  drive it. Exposed via `@Dependency(\.commandClient)`.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import OSLog
import SQLiteData
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Command")

/// Command-specific parameters. Only the fields a given command needs are set.
public struct CommandParams: Sendable, Equatable {
    public var destination: String?   // travel
    public var deviceType: String?    // print (enqueue_print)
    public var resourceType: String?  // mine (start_mining) — one of the belt resources
    public var target: String?        // mine — optional resource-site designation
    public var directive: String?     // set_directive — one of the device's available_directives
    public var index: Int?            // dequeue_print — the queue position to remove
    /// set_directive — the directive's optional configuration object (e.g. a
    /// survey controller's `{planets, moons, recall}`). Loosely typed since the
    /// shape varies per directive; nil/empty omits it.
    public var configuration: [String: JSONValue]?
    /// adopt — the device codes an AMI controller should take under its control.
    public var devices: [String]?

    public init(
        destination: String? = nil,
        deviceType: String? = nil,
        resourceType: String? = nil,
        target: String? = nil,
        directive: String? = nil,
        index: Int? = nil,
        configuration: [String: JSONValue]? = nil,
        devices: [String]? = nil
    ) {
        self.destination = destination
        self.deviceType = deviceType
        self.resourceType = resourceType
        self.target = target
        self.directive = directive
        self.index = index
        self.configuration = configuration
        self.devices = devices
    }

    var json: JSONValue {
        var dict: [String: JSONValue] = [:]
        if let destination { dict["destination"] = .string(destination) }
        if let deviceType { dict["device_type"] = .string(deviceType) }
        if let resourceType { dict["resource_type"] = .string(resourceType) }
        if let target { dict["target"] = .string(target) }
        if let directive { dict["directive"] = .string(directive) }
        if let index { dict["index"] = .number(Double(index)) }
        if let configuration, !configuration.isEmpty { dict["configuration"] = .object(configuration) }
        if let devices, !devices.isEmpty { dict["devices"] = .array(devices.map(JSONValue.string)) }
        return .object(dict)
    }
}

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
            @Dependency(\.devicesClient) var devicesClient
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
                                on: deviceCode, source: .poll, eventTime: date.now, result: nil
                            )
                        }
                        let responseJSON = (try? ok.body.json).map(jsonValue(from:)) ?? .object([:])
                        // A `system_scan` response carries a `replicants` block —
                        // everyone detected in the scanned system, with a precise
                        // `location` and `last_active`. Record those sightings so
                        // player replicants (whose position the directory withholds)
                        // get an accurate last-known-location.
                        if kind == .scan {
                            let sightings = KnownReplicant.scanSightings(from: responseJSON)
                            if !sightings.isEmpty {
                                try? await database.write { db in
                                    try KnownReplicant.record(sightings: sightings, into: db, now: date.now)
                                }
                                logger.info("scan recorded \(sightings.count, privacy: .public) replicant sighting(s)")
                            }
                        }
                        if let device = try? await devicesClient.read(deviceCode) {
                            await Reconciler().ingest(device)
                        }
                        // Topology commands (attach/detach/adopt/release) move *other*
                        // devices onto or off this one — the response names them in an
                        // `attached`/`detached`/`adopted`/`released` block. Read each so
                        // its status/carrier/controller reflects the new topology now,
                        // rather than lagging until the next poll.
                        let affected = affectedDeviceCodes(in: responseJSON).filter { $0 != deviceCode }
                        for code in affected {
                            if let device = try? await devicesClient.read(code) {
                                await Reconciler().ingest(device)
                            }
                        }
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
                    //    relay event).
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
                    //    For a deadline op whose response withheld the ETA (e.g.
                    //    `search`, whose countdown lives in the device's `scan`
                    //    block), back-fill `completesAt` from the fresh snapshot so
                    //    the progress bar and deadline scheduler have a deadline.
                    if let device = try? await devicesClient.read(deviceCode) {
                        await Reconciler().ingest(device)
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
            @Dependency(\.gameClient) var gameClient

            // A dry-run travel: same endpoint, `dry_run: true`. The server plots
            // the route and returns it with `status: "preview"` and no
            // `arrives_at` — nothing is dispatched, so we stage no op and take no
            // device read.
            let body: Operations.PostV1DevicesDeviceCode.Input.Body =
                .json(.travel(.init(command: "travel", destination: destination, dryRun: true)))
            do {
                let output = try await gameClient().postV1DevicesDeviceCode(
                    path: .init(deviceCode: deviceCode), body: body
                )
                switch output {
                case let .ok(ok):
                    let response = try ok.body.json
                    guard let plan = travelPlan(from: response) else {
                        logger.warning("preview travel → \(deviceCode, privacy: .public): unreadable plan")
                        return .failed("Couldn’t read the travel preview.")
                    }
                    logger.info("preview travel → \(deviceCode, privacy: .public): \(plan.route.count, privacy: .public) leg(s)")
                    return .plan(plan)
                case let .badRequest(response):
                    let reason = errorMessage(response.body)
                    logger.warning("preview travel → \(deviceCode, privacy: .public): rejected (400) — \(reason, privacy: .public)")
                    return .rejected(reason)
                case let .forbidden(response):
                    let reason = errorMessage(response.body)
                    logger.warning("preview travel → \(deviceCode, privacy: .public): rejected (403) — \(reason, privacy: .public)")
                    return .rejected(reason)
                case let .notFound(response):
                    let reason = errorMessage(response.body)
                    logger.warning("preview travel → \(deviceCode, privacy: .public): rejected (404) — \(reason, privacy: .public)")
                    return .rejected(reason)
                case let .default(statusCode, _):
                    return .failed("Server error (\(statusCode)).")
                @unknown default:
                    return .failed("Unexpected server response.")
                }
            } catch {
                logger.error("preview travel → \(deviceCode, privacy: .public): failed — \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        }
    )

    // MARK: Helpers

    private typealias NoParam = Components.Schemas.AppSchemasDeviceCommandsNoParamSchema
    private typealias MiningSchema = Components.Schemas.AppSchemasDeviceCommandsStartMiningSchema
    private typealias RetargetSchema = Components.Schemas.AppSchemasDeviceCommandsRetargetSchema
    private typealias SetDirectiveSchema = Components.Schemas.AppSchemasDeviceCommandsSetDirectiveSchema
    private typealias AdoptSchema = Components.Schemas.AppSchemasDeviceCommandsAdoptSchema
    private typealias ReleaseSchema = Components.Schemas.AppSchemasDeviceCommandsReleaseSchema
    private typealias AttachSchema = Components.Schemas.AppSchemasDeviceCommandsAttachSchema
    private typealias DetachSchema = Components.Schemas.AppSchemasDeviceCommandsDetachSchema
    private typealias CommandResponse = Components.Schemas.AppSchemasDevicesDeviceCommandResponseSchema

    /// How a command reports completion — derived from live probing of the API
    /// (see IMPLEMENTATION_PLAN §10). Drives the confirmed `Operation` status and
    /// whether dispatch tracks an op at all.
    private enum Completion {
        case deadline    // travel — self-describing with `arrives_at` → active
        case continuous  // mining — `mining_started`, no deadline; runs until stopped
        case enqueued    // print — queued; completes via a later relay event
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

    /// No-param commands that are nonetheless self-describing with a deadline —
    /// e.g. `recall` cruises the device home to stow on the nearest craft and
    /// returns `arrives_at`, so it's a tracked deadline op like travel (its
    /// tracked-path supersede ends any in-flight mining/travel op). `search` is a
    /// long-running survey scan whose deadline lives in the device's `scan` block
    /// (`eta_seconds`) rather than the dispatch response, so it's tracked here and
    /// its `completesAt` is back-filled from the post-command read below. `compact`
    /// packs the device down for transport over a fixed window and returns
    /// `completes_at`, so it's a tracked deadline op too; `unfurl` is its inverse
    /// (expanding a packed device back) and behaves identically.
    private static let deadlineCommands: Set<String> = ["recall", "search", "compact", "unfurl"]

    /// Immediate commands that stop a device's running action — closing its open
    /// operation so a lingering mining/travel row doesn't survive the stop.
    /// (`recall` is excluded — it's deadline-tracked and supersedes instead.)
    private static let terminatingCommands: Set<String> = ["deactivate", "decommission", "stow"]

    /// Map a kind + params onto the generated `oneOf` command body. Parameterized
    /// commands (travel/mine/print) build their typed schema; simple
    /// parameter-less lifecycle commands route through `simpleBody`.
    private static func makeBody(
        kind: OperationKind,
        params: CommandParams
    ) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        switch kind {
        case .travel:
            guard let destination = params.destination else { throw CommandError.missingParameter("destination") }
            return .json(.travel(.init(command: "travel", destination: destination)))
        case .mine:
            guard let resource = params.resourceType else { throw CommandError.missingParameter("resource_type") }
            guard let payload = MiningSchema.ResourceTypePayload(rawValue: resource) else {
                throw CommandError.invalidParameter("resource_type", resource)
            }
            return .json(.startMining(.init(command: "start_mining", resourceType: payload, target: params.target)))
        case .scan:
            return .json(.systemScan(.init(command: "system_scan")))
        case .surveyScan:
            return .json(.scan(.init(command: "scan")))
        case .census:
            return .json(.stellarCensus(.init(command: "stellar_census")))
        case .retarget:
            guard let resource = params.resourceType else { throw CommandError.missingParameter("resource_type") }
            guard let payload = RetargetSchema.ResourceTypePayload(rawValue: resource) else {
                throw CommandError.invalidParameter("resource_type", resource)
            }
            return .json(.retarget(.init(command: "retarget", resourceType: payload)))
        case .stow:
            return .json(.stow(.init(command: "stow", target: params.target)))
        case .setDirective:
            guard let directive = params.directive else { throw CommandError.missingParameter("directive") }
            return .json(.setDirective(.init(
                command: "set_directive",
                directive: directive,
                configuration: try configurationPayload(from: params.configuration)
            )))
        case .adopt:
            guard let devices = params.devices, !devices.isEmpty else { throw CommandError.missingParameter("devices") }
            return .json(.adopt(try devicesSchema(AdoptSchema.self, command: "adopt", devices: devices)))
        case .release:
            guard let devices = params.devices, !devices.isEmpty else { throw CommandError.missingParameter("devices") }
            return .json(.release(try devicesSchema(ReleaseSchema.self, command: "release", devices: devices)))
        case .attach:
            // Attach carries its device codes under `targets` (per the API docs),
            // not `devices` like adopt/release. Same untyped-container shape, so
            // reuse the JSON round-trip with the `targets` key.
            guard let devices = params.devices, !devices.isEmpty else { throw CommandError.missingParameter("targets") }
            return .json(.attach(try devicesSchema(AttachSchema.self, command: "attach", devices: devices, key: "targets")))
        case .detach:
            // Detach names the target(s) to remove (the server would detach
            // everything if omitted, but the UI always picks a device). Same
            // `targets` shape as attach.
            guard let devices = params.devices, !devices.isEmpty else { throw CommandError.missingParameter("targets") }
            return .json(.detach(try devicesSchema(DetachSchema.self, command: "detach", devices: devices, key: "targets")))
        case .print:
            guard let deviceType = params.deviceType else { throw CommandError.missingParameter("device_type") }
            return .json(.enqueuePrint(.init(command: "enqueue_print", deviceType: deviceType)))
        case .dequeuePrint:
            guard let index = params.index else { throw CommandError.missingParameter("index") }
            return .json(.dequeuePrint(.init(command: "dequeue_print", index: index)))
        default:
            guard let body = simpleBody(for: kind.rawValue) else { throw CommandError.unsupported(kind) }
            return body
        }
    }

    /// Bridge the loosely-typed `set_directive` configuration into the generated
    /// schema's `ConfigurationPayload` (an untyped `additionalProperties` bag) by
    /// round-tripping through JSON — the payload's decoder slurps every key as an
    /// additional property, so arbitrary per-directive shapes pass through intact.
    /// Nil/empty configuration is omitted (the field defaults to null server-side).
    private static func configurationPayload(
        from configuration: [String: JSONValue]?
    ) throws -> SetDirectiveSchema.ConfigurationPayload? {
        guard let configuration, !configuration.isEmpty else { return nil }
        let data = try jsonEncoder.encode(JSONValue.object(configuration))
        return try JSONDecoder().decode(SetDirectiveSchema.ConfigurationPayload.self, from: data)
    }

    /// Build an `adopt`/`release`/`attach` body carrying a device-code array under
    /// `key` (`devices` for adopt/release, `targets` for attach). Those generated
    /// schemas type the field as an untyped `OpenAPIValueContainer` (the spec
    /// leaves it schemaless), so round-trip a `{command, <key>}` object through
    /// JSON — the decoder wraps the string array into the container without
    /// hand-bridging.
    private static func devicesSchema<Schema: Decodable>(
        _ type: Schema.Type, command: String, devices: [String], key: String = "devices"
    ) throws -> Schema {
        let json = JSONValue.object([
            "command": .string(command),
            key: .array(devices.map(JSONValue.string)),
        ])
        let data = try jsonEncoder.encode(json)
        return try JSONDecoder().decode(Schema.self, from: data)
    }

    /// The device codes a topology command reports it moved, gathered from the
    /// response's `attached`/`detached`/`adopted`/`released` blocks. Each block is
    /// an array of bare codes or `{device_code, …}` objects (both handled), so a
    /// dispatch can refresh those devices too — their carrier/controller, and thus
    /// status, changed alongside the device the command targeted.
    private static func affectedDeviceCodes(in json: JSONValue) -> [String] {
        var codes: [String] = []
        for key in ["attached", "detached", "adopted", "released"] {
            guard let items = json[key]?.arrayValue else { continue }
            for item in items {
                if let code = item["device_code"]?.stringValue ?? item.stringValue {
                    codes.append(code)
                }
            }
        }
        return codes
    }

    /// The supported parameter-less commands, each routed to its discriminated
    /// `oneOf` case (the body enum is closed, so only vetted verbs dispatch).
    private static func simpleBody(for command: String) -> Operations.PostV1DevicesDeviceCode.Input.Body? {
        let schema = NoParam(command: command)
        switch command {
        case "activate":        return .json(.activate(schema))
        case "deactivate":      return .json(.deactivate(schema))
        case "deploy":          return .json(.deploy(schema))
        case "recall":          return .json(.recall(schema))
        case "decommission":    return .json(.decommission(schema))
        case "clear_queue":     return .json(.clearQueue(schema))
        case "clear_directive": return .json(.clearDirective(schema))
        case "assemble":        return .json(.assemble(schema))
        case "compact":         return .json(.compact(schema))
        case "launch":          return .json(.launch(schema))
        case "unfurl":          return .json(.unfurl(schema))
        case "withdraw":        return .json(.withdraw(schema))
        case "search":          return .json(.search(schema))
        case "set_entry_point": return .json(.setEntryPoint(schema))
        case "detonate":        return .json(.detonate(schema))
        default:                return nil
        }
    }

    /// The set of parameter-less lifecycle commands `simpleBody` can dispatch —
    /// the device-side gate for surfacing them as confirm-only grid buttons.
    public static let supportedSimpleCommands: Set<String> = [
        "activate", "deactivate", "deploy", "recall", "decommission",
        "clear_queue", "clear_directive", "assemble", "compact", "launch",
        "unfurl", "withdraw", "search", "set_entry_point", "detonate",
    ]

    /// Decode a dry-run travel response into a `TravelPlan`. The generated route
    /// legs are untyped (`additionalProperties`), so we round-trip the response
    /// through JSON — the re-encode preserves the raw leg keys — and decode the
    /// typed plan from that.
    private static func travelPlan(from response: CommandResponse) -> TravelPlan? {
        guard
            let data = try? jsonEncoder.encode(response),
            let plan = try? JSONDecoder().decode(TravelPlan.self, from: data)
        else { return nil }
        return plan
    }

    /// The deadline a self-describing command reports, trying the known
    /// completion-time fields of the shared response in priority order. For
    /// travel, `final_arrives_at` is the *whole route's* end while `arrives_at`
    /// is only the current/first leg — so it must come first, or a multi-leg
    /// trip's deadline lands at the first waypoint and the op completes a leg
    /// early.
    private static func parseDeadline(from response: CommandResponse) -> Date? {
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

    private static func errorMessage(_ body: Operations.PostV1DevicesDeviceCode.Output.BadRequest.Body) -> String {
        (try? body.json.error) ?? "The command was rejected."
    }
    private static func errorMessage(_ body: Operations.PostV1DevicesDeviceCode.Output.Forbidden.Body) -> String {
        (try? body.json.error) ?? "Not permitted."
    }
    private static func errorMessage(_ body: Operations.PostV1DevicesDeviceCode.Output.NotFound.Body) -> String {
        (try? body.json.error) ?? "Device not found."
    }

    private static let jsonEncoder: JSONEncoder = {
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
    /// Inert by default — does nothing and returns a fixed id. Tests that
    /// exercise dispatch use the live value over a stubbed `gameClient`.
    public static let testValue = CommandClient(
        dispatch: { _, _, _ in .accepted(operationID: "test-op") },
        previewTravel: { _, _ in .plan(TravelPlan()) }
    )
}

extension DependencyValues {
    public var commandClient: CommandClient {
        get { self[CommandClient.self] }
        set { self[CommandClient.self] = newValue }
    }
}
