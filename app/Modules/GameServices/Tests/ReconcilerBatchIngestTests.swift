//
//  ReconcilerBatchIngestTests.swift
//  Replicould — GameServices
//
//  The cold-load walk reconciles the whole fleet at once. One transaction for
//  the walk rather than one per device is what keeps every `devices` observer
//  from re-fetching once per device on the writer connection.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
import Utils

@testable import GameServices

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

@Suite struct ReconcilerBatchIngestTests {

    private func device(
        _ code: String,
        status: String = "idle",
        detail: JSONValue = .object([:]),
        updatedAt: TimeInterval = 1_000
    ) -> Device {
        Device(
            deviceCode: code, deviceType: "heaven_vessel", replicantCode: "R1",
            status: status, location: "SOL-3", locationName: nil,
            operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
            controllerDeviceCode: nil, attachedToDeviceCode: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: [], features: [], tags: [], detail: detail,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            firstSeenAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    /// A fleet spanning the paths `ingest` distinguishes: a plain row, a device
    /// mid-activity (adopts an op), and a settled one.
    private func fleet() -> [Device] {
        [
            device("PLAIN1"),
            device(
                "PRINTER1",
                status: "printing (ami_survey_controller)",
                detail: .object([
                    "printing": .object([
                        "started_at": .string("2026-06-28T23:52:27-05:00"),
                        "completes_at": .string("2026-06-29T00:17:27-05:00"),
                        "device_type": .string("ami_survey_controller"),
                    ])
                ])
            ),
            device("PLAIN2"),
            device(
                "TRAVELLER1",
                status: "travelling",
                detail: .object([
                    "travel": .object([
                        "started_at": .string("2026-06-28T23:52:27-05:00"),
                        "final_arrives_at": .string("2026-06-29T00:17:27-05:00"),
                    ])
                ])
            ),
            device("PLAIN3"),
        ]
    }

    private func snapshot(_ database: any DatabaseReader) async throws -> (
        devices: [Device], ops: [String]
    ) {
        try await database.read { db in
            let devices = try Device.order { $0.deviceCode }.fetchAll(db)
            let ops = try Operation.order { $0.entityCode }.fetchAll(db)
                .map { "\($0.entityCode)/\($0.kind)/\($0.status.rawValue)" }
            return (devices, ops)
        }
    }

    /// The batch must be a pure performance change: same rows, same operations.
    @Test func theBatchProducesTheSameRowsAsIngestingOneAtATime() async throws {
        let sequential = try GameDatabase.bootstrap()
        let batched = try GameDatabase.bootstrap()
        let fleet = fleet()

        try await withDependencies {
            $0.defaultDatabase = sequential
            $0.uuid = .incrementing
        } operation: {
            let reconciler = Reconciler()
            for device in fleet { await reconciler.ingest(device) }
        }

        try await withDependencies {
            $0.defaultDatabase = batched
            $0.uuid = .incrementing
        } operation: {
            await Reconciler().ingest(fleet)
        }

        let a = try await snapshot(sequential)
        let b = try await snapshot(batched)
        #expect(a.devices == b.devices)
        #expect(a.ops == b.ops)
        #expect(!a.ops.isEmpty)   // the fixture must actually exercise the op paths
    }

    /// The point of the batch: observers re-fetch once for the walk, not once
    /// per device. GRDB runs a non-constant-region observation's fetch on the
    /// writer connection, so this is what the cold-load hitch was made of.
    @Test func theBatchCostsOneObserverPassNotOnePerDevice() async throws {
        func reads(ingesting fleet: [Device], batched useBatch: Bool) async throws -> Int {
            let counter = LockIsolated(0)
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                db.trace { event in
                    // The observation's whole-table fetch, not `apply`'s own
                    // per-device lookup (which is keyed and carries a WHERE).
                    let sql = "\(event)"
                    guard sql.contains("SELECT"), sql.contains("\"devices\""),
                        !sql.contains("WHERE")
                    else { return }
                    counter.withValue { $0 += 1 }
                }
            }
            let pool = try DatabasePool(
                path: NSTemporaryDirectory() + UUID().uuidString + ".db",
                configuration: configuration
            )
            try GameDatabase.migrator().migrate(pool)

            return try await withDependencies {
                $0.defaultDatabase = pool
                $0.uuid = .incrementing
            } operation: {
                @FetchAll(Device.all) var observed: [Device]
                _ = observed.count
                try await Task.sleep(for: .milliseconds(200))

                counter.setValue(0)
                let reconciler = Reconciler()
                if useBatch {
                    await reconciler.ingest(fleet)
                } else {
                    for device in fleet { await reconciler.ingest(device) }
                }
                _ = observed.count
                return counter.value
            }
        }

        let fleet = (0..<20).map { device("BULK\($0)") }
        let sequentialReads = try await reads(ingesting: fleet, batched: false)
        let batchedReads = try await reads(ingesting: fleet, batched: true)

        // Sequential pays a per-device pass; the batch pays one for the walk.
        #expect(sequentialReads >= fleet.count)
        #expect(batchedReads <= 2)
    }

    /// The staleness marks a walk satisfies must survive the batching, or the
    /// drain loop re-reads every device the walk just refreshed.
    @Test func theBatchStillSatisfiesEveryDevicesStalenessMark() async throws {
        let database = try GameDatabase.bootstrap()
        let satisfied = LockIsolated<[String]>([])
        var staleness = DeviceStalenessClient.testValue
        staleness.markSatisfied = { code, _ in satisfied.withValue { $0.append(code) } }
        let fleet = fleet()

        await withDependencies {
            $0.defaultDatabase = database
            $0.uuid = .incrementing
            $0.deviceStaleness = staleness
        } operation: {
            await Reconciler().ingest(fleet)
        }

        #expect(satisfied.value.sorted() == fleet.map(\.deviceCode).sorted())
    }
}
