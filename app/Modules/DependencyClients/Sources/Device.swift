//
//  Device.swift
//  Replicould — shared dependency clients
//
//  The locally-persisted device record. Fetched from `GET /v1/devices/{code}`
//  (and, later, the account list walk) and upserted into SQLite so the fleet
//  reads instantly and stays live off the relay. Mirrors
//  `app_schemas_devices_DeviceStatusSchema`.
//
//  Storage follows IMPLEMENTATION_PLAN §4.1: stable typed columns for the
//  universal fields (which drive lists / status badges / capacity rings and are
//  observed via `@FetchAll`), plus a single `detail` JSON blob holding the
//  entire variable per-`device_type` tail verbatim — both the typed activity
//  sub-objects (`travel`, `mining`, `printing`, …) and the schemaless
//  `additionalProperties` objects (`ami_directive`, `system_status`, …). The
//  detail pane decodes just the subtree it needs on demand, so a new device type
//  or field needs no migration.
//

import API
import Foundation
import SQLiteData
import Utils

/// A single device owned by the signed-in account.
@Table
public struct Device: Identifiable, Equatable, Sendable {
    /// Device designation code — the natural primary key.
    @Column(primaryKey: true) public var deviceCode: String
    public var deviceType: String
    public var replicantCode: String
    public var status: String
    /// Location code; null when undeployed or in deep space.
    public var location: String?
    public var locationName: String?
    public var operationalCapacity: Double
    public var queueSize: Int
    public var stowedInDeviceCode: String?
    public var controllerDeviceCode: String?
    public var attachedToDeviceCode: String?
    public var createdAt: Date
    @Column(as: [String].JSONRepresentation.self) public var availableCommands: [String]
    @Column(as: [String].JSONRepresentation.self) public var features: [String]
    @Column(as: [String].JSONRepresentation.self) public var tags: [String]
    /// The entire variable per-type tail, verbatim (snake_case keys, as on the
    /// wire), with the core-column keys stripped. Decoded on demand.
    @Column(as: JSONValue.JSONRepresentation.self) public var detail: JSONValue
    /// Synthesized authoritative event-time used by the reconciliation guard
    /// (§4.1 / §6): the relay event `timestamp` for events, or fetch wall-clock
    /// for reads. The payload carries no server modified-time.
    public var updatedAt: Date
    /// Local-only provenance — when this device was first seen. Preserved across
    /// upserts (like `Star.createdAt`).
    public var firstSeenAt: Date

    public var id: String { deviceCode }

    public init(
        deviceCode: String,
        deviceType: String,
        replicantCode: String,
        status: String,
        location: String?,
        locationName: String?,
        operationalCapacity: Double,
        queueSize: Int,
        stowedInDeviceCode: String?,
        controllerDeviceCode: String?,
        attachedToDeviceCode: String?,
        createdAt: Date,
        availableCommands: [String],
        features: [String],
        tags: [String],
        detail: JSONValue,
        updatedAt: Date,
        firstSeenAt: Date
    ) {
        self.deviceCode = deviceCode
        self.deviceType = deviceType
        self.replicantCode = replicantCode
        self.status = status
        self.location = location
        self.locationName = locationName
        self.operationalCapacity = operationalCapacity
        self.queueSize = queueSize
        self.stowedInDeviceCode = stowedInDeviceCode
        self.controllerDeviceCode = controllerDeviceCode
        self.attachedToDeviceCode = attachedToDeviceCode
        self.createdAt = createdAt
        self.availableCommands = availableCommands
        self.features = features
        self.tags = tags
        self.detail = detail
        self.updatedAt = updatedAt
        self.firstSeenAt = firstSeenAt
    }
}

// MARK: - Mapping

