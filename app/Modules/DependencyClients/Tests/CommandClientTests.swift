//
//  CommandClientTests.swift
//  Replicould — DependencyClients
//
//  The Operation lifecycle (IMPLEMENTATION_PLAN §4 / §8): drive `CommandClient`
//  over a canned transport and assert the optimistic row transitions correctly —
//  confirmed-active with a deadline for travel, rejected on a 4xx (leaving a
//  prior op untouched), and superseding a prior open op on success.
//

import API
import ComposableArchitecture
import Foundation
import HTTPTypes
import OpenAPIRuntime
import SQLiteData
import Testing
@testable import DependencyClients

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = DependencyClients.Operation

@Suite struct CommandClientTests {

    // MARK: Fixtures

    private func makeDatabase() throws -> any DatabaseWriter {
        let database = try SQLiteData.defaultDatabase()
        var migrator = DatabaseMigrator()
        Device.registerMigrations(&migrator)
        Operation.registerMigrations(&migrator)
        try migrator.migrate(database)
        return database
    }

    private func openOp(_ id: String, device: String, status: OperationStatus) -> Operation {
        Operation(
            id: id, entityCode: device, kind: OperationKind.travel.rawValue,
            status: status.rawValue, source: OperationSource.poll.rawValue,
            startedAt: Date(timeIntervalSince1970: 0), completesAt: nil,
            lastConfirmedAt: Date(timeIntervalSince1970: 0), detail: .object([:])
        )
    }

    private func op(_ database: any DatabaseWriter, device: String) async throws -> Operation? {
        try await database.read { db in
            try Operation.where { $0.entityCode.eq(device) }.fetchOne(db)
        }
    }

    // MARK: Tests

    /// A travel command whose 200 response carries `arrives_at` confirms the op
    /// active with a completion deadline, and takes the post-command device read.
    @Test func travelConfirmsActiveWithDeadline() async throws {
        let database = try makeDatabase()
        let readCount = LockIsolated(0)
        let body = #"{"status":"travelling","arrives_at":"2026-06-26T01:00:00Z","destination":"ATIANFU-1"}"#

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.gameClient = stubGameClient { _ in jsonResponse(200, body) }
            $0.devicesClient.read = { code in
                readCount.withValue { $0 += 1 }
                return makeDevice(code: code, status: "travelling")
            }
        } operation: {
            _ = await CommandClient.liveValue.dispatch(.travel, "965AC2C3", CommandParams(destination: "ATIANFU-1"))
        }

        let stored = try await op(database, device: "965AC2C3")
        #expect(stored?.status == OperationStatus.active.rawValue)
        #expect(stored?.source == OperationSource.poll.rawValue)
        #expect(stored?.completesAt == (try Date("2026-06-26T01:00:00Z", strategy: .iso8601)))
        #expect(readCount.value == 1)   // one authoritative post-command read
    }

    /// A 400 (busy device) rejects the optimistic op and never touches the
    /// device read.
    @Test func rejectionMarksRejectedAndSkipsRead() async throws {
        let database = try makeDatabase()
        let readCount = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.gameClient = stubGameClient { _ in jsonResponse(400, #"{"error":"Device is busy"}"#) }
            $0.devicesClient.read = { code in
                readCount.withValue { $0 += 1 }
                return makeDevice(code: code, status: "idle")
            }
        } operation: {
            _ = await CommandClient.liveValue.dispatch(.travel, "965AC2C3", CommandParams(destination: "X"))
        }

        let stored = try await op(database, device: "965AC2C3")
        #expect(stored?.status == OperationStatus.rejected.rawValue)
        #expect(readCount.value == 0)
    }

    /// A successful dispatch supersedes a prior open op on the same device.
    @Test func successSupersedesPriorOpenOp() async throws {
        let database = try makeDatabase()
        try await database.write { db in
            try Operation.insert { openOp("prior", device: "965AC2C3", status: .active) }.execute(db)
        }
        let body = #"{"status":"travelling","arrives_at":"2026-06-26T01:00:00Z"}"#

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.gameClient = stubGameClient { _ in jsonResponse(200, body) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "travelling") }
        } operation: {
            _ = await CommandClient.liveValue.dispatch(.travel, "965AC2C3", CommandParams(destination: "X"))
        }

        let prior = try await database.read { db in
            try Operation.where { $0.id.eq("prior") }.fetchOne(db)
        }
        #expect(prior?.status == OperationStatus.superseded.rawValue)

        let openCount = try await database.read { db in
            try Operation.where {
                $0.status.eq(OperationStatus.active.rawValue) || $0.status.eq(OperationStatus.enqueued.rawValue)
            }.fetchCount(db)
        }
        #expect(openCount == 1)   // exactly one open op survives (the new travel)
    }
}

// MARK: - Helpers

private func makeDevice(code: String, status: String) -> Device {
    Device(
        deviceCode: code, deviceType: "heaven_vessel", replicantCode: "R1", status: status,
        location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
        detail: .object([:]), updatedAt: Date(timeIntervalSince1970: 1_000),
        firstSeenAt: Date(timeIntervalSince1970: 1_000)
    )
}

/// Vends a `GameClient` whose generated `Client` is backed by a canned transport.
private func stubGameClient(
    _ respond: @escaping @Sendable (HTTPRequest) -> (HTTPResponse, HTTPBody?)
) -> GameClient {
    GameClient(make: {
        Client(serverURL: URL(string: "https://stub.invalid")!, transport: StubTransport(respond: respond))
    })
}

private struct StubTransport: ClientTransport {
    let respond: @Sendable (HTTPRequest) -> (HTTPResponse, HTTPBody?)
    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        respond(request)
    }
}

private func jsonResponse(_ status: Int, _ body: String = "{}") -> (HTTPResponse, HTTPBody?) {
    (
        HTTPResponse(status: .init(code: status), headerFields: [.contentType: "application/json"]),
        HTTPBody(Array(body.utf8))
    )
}
