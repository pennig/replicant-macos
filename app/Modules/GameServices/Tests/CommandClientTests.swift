//
//  CommandClientTests.swift
//  Replicould — GameServices
//
//  The Operation lifecycle (IMPLEMENTATION_PLAN §4 / §8): drive `CommandClient`
//  over a canned transport and assert the optimistic row transitions correctly —
//  confirmed-active with a deadline for travel, rejected on a 4xx (leaving a
//  prior op untouched), and superseding a prior open op on success.
//

import API
import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameSession
import HTTPTypes
import OpenAPIRuntime
import SQLiteData
import Testing
import Utils
@testable import GameServices

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

@Suite struct CommandClientTests {

    // MARK: Fixtures

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

    /// `dedupKey` is stable across field-assignment order and omits unset fields.
    @Test func dedupKeyIsOrderIndependentAndOmitsNil() {
        var a = CommandParams(); a.destination = "SOL"; a.quantity = 2
        var b = CommandParams(); b.quantity = 2; b.destination = "SOL"
        #expect(a.dedupKey == b.dedupKey)
        var c = CommandParams(); c.destination = "SOL"
        #expect(a.dedupKey != c.dedupKey)
        #expect(!c.dedupKey.contains("quantity"), "an unset field must be absent, not null")
    }

    /// An immediate verb dispatched with an owner writes one terminal row
    /// carrying the owner's `directiveID`/`step`, not just a tracked one.
    @Test func immediateVerbWritesATerminalOwnedRow() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(200, #"{"status":"stowed"}"#) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "idle") }
        } operation: {
            let owner = CommandOwner(directiveID: "D1", step: "stowing", since: .distantPast)
            let outcome = await CommandClient.liveValue.dispatchOwned(
                .stow, "RELAY1", CommandParams(target: "CARRIER"), owner
            )
            #expect(outcome == .accepted(operationID: nil))
        }