extension Device {
    /// Map a generated device snapshot onto the local record. `fetchedAt` is the
    /// synthesized event-time (the read's wall-clock) and seeds `firstSeenAt` on
    /// first insert; the reconciliation guard preserves the stored `firstSeenAt`
    /// thereafter.
    public init(
        schema: Components.Schemas.AppSchemasDevicesDeviceStatusSchema,
        fetchedAt: Date
    ) {
        self.init(
            deviceCode: schema.deviceCode ?? "",
            deviceType: schema.deviceType ?? "",
            replicantCode: schema.replicantCode ?? "",
            status: schema.status ?? "",
            location: schema.location,
            locationName: schema.locationName,
            operationalCapacity: schema.operationalCapacity ?? 0,
            queueSize: schema.queueSize ?? 0,
            stowedInDeviceCode: schema.stowedInDeviceCode,
            controllerDeviceCode: schema.controllerDeviceCode,
            attachedToDeviceCode: schema.attachedToDeviceCode,
            createdAt: schema.createdAt ?? Date(timeIntervalSince1970: 0),
            availableCommands: schema.availableCommands ?? [],
            features: schema.features ?? [],
            tags: schema.tags ?? [],
            detail: Self.detailJSON(from: schema),
            updatedAt: fetchedAt,
            firstSeenAt: fetchedAt
        )
    }

    /// The keys promoted to typed columns; stripped from `detail` so the blob is
    /// just the variable tail.
    private static let coreKeys: Set<String> = [
        "device_code", "device_type", "replicant_code", "status", "location",
        "location_name", "operational_capacity", "queue_size", "stowed_in_device_code",
        "controller_device_code", "attached_to_device_code", "created_at",
        "available_commands", "features", "tags",
    ]

    private static let detailEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Re-encode the generated snapshot to JSON and keep everything except the
    /// core-column keys. Falls back to an empty object if the round-trip fails,
    /// so a quirk in one device never blocks ingestion.
    static func detailJSON(from schema: Components.Schemas.AppSchemasDevicesDeviceStatusSchema) -> JSONValue {
        guard
            let data = try? detailEncoder.encode(schema),
            case .object(var dict)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .object([:]) }
        for key in coreKeys { dict.removeValue(forKey: key) }
        return .object(dict)
    }
}

// MARK: - Operation completion signals

extension Device {
    /// Device statuses that mean it is *not* executing a timed operation. The
    /// relay completion event is the primary signal that an op finished; when
    /// that's lost, the deadline scheduler falls back to this — an op is complete
    /// once its device has settled.
    public static let settledStatuses: Set<String> = ["idle", "stowed", "inactive"]

    /// Whether the device is idle / done with any timed activity.
    public var isSettled: Bool { Self.settledStatuses.contains(status) }

    /// The soonest completion time reported by an in-progress activity block in
    /// `detail` (travel/mining/printing/…), if the device is still mid-activity.
    /// Used to re-arm the deadline when the server's estimate slips past the
    /// original ETA (so the bar stays honest and the scheduler keeps polling
    /// instead of completing the op prematurely). All activity-timing payload
    /// parsing lives here, in one place. Nil when no active block is present.
    public var activityDeadline: Date? {
        let blocks: [(block: String, fields: [String])] = [
            ("travel", ["arrives_at", "final_arrives_at"]),
            ("mining", ["completes_at", "cycle_completes_at"]),
            ("printing", ["completes_at"]),
            ("scan", ["completes_at"]),
            ("prospect", ["completes_at"]),
            ("repair", ["completes_at"]),
        ]
        var soonest: Date?
        for (block, fields) in blocks {
            guard case .object = detail[block] else { continue }
            for field in fields {
                if let string = detail[block]?[field]?.stringValue,
                   let date = Self.parseActivityDate(string) {
                    soonest = soonest.map { min($0, date) } ?? date
                }
            }
        }
        // The survey `scan`/search block reports *remaining* time as
        // `eta_seconds` rather than an absolute `completes_at`, so derive its
        // deadline off the fetch event-time. (Folded in after the loop so a
        // future scan variant carrying `completes_at` still wins via the table.)
        if case .object = detail["scan"], let eta = detail["scan"]?["eta_seconds"]?.numberValue {
            let date = updatedAt.addingTimeInterval(eta)
            soonest = soonest.map { Swift.min($0, date) } ?? date
        }
        return soonest
    }

