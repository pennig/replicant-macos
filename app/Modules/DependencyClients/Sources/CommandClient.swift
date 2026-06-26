//
//  CommandClient.swift
//  Replicould — shared dependency clients
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
import SQLiteData
import Utils

/// Command-specific parameters. Only the fields a given command needs are set.
public struct CommandParams: Sendable, Equatable {
    public var destination: String?   // travel
    public var deviceType: String?    // print (enqueue_print)

    public init(destination: String? = nil, deviceType: String? = nil) {
        self.destination = destination
        self.deviceType = deviceType
    }

    var json: JSONValue {
        var dict: [String: JSONValue] = [:]
        if let destination { dict["destination"] = .string(destination) }
        if let deviceType { dict["device_type"] = .string(deviceType) }
        return .object(dict)
    }
}

public struct CommandClient: Sendable {
    /// Fire a command at a device. Returns the client-local operation id so a
    /// caller can correlate, though the UI normally just observes the tables.
    /// Never throws — failures land as the operation's `rejected`/`failed` state.
    public var dispatch: @Sendable (_ kind: OperationKind, _ deviceCode: String, _ params: CommandParams) async -> String
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

            let opID = uuid().uuidString
            let started = date.now

            // 1) Optimistic insert — instant UI. `optimistic` is excluded from
            //    the open-uniqueness index, so this never conflicts with a prior
            //    op that this command might replace.
            let optimistic = Operation(
                id: opID, entityCode: deviceCode, kind: kind.rawValue,
                status: OperationStatus.optimistic.rawValue,
                source: OperationSource.optimistic.rawValue,
                startedAt: started, completesAt: nil, lastConfirmedAt: started,
                detail: .object(["params": params.json])
            )
            try? await database.write { db in try Operation.insert { optimistic }.execute(db) }

            // 2) POST the command.
            do {
                let body = try makeBody(kind: kind, params: params)
                let output = try await gameClient().postV1DevicesDeviceCode(
                    path: .init(deviceCode: deviceCode), body: body
                )

                switch output {
                case let .ok(ok):
                    let response = try ok.body.json
                    // 3) Confirm: travel-style responses carry `arrives_at` (a
                    //    deadline → active); enqueued ones don't (→ enqueued,
                    //    completion comes later from a relay event).
                    let completesAt = response.arrivesAt.flatMap(parseTimestamp)
                    let confirmed: OperationStatus = completesAt == nil ? .enqueued : .active
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
                                    && ($0.status.eq(OperationStatus.enqueued.rawValue)
                                        || $0.status.eq(OperationStatus.active.rawValue))
                            }
                            .fetchAll(db)
                        for var other in openOps where other.id != opID {
                            other.status = OperationStatus.superseded.rawValue
                            other.lastConfirmedAt = confirmedAt
                            try Operation.upsert { other }.execute(db)
                        }

                        if var op = try Operation.where({ $0.id.eq(opID) }).fetchOne(db) {
                            op.status = confirmed.rawValue
                            op.source = OperationSource.poll.rawValue
                            op.completesAt = completesAt
                            op.lastConfirmedAt = confirmedAt
                            op.detail = .object(["params": params.json, "result": resultJSON])
                            try Operation.upsert { op }.execute(db)
                        }
                    }

                    // 4) One authoritative post-command device read (§1 settled
                    //    decision): the command response is a result, not a full
                    //    device snapshot, so this refreshes status/location/detail.
                    if let device = try? await devicesClient.read(deviceCode) {
                        await Reconciler().ingest(device)
                    }

                case let .badRequest(response):
                    await finish(opID, as: .rejected, reason: errorMessage(response.body), at: date.now, database: database)
                case let .forbidden(response):
                    await finish(opID, as: .rejected, reason: errorMessage(response.body), at: date.now, database: database)
                case let .notFound(response):
                    await finish(opID, as: .rejected, reason: errorMessage(response.body), at: date.now, database: database)
                @unknown default:
                    await finish(opID, as: .failed, reason: "Unexpected server response.", at: date.now, database: database)
                }
            } catch {
                // Network / encoding error — not a server rejection. No retry.
                await finish(opID, as: .failed, reason: error.localizedDescription, at: date.now, database: database)
            }

            return opID
        }
    )

    // MARK: Helpers

    /// Map a kind + params onto the generated `oneOf` command body. Phase 3
    /// implements travel and print; other kinds aren't dispatchable yet.
    private static func makeBody(
        kind: OperationKind,
        params: CommandParams
    ) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        switch kind {
        case .travel:
            guard let destination = params.destination else { throw CommandError.missingParameter("destination") }
            return .json(.travel(.init(command: "travel", destination: destination)))
        case .print:
            guard let deviceType = params.deviceType else { throw CommandError.missingParameter("device_type") }
            return .json(.enqueuePrint(.init(command: "enqueue_print", deviceType: deviceType)))
        case .mine, .scan, .census:
            throw CommandError.unsupported(kind)
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
            op.status = status.rawValue
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
    case unsupported(OperationKind)
}

// MARK: - Test / preview implementation

extension CommandClient: TestDependencyKey {
    /// Inert by default — does nothing and returns a fixed id. Tests that
    /// exercise dispatch use the live value over a stubbed `gameClient`.
    public static let testValue = CommandClient(dispatch: { _, _, _ in "test-op" })
}

extension DependencyValues {
    public var commandClient: CommandClient {
        get { self[CommandClient.self] }
        set { self[CommandClient.self] = newValue }
    }
}