        let rows = try await database.read { db in
            try Operation.where { $0.entityCode.eq("RELAY1") }.fetchAll(db)
        }
        #expect(rows.count == 1)
        #expect(rows[0].status == OperationStatus.completed)
        #expect(rows[0].directiveID == "D1" && rows[0].step == "stowing")
        #expect(rows[0].kind == OperationKind.stow.rawValue)
    }

    /// A rejected immediate dispatch still writes its terminal row — `.rejected`,
    /// carrying the server's message in `detail`.
    @Test func immediateRejectionWritesARejectedRow() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(400, #"{"error":"Device is busy"}"#) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "idle") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.scan, "965AC2C3", CommandParams())
            #expect(outcome == .rejected("Device is busy"))
        }

        let stored = try await op(database, device: "965AC2C3")
        #expect(stored?.status == OperationStatus.rejected)
        #expect(stored?.detail["message"]?.stringValue == "Device is busy")
    }

    /// A tracked dispatch's optimistic insert carries the owner through too.
    @Test func trackedDispatchCarriesOwner() async throws {
        let database = try GameDatabase.bootstrap()
        let owner = CommandOwner(directiveID: "D1", step: "travelling", since: .distantPast)
        let body = #"{"status":"travelling","arrives_at":"2026-06-26T01:00:00Z"}"#

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(200, body) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "travelling") }
        } operation: {
            _ = await CommandClient.liveValue.dispatchOwned(
                .travel, "965AC2C3", CommandParams(destination: "SOL"), owner
            )
        }

        let stored = try await op(database, device: "965AC2C3")
        #expect(stored?.directiveID == "D1")
        #expect(stored?.step == "travelling")
        #expect(stored?.paramsDigest == CommandParams(destination: "SOL").dedupKey)
    }

    /// A travel command whose 200 response carries `arrives_at` confirms the op
    /// active with a completion deadline, and takes the post-command device read.
    @Test func travelConfirmsActiveWithDeadline() async throws {
        let database = try GameDatabase.bootstrap()
        let readCount = LockIsolated(0)
        let body = #"{"status":"travelling","arrives_at":"2026-06-26T01:00:00Z","destination":"ATIANFU-1"}"#

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
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
        let database = try GameDatabase.bootstrap()
        let readCount = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
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
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { openOp("prior", device: "965AC2C3", status: .active) }.execute(db)
        }
        let body = #"{"status":"travelling","arrives_at":"2026-06-26T01:00:00Z"}"#

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
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

    /// A second print on a bench queues behind the first. Travel still
    /// supersedes, because a device travels to one place at a time.
    @Test func secondPrintDoesNotSupersedeTheFirst() async throws {
        let database = try GameDatabase.bootstrap()
        let body = #"{"status":"printing"}"#

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(200, body) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "printing") }
        } operation: {
            _ = await CommandClient.liveValue.dispatch(.print, "B1", CommandParams(deviceType: "mining_drone"))
            _ = await CommandClient.liveValue.dispatch(.print, "B1", CommandParams(deviceType: "ftl_relay"))
        }

        let live = try await database.read { db in
            try Operation.where { $0.entityCode.eq("B1") && $0.status.in(OperationStatus.liveCases) }
                .fetchAll(db)
        }

        #expect(live.count == 2)
        #expect(live.filter { $0.status == .active }.count <= 1)
    }

    /// Mining is continuous — its 200 carries no deadline, so the op confirms
    /// active with a nil `completesAt` (it runs until stopped, not toward an ETA).
    @Test func mineConfirmsActiveWithoutDeadline() async throws {
        let database = try GameDatabase.bootstrap()
        let body = #"{"status":"mining_started","resource_type":"volatiles","cycle_time_seconds":25}"#

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
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
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(200) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "idle") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.mine, "32658E70", CommandParams())
            if case .failed = outcome {} else { Issue.record("expected failed, got \(outcome)") }
        }

        #expect(try await op(database, device: "32658E70") == nil)   // no op staged
    }

    /// An immediate command (scan) writes a terminal completed row (no deadline,
    /// no `completesAt`) and still takes the one authoritative post-command
    /// device read.
    @Test func immediateCommandWritesACompletedRowAndReads() async throws {
        let database = try GameDatabase.bootstrap()
        let readCount = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(200, #"{"star":"ATIANFU"}"#) }
            $0.devicesClient.read = { code in
                readCount.withValue { $0 += 1 }
                return makeDevice(code: code, status: "idle")
            }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.scan, "965AC2C3", CommandParams())
            #expect(outcome == .accepted(operationID: nil))
        }

        let stored = try await op(database, device: "965AC2C3")
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.kind == OperationKind.scan.rawValue)
        #expect(readCount.value == 1)
    }

    /// A terminating immediate command (deactivate) closes the device's open
    /// operation, so a continuous mining row doesn't survive the in-place stop.
    @Test func terminatingCommandClosesOpenOp() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { openOp("running", device: "32658E70", status: .active) }.execute(db)
        }

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 2_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
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
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Operation.insert { openOp("mining", device: "32658E70", status: .active) }.execute(db)
        }
        let body = #"{"status":"recalling","arrives_at":"2026-06-26T01:00:00Z","destination":"ATIANFU-1"}"#

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
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
    /// body and it dispatches as immediate: no new TRACKED op (the mining op
    /// continues), but its own terminal row lands.
    @Test func retargetIsImmediateWithResource() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(200, #"{"status":"mining_retargeted","new_resource":"conductive"}"#) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "mining") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(
                .retarget, "32658E70", CommandParams(resourceType: "conductive")
            )
            #expect(outcome == .accepted(operationID: nil))
        }

        let stored = try await op(database, device: "32658E70")
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.kind == OperationKind.retarget.rawValue)
    }

    /// `set_directive` is a synchronous controller config change — it
    /// dispatches as immediate (a terminal row, no tracked op), and the
    /// post-command read refreshes the controller's `ami_directive`.
    @Test func setDirectiveIsImmediateWithDirective() async throws {
        let database = try GameDatabase.bootstrap()
        let readCount = LockIsolated(0)

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(200, #"{"status":"coordinating","ami_directive":{"name":"belt_search"}}"#) }
            $0.devicesClient.read = { code in
                readCount.withValue { $0 += 1 }
                return makeDevice(code: code, status: "coordinating")
            }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(
                .setDirective, "E45C43AB", CommandParams(directive: "belt_search")
            )
            #expect(outcome == .accepted(operationID: nil))
        }

        let stored = try await op(database, device: "E45C43AB")
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.kind == OperationKind.setDirective.rawValue)
        #expect(readCount.value == 1)
    }

    /// A survey-drone body `scan` is long-running (not the immediate heaven-vessel
    /// `system_scan`): its 200 carries `completes_at`, so it confirms a tracked
    /// deadline op, and it dispatches the bare `scan` verb.
    @Test func surveyScanConfirmsActiveWithDeadline() async throws {
        let database = try GameDatabase.bootstrap()
        let command = LockIsolated<String?>(nil)
        let client = GameClient(make: {
            Client(
                serverURL: URL(string: "https://stub.invalid")!,
                transport: CapturingTransport(
                    onBody: { data in
                        command.setValue((try? JSONDecoder().decode(JSONValue.self, from: data))?["command"]?.stringValue)
                    },
                    response: jsonResponse(200, #"{"status":"scan_started","completes_at":"2026-06-26T01:00:00Z","scan_target":"ATIANFU-1"}"#)
                )
            )
        })

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = client
            $0.devicesClient.read = { code in makeDevice(code: code, status: "scanning") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.surveyScan, "2586E328", CommandParams())
            if case .accepted = outcome {} else { Issue.record("expected accepted, got \(outcome)") }
        }

        #expect(command.value == "scan")   // the drone verb, not "system_scan"
        let stored = try await op(database, device: "2586E328")
        #expect(stored?.kind == OperationKind.surveyScan.rawValue)
        #expect(stored?.status == OperationStatus.active)
        #expect(stored?.completesAt == (try Date("2026-06-26T01:00:00Z", strategy: .iso8601)))
    }

    /// `set_directive` carries the directive's configuration object through to the
    /// request body — the loosely-typed `{planets, moons, recall}` survives the
    /// bridge into the generated schema's untyped configuration bag.
    @Test func setDirectiveTransmitsConfiguration() async throws {
        let database = try GameDatabase.bootstrap()
        let captured = LockIsolated<JSONValue?>(nil)
        let client = GameClient(make: {
            Client(
                serverURL: URL(string: "https://stub.invalid")!,
                transport: CapturingTransport(
                    onBody: { data in captured.setValue(try? JSONDecoder().decode(JSONValue.self, from: data)) },
                    response: jsonResponse(200, #"{"status":"coordinating"}"#)
                )
            )
        })

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = client
            $0.devicesClient.read = { code in makeDevice(code: code, status: "coordinating") }
        } operation: {
            _ = await CommandClient.liveValue.dispatch(
                .setDirective, "E45C43AB",
                CommandParams(directive: "survey_system", configuration: [
                    "planets": .string("all"), "moons": .string("none"), "recall": .bool(true),
                ])
            )
        }

        let body = captured.value
        #expect(body?["directive"]?.stringValue == "survey_system")
        #expect(body?["configuration"]?["planets"]?.stringValue == "all")
        #expect(body?["configuration"]?["moons"]?.stringValue == "none")
        #expect(body?["configuration"]?["recall"]?.boolValue == true)
    }

    /// `gather_salvage` requires a `location` in its configuration (the backend
    /// rejects it otherwise); the salvage-site designation and recall flag survive
    /// the bridge into the untyped configuration bag.
    @Test func gatherSalvageTransmitsLocation() async throws {
        let database = try GameDatabase.bootstrap()
        let captured = LockIsolated<JSONValue?>(nil)
        let client = GameClient(make: {
            Client(
                serverURL: URL(string: "https://stub.invalid")!,
                transport: CapturingTransport(
                    onBody: { data in captured.setValue(try? JSONDecoder().decode(JSONValue.self, from: data)) },
                    response: jsonResponse(200, #"{"status":"coordinating"}"#)
                )
            )
        })

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = client
            $0.devicesClient.read = { code in makeDevice(code: code, status: "coordinating") }
        } operation: {
            _ = await CommandClient.liveValue.dispatch(
                .setDirective, "18CA7C99",
                CommandParams(directive: "gather_salvage", configuration: [
                    "location": .string("SHERATANON-7-4-SAL-1"), "recall": .bool(true),
                ])
            )
        }

        let body = captured.value
        #expect(body?["directive"]?.stringValue == "gather_salvage")
        #expect(body?["configuration"]?["location"]?.stringValue == "SHERATANON-7-4-SAL-1")
        #expect(body?["configuration"]?["recall"]?.boolValue == true)
    }

    /// `adopt` is an immediate controller topology change (no tracked op): its
    /// `devices` array reaches the wire, and dispatch refreshes both the
    /// controller and each device the response reports it adopted (so the newly
    /// adopted device's controller linkage reflects now, not next poll).
    @Test func adoptSendsDevicesAndIsImmediate() async throws {
        let database = try GameDatabase.bootstrap()
        let readCodes = LockIsolated<[String]>([])
        let devices = LockIsolated<[String]?>(nil)
        let client = GameClient(make: {
            Client(
                serverURL: URL(string: "https://stub.invalid")!,
                transport: CapturingTransport(
                    onBody: { data in
                        let body = try? JSONDecoder().decode(JSONValue.self, from: data)
                        devices.setValue(body?["devices"]?.arrayValue?.compactMap(\.stringValue))
                    },
                    response: jsonResponse(200, #"{"status":"adopted","controller_code":"18CA7C99","adopted":[{"device_code":"32658E70"}]}"#)
                )
            )
        })

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = client
            $0.devicesClient.read = { code in
                readCodes.withValue { $0.append(code) }
                return makeDevice(code: code, status: "coordinating")
            }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(
                .adopt, "18CA7C99", CommandParams(devices: ["32658E70", "7C79FCE1"])
            )
            #expect(outcome == .accepted(operationID: nil))
        }

        #expect(devices.value == ["32658E70", "7C79FCE1"])
        let stored = try await op(database, device: "18CA7C99")
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.kind == OperationKind.adopt.rawValue)
        // The authoritative controller read, then a read of each device the
        // response's `adopted` block named (here just 32658E70).
        #expect(readCodes.value == ["18CA7C99", "32658E70"])
    }

    /// `release` mirrors adopt — an immediate topology change whose `devices` array
    /// reaches the wire (the `release` verb, not `adopt`).
    @Test func releaseSendsDevicesAndIsImmediate() async throws {
        let database = try GameDatabase.bootstrap()
        let command = LockIsolated<String?>(nil)
        let devices = LockIsolated<[String]?>(nil)
        let client = GameClient(make: {
            Client(
                serverURL: URL(string: "https://stub.invalid")!,
                transport: CapturingTransport(
                    onBody: { data in
                        let body = try? JSONDecoder().decode(JSONValue.self, from: data)
                        command.setValue(body?["command"]?.stringValue)
                        devices.setValue(body?["devices"]?.arrayValue?.compactMap(\.stringValue))
                    },
                    response: jsonResponse(200, #"{"status":"released","controller_code":"E45C43AB","released":[{"device_code":"CAA6D3EE"}]}"#)
                )
            )
        })

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = client
            $0.devicesClient.read = { code in makeDevice(code: code, status: "coordinating") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(
                .release, "E45C43AB", CommandParams(devices: ["CAA6D3EE"])
            )
            #expect(outcome == .accepted(operationID: nil))
        }

        #expect(command.value == "release")
        #expect(devices.value == ["CAA6D3EE"])
        let stored = try await op(database, device: "E45C43AB")
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.kind == OperationKind.release.rawValue)
    }

    /// `adopt` with no devices fails before any request is sent.
    @Test func adoptWithNoDevicesFails() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(200) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "coordinating") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.adopt, "18CA7C99", CommandParams())
            if case .failed = outcome {} else { Issue.record("expected failed, got \(outcome)") }
        }
    }

    /// `dequeue_print` removes one queued job by index — an immediate command (no
    /// tracked op) whose `command` verb and `index` reach the wire.
    @Test func dequeuePrintSendsIndexAndIsImmediate() async throws {
        let database = try GameDatabase.bootstrap()
        let command = LockIsolated<String?>(nil)
        let index = LockIsolated<Double?>(nil)
        let client = GameClient(make: {
            Client(
                serverURL: URL(string: "https://stub.invalid")!,
                transport: CapturingTransport(
                    onBody: { data in
                        let body = try? JSONDecoder().decode(JSONValue.self, from: data)
                        command.setValue(body?["command"]?.stringValue)
                        index.setValue(body?["index"]?.numberValue)
                    },
                    response: jsonResponse(200, #"{"status":"dequeued","queue_length":1}"#)
                )
            )
        })

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = client
            $0.devicesClient.read = { code in makeDevice(code: code, status: "printing (autofactory)") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(
                .dequeuePrint, "965AC2C3", CommandParams(index: 2)
            )
            #expect(outcome == .accepted(operationID: nil))
        }

        #expect(command.value == "dequeue_print")
        #expect(index.value == 2)
        let stored = try await op(database, device: "965AC2C3")
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.kind == OperationKind.dequeuePrint.rawValue)
    }

    /// `dequeue_print` with no index fails before any request is sent.
    @Test func dequeuePrintMissingIndexFails() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(200) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "printing") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.dequeuePrint, "965AC2C3", CommandParams())
            if case .failed = outcome {} else { Issue.record("expected failed, got \(outcome)") }
        }
    }

    /// `set_directive` with no directive fails before any request is sent.
    @Test func setDirectiveMissingDirectiveFails() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(200) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "coordinating") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.setDirective, "E45C43AB", CommandParams())
            if case .failed = outcome {} else { Issue.record("expected failed, got \(outcome)") }
        }
    }

    /// `collect_resources` loads the hold from the local stockpile — an immediate
    /// command (no tracked op) whose `command` verb and per-type `resources` map
    /// reach the wire, and whose post-command read refreshes the transport's cargo.
    @Test func collectResourcesSendsResourcesAndIsImmediate() async throws {
        let database = try GameDatabase.bootstrap()
        let readCount = LockIsolated(0)
        let captured = LockIsolated<JSONValue?>(nil)
        let client = GameClient(make: {
            Client(
                serverURL: URL(string: "https://stub.invalid")!,
                transport: CapturingTransport(
                    onBody: { data in captured.setValue(try? JSONDecoder().decode(JSONValue.self, from: data)) },
                    response: jsonResponse(200, #"{"status":"idle","cargo_used":50}"#)
                )
            )
        })

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = client
            $0.devicesClient.read = { code in
                readCount.withValue { $0 += 1 }
                return makeDevice(code: code, status: "idle")
            }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(
                .collectResources, "51910407", CommandParams(resources: ["structural": 30, "carbon": 20])
            )
            #expect(outcome == .accepted(operationID: nil))
        }

        let body = captured.value
        #expect(body?["command"]?.stringValue == "collect_resources")
        #expect(body?["resources"]?["structural"]?.numberValue == 30)
        #expect(body?["resources"]?["carbon"]?.numberValue == 20)
        let stored = try await op(database, device: "51910407")
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.kind == OperationKind.collectResources.rawValue)
        #expect(readCount.value == 1)                                // one authoritative read
    }

    /// `collect_resources` with an empty map fails before any request is sent (the
    /// server needs at least one resource/amount to move).
    @Test func collectResourcesEmptyFails() async throws {
        let database = try GameDatabase.bootstrap()

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in jsonResponse(200) }
            $0.devicesClient.read = { code in makeDevice(code: code, status: "idle") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.collectResources, "51910407", CommandParams())
            if case .failed = outcome {} else { Issue.record("expected failed, got \(outcome)") }
        }
    }

    /// `deposit_resources` with no `resources` empties the entire hold — the body
    /// carries only the verb (no `resources` key), and it dispatches as immediate.
    @Test func depositResourcesEmptyOmitsResourcesAndIsImmediate() async throws {
        let database = try GameDatabase.bootstrap()
        let captured = LockIsolated<JSONValue?>(nil)
        let client = GameClient(make: {
            Client(
                serverURL: URL(string: "https://stub.invalid")!,
                transport: CapturingTransport(
                    onBody: { data in captured.setValue(try? JSONDecoder().decode(JSONValue.self, from: data)) },
                    response: jsonResponse(200, #"{"status":"idle","cargo_used":0}"#)
                )
            )
        })

        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = client
            $0.devicesClient.read = { code in makeDevice(code: code, status: "idle") }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.depositResources, "51910407", CommandParams())
            #expect(outcome == .accepted(operationID: nil))
        }

        let body = captured.value
        #expect(body?["command"]?.stringValue == "deposit_resources")
        #expect(body?["resources"] == nil)   // omitted → empty the whole hold
        let stored = try await op(database, device: "51910407")
        #expect(stored?.status == OperationStatus.completed)
        #expect(stored?.kind == OperationKind.depositResources.rawValue)
    }

    /// Regression for the `DeviceCommandResponseSchema` `additionalProperties:false`
    /// drift: the device-command 200 body carries confirmation/travel fields the
    /// hand-maintained spec had omitted — `activated`/`deactivated` on the
    /// lifecycle toggles, `relay_active`/`origin_name`/`travel_type` on travel — so
    /// the generated client (which eagerly decodes the body when building `.ok`)
    /// used to *throw* on the unknown key, failing dispatch. Each must now decode
    /// as its typed property. Same generated `Codable` path the client uses, so a
    /// direct decode is the tightest guard.
    @Test func commandResponseDecodesDriftFields() throws {
        let body = Data(#"""
        {
          "status": "travelling",
          "activated": "mining",
          "deactivated": "mining",
          "relay_active": true,
          "origin": "ATIANFU-1",
          "origin_name": "Atianfu I",
          "travel_type": "cruise"
        }
        """#.utf8)

        let response = try JSONDecoder().decode(
            Components.Schemas.AppSchemasDevicesDeviceCommandResponseSchema.self, from: body
        )

        #expect(response.activated == "mining")
        #expect(response.deactivated == "mining")
        #expect(response.relayActive == true)
        #expect(response.originName == "Atianfu I")
        #expect(response.travelType == "cruise")
    }

    /// The four Stage 4 utility verbs serialize the documented wire bodies.
    @Test func utilityVerbBodiesSerializeAsDocumented() async throws {
        let cases: [(OperationKind, CommandParams, [String: JSONValue])] = [
            (.configure, CommandParams(mode: "taxi"),
             ["command": .string("configure"), "mode": .string("taxi")]),
            (.message, CommandParams(channel: "#general", text: "hello"),
             ["command": .string("message"), "channel": .string("#general"), "text": .string("hello")]),
            (.changeOwner, CommandParams(target: "REP2"),
             ["command": .string("change_owner"), "target": .string("REP2")]),
        ]
        for (kind, params, expected) in cases {
            let database = try GameDatabase.bootstrap()
            let captured = LockIsolated<Data?>(nil)
            await withDependencies {
                $0.defaultDatabase = database
                $0.date = .constant(Date(timeIntervalSince1970: 1_000))
                $0.uuid = .incrementing
                $0.deviceRefresher = coordinatorBackedRefresher()
                $0.gameClient = capturingGameClient(
                    onBody: { captured.setValue($0) },
                    response: jsonResponse(200, #"{"status":"ok"}"#)
                )
                $0.devicesClient.read = { code in makeDevice(code: code, status: "idle") }
            } operation: {
                let outcome = await CommandClient.liveValue.dispatch(kind, "DEV1", params)
                #expect(outcome == .accepted(operationID: nil), "\(kind.rawValue)")
            }
            let body = try #require(captured.value, "\(kind.rawValue) sent no body")
            let json = try JSONDecoder().decode(JSONValue.self, from: body)
            #expect(json == .object(expected), "\(kind.rawValue)")
        }
    }

    /// `repair` sends `target` (not `device`) and is deadline-tracked: it
    /// confirms an active op, back-filling `completesAt` from the post-command
    /// read's `repair` block when the response withholds a deadline.
    @Test func repairTracksDeadlineAndSendsTarget() async throws {
        let database = try GameDatabase.bootstrap()
        let captured = LockIsolated<Data?>(nil)
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = capturingGameClient(
                onBody: { captured.setValue($0) },
                response: jsonResponse(200, #"{"status":"repairing"}"#)
            )
            $0.devicesClient.read = { code in
                var device = makeDevice(code: code, status: "repairing")
                device.detail = .object([
                    "repair": .object(["completes_at": .string("2026-07-23T12:00:00Z")]),
                ])
                return device
            }
        } operation: {
            let outcome = await CommandClient.liveValue.dispatch(.repair, "BOT1", CommandParams(target: "7C79FCE1"))
            if case .accepted(let opID) = outcome { #expect(opID != nil) } else {
                Issue.record("expected accepted, got \(outcome)")
            }
        }
        let body = try #require(captured.value)
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        #expect(json == .object(["command": .string("repair"), "target": .string("7C79FCE1")]))

        let stored = try await database.read { db in
            try GameModels.Operation.where { $0.entityCode.eq("BOT1") }.fetchOne(db)
        }
        #expect(stored?.status == OperationStatus.active)
        #expect(stored?.kind == "repair")
        #expect(stored?.completesAt == (try Date("2026-07-23T12:00:00Z", strategy: .iso8601)))
    }

    /// A missing required parameter fails fast, before any request or op row.
    @Test func utilityVerbsFailFastOnMissingParams() async throws {
        let database = try GameDatabase.bootstrap()
        await withDependencies {
            $0.defaultDatabase = database
            $0.date = .constant(Date(timeIntervalSince1970: 1_000))
            $0.uuid = .incrementing
            $0.deviceRefresher = coordinatorBackedRefresher()
            $0.gameClient = stubGameClient { _ in
                Issue.record("no request should be sent")
                return jsonResponse(200, "{}")
            }
        } operation: {
            for (kind, params) in [
                (OperationKind.configure, CommandParams()),
                (.configure, CommandParams(mode: "warp")),   // invalid value
                (.message, CommandParams(channel: "#general")),  // missing text
                (.repair, CommandParams()),
                (.changeOwner, CommandParams()),
            ] {
                let outcome = await CommandClient.liveValue.dispatch(kind, "DEV1", params)
                if case .failed = outcome {} else { Issue.record("\(kind.rawValue): expected .failed, got \(outcome)") }
            }
        }
    }
}

// MARK: - Helpers

/// A refresher backed by a real (per-test) `PollCoordinator`, so post-command
/// confirm-reads exercise the same coalesce → read → reconcile path as
/// production while the underlying network read stays the test's
/// `devicesClient.read` stub (the coordinator resolves it at call time).
private func coordinatorBackedRefresher() -> DeviceRefreshClient {
    let coordinator = PollCoordinator(reconciler: Reconciler())
    return DeviceRefreshClient { code, priority in
        await coordinator.refresh(code, priority: priority)
    }
}

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

/// Vends a `GameClient` whose generated `Client` is backed by a
/// `CapturingTransport` — captures the request body via `onBody` before
/// answering with `response`.
private func capturingGameClient(
    onBody: @escaping @Sendable (Data) async -> Void,
    response: (HTTPResponse, HTTPBody?)
) -> GameClient {
    GameClient(make: {
        Client(
            serverURL: URL(string: "https://stub.invalid")!,
            transport: CapturingTransport(onBody: onBody, response: response)
        )
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

/// A transport that hands the collected request body to `onBody` before returning
/// a fixed response — lets a test assert what was actually sent on the wire.
private struct CapturingTransport: ClientTransport {
    let onBody: @Sendable (Data) async -> Void
    let response: (HTTPResponse, HTTPBody?)
    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if let body {
            let data = try await Data(collecting: body, upTo: 1_000_000)
            await onBody(data)
        }
        return response
    }
}

private func jsonResponse(_ status: Int, _ body: String = "{}") -> (HTTPResponse, HTTPBody?) {
    (
        HTTPResponse(status: .init(code: status), headerFields: [.contentType: "application/json"]),
        HTTPBody(Array(body.utf8))
    )
}
