//
//  SchemaMappingTests.swift
//  Replicould — GameModels
//
//  The tolerant wire→model mappings (V3.10 item 15): every `init(schema:)` is
//  the app's malformed-payload firewall — a device with a missing field must
//  land as a usable row, never a crash or a dropped page. Fixtures decode the
//  GENERATED schema types from JSON (the real wire path, same as
//  UniverseModelsTests' location decode tests) and assert the mapped rows.
//

import API
import Foundation
import Testing
import Utils
@testable import GameModels

@Suite struct SchemaMappingTests {

    /// Decode a generated schema type from a raw JSON fixture — the same path a
    /// live response takes after transport.
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Device

    @Test func deviceSnapshotMapsCoreColumnsAndKeepsTheDetailTail() throws {
        let schema = try decode(
            Components.Schemas.AppSchemasDevicesDeviceStatusSchema.self,
            #"""
            {
              "device_code": "965AC2C3",
              "device_type": "mining_drone",
              "replicant_code": "R1",
              "status": "mining (iron)",
              "location": "ATIANFU-BELT-1",
              "location_name": "Inner Belt",
              "operational_capacity": 87.5,
              "queue_size": 2,
              "created_at": "2026-07-01T12:00:00Z",
              "available_commands": ["deactivate", "retarget"],
              "features": ["mining"],
              "tags": ["alpha"],
              "in_control_range": false,
              "mining": {
                "belt": "ATIANFU-BELT-1",
                "resource_type": "iron",
                "started_at": "2026-07-01T11:00:00Z",
                "pending_cycles": 3,
                "quantity_mined": 120
              }
            }
            """#
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let device = Device(schema: schema, fetchedAt: fetchedAt)

        #expect(device.deviceCode == "965AC2C3")
        #expect(device.deviceType == "mining_drone")
        #expect(device.status == "mining (iron)")
        #expect(device.location == "ATIANFU-BELT-1")
        #expect(device.locationName == "Inner Belt")
        #expect(device.operationalCapacity == 87.5)
        #expect(device.queueSize == 2)
        #expect(device.availableCommands == ["deactivate", "retarget"])
        #expect(device.createdAt == (try Date("2026-07-01T12:00:00Z", strategy: .iso8601)))
        #expect(device.updatedAt == fetchedAt)
        #expect(device.firstSeenAt == fetchedAt)

        // The variable tail survives in `detail`, core columns are stripped.
        #expect(device.detail["mining"]?["resource_type"]?.stringValue == "iron")
        #expect(device.detail["device_code"] == nil)
        #expect(device.detail["status"] == nil)
        // Typed accessors read the tail.
        #expect(device.isOutOfControlRange == true)
    }

    @Test func emptyDevicePayloadCoalescesToAUsableRow() throws {
        let schema = try decode(Components.Schemas.AppSchemasDevicesDeviceStatusSchema.self, "{}")
        let device = Device(schema: schema, fetchedAt: Date(timeIntervalSince1970: 1_000))

        #expect(device.deviceCode == "")
        #expect(device.deviceType == "")
        #expect(device.status == "")
        #expect(device.operationalCapacity == 0)
        #expect(device.queueSize == 0)
        #expect(device.createdAt == Date(timeIntervalSince1970: 0))
        #expect(device.availableCommands.isEmpty)
        #expect(device.detail == .object([:]))
        // Absent `in_control_range` is NOT out-of-range.
        #expect(device.isOutOfControlRange == false)
    }

    // MARK: - Replicant

    @Test func replicantSummaryMapsAndCoalesces() throws {
        let schema = try decode(
            Components.Schemas.AppSchemasAccountsReplicantSummarySchema.self,
            #"""
            {
              "replicant_code": "R1",
              "name": "pennig-1",
              "created_at": "2026-06-12T09:30:00Z",
              "current_star": "ATIANFU",
              "current_location": "ATIANFU-KUIPER",
              "hosted_device_code": "HOST",
              "experience_points": 4536,
              "device_count": 3
            }
            """#
        )
        let replicant = Replicant(schema: schema)
        #expect(replicant.replicantCode == "R1")
        #expect(replicant.name == "pennig-1")
        #expect(replicant.createdAt == (try Date("2026-06-12T09:30:00Z", strategy: .iso8601)))
        #expect(replicant.currentStar == "ATIANFU")
        #expect(replicant.currentStarName == nil)
        #expect(replicant.hostedDeviceCode == "HOST")
        #expect(replicant.experiencePoints == 4536)
        #expect(replicant.deviceCount == 3)

        let empty = Replicant(schema: try decode(
            Components.Schemas.AppSchemasAccountsReplicantSummarySchema.self, "{}"
        ))
        #expect(empty.replicantCode == "")
        #expect(empty.experiencePoints == 0)
        #expect(empty.createdAt == Date(timeIntervalSince1970: 0))
    }

    @Test func timestampParsingToleratesFractionsAndFallsBackToEpoch() {
        #expect(
            Replicant.parseTimestamp("2026-06-12T09:30:00.250Z")
                == (try? Date("2026-06-12T09:30:00.250Z", strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        )
        #expect(
            Replicant.parseTimestamp("2026-06-12T09:30:00Z")
                == (try? Date("2026-06-12T09:30:00Z", strategy: .iso8601))
        )
        // Malformed sorts predictably instead of crashing.
        #expect(Replicant.parseTimestamp("last tuesday") == Date(timeIntervalSince1970: 0))
        #expect(Replicant.parseTimestamp("") == Date(timeIntervalSince1970: 0))
    }

    // MARK: - Blueprint

    @Test func blueprintMapsCostsAndPreservesNilHubs() throws {
        let schema = try decode(
            Components.Schemas.AppSchemasBlueprintsBlueprintSchema.self,
            #"""
            {
              "device_type": "ftl_beacon",
              "short_description": "A beacon.",
              "description": "A long description.",
              "print_time": 900.0,
              "features": ["beacon"],
              "directives": [],
              "resources": {"structural": 1500, "silicates": 300, "unknown_future_resource": 7},
              "stow_capacity": 0,
              "queue_size": 1,
              "strength": 2.5
            }
            """#
        )
        let blueprint = Blueprint(schema: schema)
        #expect(blueprint.deviceType == "ftl_beacon")
        #expect(blueprint.printTime == 900)   // Double on the wire, whole seconds locally
        #expect(blueprint.resources.amount(for: "structural") == 1500)
        #expect(blueprint.resources.amount(for: "silicates") == 300)
        // A resource outside the six-key taxonomy is ignored, not a crash.
        #expect(blueprint.resources.amount(for: "unknown_future_resource") == 0)
        #expect(blueprint.strength == 2.5)
        #expect(blueprint.currentHubs == nil)   // preserved as nil, not coalesced to 0

        let empty = Blueprint(schema: try decode(
            Components.Schemas.AppSchemasBlueprintsBlueprintSchema.self, "{}"
        ))
        #expect(empty.deviceType == "")
        #expect(empty.printTime == 0)
        #expect(empty.resources == ResourceCost())
    }
}