    private static func parseActivityDate(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle()) { return date }
        return nil
    }
}

// MARK: - Derived operations

extension Device {
    /// An open operation derived from an in-progress device snapshot. The
    /// reconcile path adopts this when the device holds no operation of its own —
    /// e.g. a cold-load or relaunch finds the device already printing or
    /// travelling, so its task (and progress bar) would otherwise be invisible
    /// because ops are normally only created by optimistic command dispatch. Nil
    /// when the device is settled or carries no recognized activity block.
    public struct DerivedActivity: Equatable, Sendable {
        public let kind: OperationKind
        public let startedAt: Date?
        public let completesAt: Date?
    }

    /// The in-progress activity this snapshot describes, if any. Reads the same
    /// `detail` activity blocks as `activityDeadline`, but identifies the kind so
    /// an op can be reconstructed. Mining is continuous (its cycle deadline is the
    /// soonest completion, not the op's end), so its `completesAt` is best-effort.
    public var derivedActivity: DerivedActivity? {
        guard !isSettled else { return nil }
        if case .object = detail["printing"] {
            return DerivedActivity(
                kind: .print,
                startedAt: detailDate("printing", "started_at"),
                completesAt: detailDate("printing", "completes_at")
            )
        }
        if case .object = detail["travel"] {
            return DerivedActivity(
                kind: .travel,
                startedAt: detailDate("travel", "started_at"),
                completesAt: detailDate("travel", "arrives_at") ?? detailDate("travel", "final_arrives_at")
            )
        }
        if case .object = detail["mining"] {
            return DerivedActivity(
                kind: .mine,
                startedAt: detailDate("mining", "started_at"),
                completesAt: detailDate("mining", "completes_at") ?? detailDate("mining", "cycle_completes_at")
            )
        }
        // Survey-drone search: a `scan` block with an `eta_seconds` countdown (no
        // absolute completion). The deadline is the fetch event-time plus the
        // remaining ETA — eta_seconds is *remaining*, not total, so anchoring on
        // `updatedAt` (not `started_at`) lands on the real finish.
        if case .object = detail["scan"] {
            return DerivedActivity(
                kind: .search,
                startedAt: detailDate("scan", "started_at"),
                completesAt: detailDate("scan", "completes_at")
                    ?? detail["scan"]?["eta_seconds"]?.numberValue.map { updatedAt.addingTimeInterval($0) }
            )
        }
        return nil
    }

    private func detailDate(_ block: String, _ field: String) -> Date? {
        guard let string = detail[block]?[field]?.stringValue else { return nil }
        return Self.parseActivityDate(string)
    }
}

// MARK: - Schema

extension Device {
    /// Registers the `devices` table migration. Kept beside the model so the
    /// schema and the type never drift. Composed into the app's
    /// `bootstrapDatabase` alongside other tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'devices' table") { db in
            try #sql(
                """
                CREATE TABLE "devices" (
                  "deviceCode" TEXT PRIMARY KEY NOT NULL,
                  "deviceType" TEXT NOT NULL DEFAULT '',
                  "replicantCode" TEXT NOT NULL DEFAULT '',
                  "status" TEXT NOT NULL DEFAULT '',
                  "location" TEXT,
                  "locationName" TEXT,
                  "operationalCapacity" REAL NOT NULL DEFAULT 0,
                  "queueSize" INTEGER NOT NULL DEFAULT 0,
                  "stowedInDeviceCode" TEXT,
                  "controllerDeviceCode" TEXT,
                  "attachedToDeviceCode" TEXT,
                  "createdAt" TEXT NOT NULL,
                  "availableCommands" TEXT NOT NULL DEFAULT '[]',
                  "features" TEXT NOT NULL DEFAULT '[]',
                  "tags" TEXT NOT NULL DEFAULT '[]',
                  "detail" TEXT NOT NULL DEFAULT '{}',
                  "updatedAt" TEXT NOT NULL,
                  "firstSeenAt" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}
