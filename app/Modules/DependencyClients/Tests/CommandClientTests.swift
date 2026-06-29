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
            status: status, source: OperationSource.poll,
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
        #expect(stored?.status == OperationStatus.active)
        #expect(stored?.source == OperationSource.poll)
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
            let outcome = await CommandClient.liveValue.dispatch(.travel, "965AC2C3", CommandParams(destination: "X"))
            #expect(outcome == .rejected("Device is busy"))
        }

        let stored = try await op(database, device: "965AC2C3")
        #expect(stored?.status == OperationStatus.rejected)
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
        #expect(prior?.status == OperationStatus.superseded)

        let openCount = try await database.read { db in
            try Operation.where {
                $0.status.in(OperationStatus.liveCases)
            }.fetchCount(db)
        }
        #expect(openCount == 1)   // exactly one open op survives (the new travel)
    }

    /// Mining is continuous — its 200 carries no deadline, so the op confirms
    /// active with a nil `completesAt` (it runs until stopped, not toward an ETA).
    @Test func mineConfirmsActiveWithoutDeadline() async throws {
        let database = try makeDatabase()
        let body = #"{"status":"mining_started","resource_type":"volatiles","cycle_time_seconds":25}"#

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.gameClient = stubGameClient { _ in jsonResponse(200, body) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "mining") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(
                .mine, "32658E70", CommandParams(resourceType: "volatiles")
            )
            if case .accepted = outcome {} else { Issue.record("expected accepted, got \(outcome)") }
        }

        let stored = try await op(database, device: "32658E70")
        #expect(stored?.status == OperationStatus.active)
        #expect(stored?.completesAt == nil)
    }

    /// A missing required parameter fails before any optimistic row is staged.
    @Test func missingParameterFailsWithoutStagingOp() async throws {
        let database = try makeDatabase()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.gameClient = stubGameClient { _ in jsonResponse(200) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "idle") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.mine, "32658E70", CommandParams())
            if case .failed = outcome {} else { Issue.record("expected failed, got \(outcome)") }
        }

        #expect(try await op(database, device: "32658E70") == nil)   // no op staged
    }

    /// An immediate command (scan) creates no operation row but still takes the
    /// one authoritative post-command device read.
    @Test func immediateCommandCreatesNoOpButReads() async throws {
        let database = try makeDatabase()
        let readCount = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.gameClient = stubGameClient { _ in jsonResponse(200, #"{"star":{"designation":"ATIANFU"}}"#) }
            $0.devicesClient.read = { code in
                readCount.withValue { $0 += 1 }
                return makeDevice(code: code, status: "idle")
            }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.scan, "965AC2C3", CommandParams())
            #expect(outcome == .accepted(operationID: nil))
        }

        #expect(try await op(database, device: "965AC2C3") == nil)   // no tracked op
        #expect(readCount.value == 1)
    }

    /// A terminating immediate command (deactivate) closes the device's open
    /// operation, so a continuous mining row doesn't survive the in-place stop.
    @Test func terminatingCommandClosesOpenOp() async throws {
        let database = try makeDatabase()
        try await database.write { db in
            try Operation.insert { openOp("running", device: "32658E70", status: .active) }.execute(db)
        }

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
            $0.uuid = .incrementing
            $0.gameClient = stubGameClient { _ in jsonResponse(200, #"{"deactivated":"mining","status":"mining_stopped"}"#) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "idle") }
        } operation: {
            _ = await CommandClient.liveValue.dispatch(.simple("deactivate"), "32658E70", CommandParams())
        }

        let running = try await database.read { db in
            try Operation.where { $0.id.eq("running") }.fetchOne(db)
        }
        #expect(running?.status == OperationStatus.completed)
    }

    /// `recall` is self-describing — it cruises the device home to stow and
    /// returns `arrives_at`, so it confirms a tracked deadline op and supersedes
    /// any in-flight op (e.g. mining) rather than completing it in place.
    @Test func recallConfirmsDeadlineAndSupersedesPrior() async throws {
        let database = try makeDatabase()
        try await database.write { db in
            try Operation.insert { openOp("mining", device: "32658E70", status: .active) }.execute(db)
        }
        let body = #"{"status":"recalling","arrives_at":"2026-06-26T01:00:00Z","destination":"ATIANFU-1"}"#

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.gameClient = stubGameClient { _ in jsonResponse(200, body) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "recalling") }
        } operation: {
            _ = await CommandClient.liveValue.dispatch(.simple("recall"), "32658E70", CommandParams())
        }

        let mining = try await database.read { db in
            try Operation.where { $0.id.eq("mining") }.fetchOne(db)
        }
        #expect(mining?.status == OperationStatus.superseded)

        let recall = try await database.read { db in
            try Operation.where { $0.kind.eq("recall") }.fetchOne(db)
        }
        #expect(recall?.status == OperationStatus.active)
        #expect(recall?.completesAt == (try Date("2026-06-26T01:00:00Z", strategy: .iso8601)))
    }

    /// `retarget` is a mid-mining modifier — its valid `resource_type` builds the
    /// body and it dispatches as immediate (no new op; the mining op continues).
    @Test func retargetIsImmediateWithResource() async throws {
        let database = try makeDatabase()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.gameClient = stubGameClient { _ in jsonResponse(200, #"{"status":"mining_retargeted","new_resource":"conductive"}"#) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "mining") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(
                .retarget, "32658E70", CommandParams(resourceType: "conductive")
            )
            #expect(outcome == .accepted(operationID: nil))
        }

        #expect(try await op(database, device: "32658E70") == nil)   // no tracked op
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
