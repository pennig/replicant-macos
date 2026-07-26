//
//  EventLog.swift
//  Replicould — GameModels
//
//  A persisted record of one Server-Sent Event that crossed the app's ingestion
//  choke point (`EventRouter.dispatch`). Unlike the feature tables — which each
//  distil a slice of the stream into their own shape — this is the *raw* diagnostic
//  ledger: every event, verbatim, kept across launches so the SSE Event Log window
//  (a power-user tool modelled on Raw API Access) can inspect the live taxonomy.
//
//  Structured envelope metadata rides in typed columns (so the "unhandled only"
//  filter is a plain SQL `WHERE`), while the genuinely free-form `payload` is stored
//  as a JSON blob and reconstructed — together with the metadata — into `envelopeJSON`
//  for the detail pane's JSON tree.
//

import API
import Foundation
import SQLiteData
import Utils

/// One captured game event, persisted verbatim for the diagnostic Event Log.
@Table
public struct EventLog: Identifiable, Equatable, Sendable {
    /// Redis stream id (e.g. `1752681600000-0`) — globally unique, so it doubles as
    /// the primary key and natural dedupe key.
    @Column(primaryKey: true) public var id: String
    /// Dotted event name, e.g. `"mining.started"`.
    public var event: String
    /// Coarse family, e.g. `"mining"`.
    public var category: String
    public var replicantCode: String?
    public var deviceCode: String?
    public var deviceType: String?
    public var star: String?
    public var location: String?
    public var version: Int?
    /// ISO-8601 timestamp as delivered on the wire (may be absent/malformed).
    public var createdAt: String?
    /// Local receipt time — the ordering key for the log (the wire timestamp is
    /// optional and not always monotonic across catch-up replay).
    public var receivedAt: Date
    /// `"stream"` (live) or `"catchUp"` (historical replay pull).
    public var provenance: String
    /// Whether any *feature-specific* route consumed this event (or it carried a
    /// device code the catch-all device route handles) — the exact inverse of the
    /// dispatcher's "⚠️ UNHANDLED" condition.
    public var isHandled: Bool
    /// Comma-joined ids of the feature-specific routes that matched (empty when none).
    public var matchedRoutes: String?
    /// The event's free-form payload map, verbatim. `{}` when the event had none.
    @Column(as: JSONValue.JSONRepresentation.self) public var payload: JSONValue

    public init(
        id: String,
        event: String,
        category: String,
        replicantCode: String? = nil,
        deviceCode: String? = nil,
        deviceType: String? = nil,
        star: String? = nil,
        location: String? = nil,
        version: Int? = nil,
        createdAt: String? = nil,
        receivedAt: Date,
        provenance: String,
        isHandled: Bool,
        matchedRoutes: String? = nil,
        payload: JSONValue = .object([:])
    ) {
        self.id = id
        self.event = event
        self.category = category
        self.replicantCode = replicantCode
        self.deviceCode = deviceCode
        self.deviceType = deviceType
        self.star = star
        self.location = location
        self.version = version
        self.createdAt = createdAt
        self.receivedAt = receivedAt
        self.provenance = provenance
        self.isHandled = isHandled
        self.matchedRoutes = matchedRoutes
        self.payload = payload
    }
}

// MARK: - Mapping from the ingestion envelope

extension EventLog {
    /// Build a log row from a dispatched `GameEventEnvelope`, stamping `receivedAt`.
    /// The mapping lives beside the model so the row and the envelope never drift.
    public init(
        envelope: GameEventEnvelope,
        isHandled: Bool,
        matchedRouteIDs: [String],
        receivedAt: Date
    ) {
        self.init(
            id: envelope.id,
            event: envelope.event,
            category: envelope.category,
            replicantCode: envelope.replicantCode,
            deviceCode: envelope.deviceCode,
            deviceType: envelope.deviceType,
            star: envelope.star,
            location: envelope.location,
            version: envelope.version,
            createdAt: envelope.createdAt,
            receivedAt: receivedAt,
            provenance: envelope.provenance == .stream ? "stream" : "catchUp",
            isHandled: isHandled,
            matchedRoutes: matchedRouteIDs.isEmpty ? nil : matchedRouteIDs.joined(separator: ", "),
            payload: .object(envelope.payload ?? [:])
        )
    }
}

// MARK: - Detail rendering

extension EventLog {
    /// The full event reconstructed as a single JSON object for the detail tree:
    /// the typed metadata columns folded back together with the nested `payload`.
    /// Absent metadata is omitted (rather than rendered as `null`) to keep the tree
    /// readable; wire-style snake_case keys mirror how the event arrived.
    public var envelopeJSON: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "category": .string(category),
            "event": .string(event),
            "provenance": .string(provenance),
        ]
        if let version { object["version"] = .number(Double(version)) }
        if let replicantCode { object["replicant_code"] = .string(replicantCode) }
        if let deviceCode { object["device_code"] = .string(deviceCode) }
        if let deviceType { object["device_type"] = .string(deviceType) }
        if let star { object["star"] = .string(star) }
        if let location { object["location"] = .string(location) }
        if let createdAt { object["created_at"] = .string(createdAt) }
        object["payload"] = payload
        return .object(object)
    }
}

// MARK: - Schema

extension EventLog {
    /// Registers the `eventLogs` table migration. Kept beside the model so the
    /// schema and the type never drift. Composed into `bootstrapDatabase`.
    public static let createEventLogs = SchemaMigration("Create 'eventLogs' table") { db in
        try #sql(
            """
            CREATE TABLE "eventLogs" (
              "id" TEXT PRIMARY KEY NOT NULL,
              "event" TEXT NOT NULL DEFAULT '',
              "category" TEXT NOT NULL DEFAULT '',
              "replicantCode" TEXT,
              "deviceCode" TEXT,
              "deviceType" TEXT,
              "star" TEXT,
              "location" TEXT,
              "version" INTEGER,
              "createdAt" TEXT,
              "receivedAt" TEXT NOT NULL,
              "provenance" TEXT NOT NULL DEFAULT 'stream',
              "isHandled" INTEGER NOT NULL DEFAULT 0,
              "matchedRoutes" TEXT,
              "payload" TEXT NOT NULL DEFAULT '{}'
            ) STRICT
            """
        )
        .execute(db)
    }

    /// Temporary shim so `GameDatabase` keeps compiling mid-conversion.
    /// Deleted in the manifest task.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        createEventLogs.register(in: &migrator)
    }
}
