//
//  KnownReplicant.swift
//  Replicould — shared dependency clients
//
//  The galaxy-wide replicant directory as a local record — every replicant known
//  to this account, its own and others' (players and NPCs alike). Distinct from
//  the `Replicant` roster table (which holds only the account's own replicants,
//  fetched from `accounts/me` for the sidebar): this backs the Replicants screen,
//  which surveys the whole known galaxy.
//
//  Three sources feed it, each contributing what it knows and preserving the rest
//  (merge, not clobber):
//   • the directory (`GET /v1/replicants`) — code, name, is_npc, and a
//     low-fidelity `last_location` (mostly populated for NPCs);
//   • the details endpoint (`GET /v1/replicants/{code}`) — status, XP, host, and
//     the current `location` (authoritative), plus the full lore/inventory blob;
//   • scan responses (`system_scan`) — a `replicants` block listing everyone
//     detected in the scanned system with a precise `location` and `last_active`
//     timestamp. This is the only fidelity we get for *other players'* positions,
//     since the directory withholds them.
//
//  `lastKnownLocation` (scan/details) is preferred over `directoryLocation` when
//  showing where a replicant was last seen.
//

import API
import Foundation
import SQLiteData
import Utils

/// A single replicant known to this account — its own, another player's, or an
/// NPC. Merged from the directory, the details endpoint, and scan sightings.
@Table
public struct KnownReplicant: Identifiable, Equatable, Sendable {
    /// Replicant designation code — the natural primary key.
    @Column(primaryKey: true) public var replicantCode: String
    public var name: String
    public var isNPC: Bool
    /// Low-fidelity location from the directory (`last_location`), mostly NPCs.
    public var directoryLocation: String?
    /// Precise last-known location from a scan sighting or the details endpoint.
    public var lastKnownLocation: String?
    public var lastKnownLocationName: String?
    /// When the replicant was last detected at `lastKnownLocation` (scan
    /// `last_active`), or last confirmed present via details.
    public var lastSeenAt: Date?
    /// The replicant's activity status, from details (`stationary`, `travelling`, …).
    public var status: String?
    public var experiencePoints: Int
    /// The device this replicant currently inhabits, from details.
    public var hostedDeviceCode: String?
    /// The full details payload (lore, position, stowed/attached devices, cargo,
    /// print queue), verbatim as JSON — decoded on demand by the detail pane.
    /// Empty until details are fetched.
    @Column(as: JSONValue.JSONRepresentation.self) public var detail: JSONValue
    /// When the details endpoint was last fetched for this replicant; nil until
    /// the detail pane loads it once.
    public var detailFetchedAt: Date?
    /// Local-only provenance — when this replicant was first seen.
    public var firstSeenAt: Date
    public var updatedAt: Date

    public var id: String { replicantCode }

    public init(
        replicantCode: String,
        name: String = "",
        isNPC: Bool = false,
        directoryLocation: String? = nil,
        lastKnownLocation: String? = nil,
        lastKnownLocationName: String? = nil,
        lastSeenAt: Date? = nil,
        status: String? = nil,
        experiencePoints: Int = 0,
        hostedDeviceCode: String? = nil,
        detail: JSONValue = .object([:]),
        detailFetchedAt: Date? = nil,
        firstSeenAt: Date,
        updatedAt: Date
    ) {
        self.replicantCode = replicantCode
        self.name = name
        self.isNPC = isNPC
        self.directoryLocation = directoryLocation
        self.lastKnownLocation = lastKnownLocation
        self.lastKnownLocationName = lastKnownLocationName
        self.lastSeenAt = lastSeenAt
        self.status = status
        self.experiencePoints = experiencePoints
        self.hostedDeviceCode = hostedDeviceCode
        self.detail = detail
        self.detailFetchedAt = detailFetchedAt
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
    }

    /// Where this replicant was last seen, preferring precise intel (scan /
    /// details) over the directory's coarse `last_location`. Nil when nothing is
    /// known.
    public var displayLocation: String? {
        lastKnownLocation ?? directoryLocation
    }

    /// The human label for `displayLocation`, falling back to the bare code.
    public var displayLocationLabel: String? {
        if lastKnownLocation != nil { return lastKnownLocationName ?? lastKnownLocation }
        return directoryLocation
    }
}

// MARK: - Merge

extension KnownReplicant {
    /// A blank record for a code we've only just heard of, stamped `now`.
    static func fresh(code: String, now: Date) -> KnownReplicant {
        KnownReplicant(replicantCode: code, firstSeenAt: now, updatedAt: now)
    }

    /// Fold a directory search item into this record, preserving richer fields
    /// (scan/details intel) the directory doesn't carry.
    func merging(directoryItem item: Components.Schemas.AppSchemasReplicantsReplicantSearchItemSchema, now: Date) -> KnownReplicant {
        var copy = self
        if let name = item.name, !name.isEmpty { copy.name = name }
        if let isNpc = item.isNpc { copy.isNPC = isNpc }
        // The directory reports `null` to mean "unknown", so only overwrite with a
        // present value.
        if let location = item.lastLocation { copy.directoryLocation = location }
        copy.updatedAt = now
        return copy
    }

    /// Fold a details payload into this record. `blob` is the whole details
    /// response re-encoded as JSON (the detail pane decodes subtrees from it).
    func merging(
        details schema: Components.Schemas.AppSchemasReplicantsReplicantStatusSchema,
        blob: JSONValue,
        now: Date
    ) -> KnownReplicant {
        var copy = self
        if let name = schema.name, !name.isEmpty { copy.name = name }
        if let isNpc = schema.isNpc { copy.isNPC = isNpc }
        if let status = schema.status { copy.status = status }
        if let xp = schema.experiencePoints { copy.experiencePoints = xp }
        if let host = schema.hostedDeviceCode { copy.hostedDeviceCode = host }
        // Details carry the authoritative current location — a fresh, precise
        // sighting.
        if let location = schema.location {
            copy.lastKnownLocation = location
            copy.lastKnownLocationName = schema.locationName
            copy.lastSeenAt = now
        }
        copy.detail = blob
        copy.detailFetchedAt = now
        copy.updatedAt = now
        return copy
    }

    /// Fold a scan sighting into this record — the precise position and time a
    /// replicant was detected in a scanned system.
    func merging(sighting: ScanSighting, now: Date) -> KnownReplicant {
        var copy = self
        if let name = sighting.name, !name.isEmpty, copy.name.isEmpty { copy.name = name }
        copy.lastKnownLocation = sighting.location
        copy.lastKnownLocationName = nil   // the scan block carries only the code
        if let lastActive = sighting.lastActive { copy.lastSeenAt = lastActive }
        else { copy.lastSeenAt = now }
        copy.updatedAt = now
        return copy
    }

    /// Set the public `plan` inside the details blob, leaving every other field
    /// intact. Creates a minimal `{plan}` blob when no details have been fetched.
    func settingPlan(_ plan: String, now: Date) -> KnownReplicant {
        var copy = self
        if case .object(var dict) = copy.detail {
            dict["plan"] = .string(plan)
            copy.detail = .object(dict)
        } else {
            copy.detail = .object(["plan": .string(plan)])
        }
        copy.updatedAt = now
        return copy
    }

    /// Seed a record from an owned roster `Replicant`, so the account's own
    /// replicants always appear in the directory list with their current location
    /// even before the galaxy walk reaches them.
    func merging(roster replicant: Replicant, now: Date) -> KnownReplicant {
        var copy = self
        if !replicant.name.isEmpty { copy.name = replicant.name }
        copy.isNPC = false
        if replicant.experiencePoints > 0 { copy.experiencePoints = replicant.experiencePoints }
        if let host = replicant.hostedDeviceCode { copy.hostedDeviceCode = host }
        if let location = replicant.currentLocation {
            copy.lastKnownLocation = location
            copy.lastKnownLocationName = replicant.currentLocationName
            copy.lastSeenAt = now
        }
        copy.updatedAt = now
        return copy
    }
}

// MARK: - Scan sightings

/// One replicant detected in a scanned system — the precise last-known-location
/// intel that drives player-replicant tracking.
public struct ScanSighting: Equatable, Sendable {
    public var code: String
    public var name: String?
    public var location: String
    public var lastActive: Date?

    public init(code: String, name: String? = nil, location: String, lastActive: Date? = nil) {
        self.code = code
        self.name = name
        self.location = location
        self.lastActive = lastActive
    }
}

extension KnownReplicant {
    /// Parse the `replicants` block of a scan response (`system_scan`) — each entry
    /// carries `{replicant_code, name, location, last_active}`. Entries missing a
    /// code or location are skipped (nothing actionable to record). Works off the
    /// loosely-typed `JSONValue` so it's independent of the opaque generated
    /// scan-payload schema.
    public static func scanSightings(from response: JSONValue?) -> [ScanSighting] {
        guard let entries = response?["replicants"]?.arrayValue else { return [] }
        return entries.compactMap { entry in
            guard
                let code = entry["replicant_code"]?.stringValue, !code.isEmpty,
                let location = entry["location"]?.stringValue, !location.isEmpty
            else { return nil }
            return ScanSighting(
                code: code,
                name: entry["name"]?.stringValue,
                location: location,
                lastActive: entry["last_active"]?.stringValue.flatMap(DiversionSnapshot.parseDate)
            )
        }
    }
}

// MARK: - Persistence helpers

extension KnownReplicant {
    /// Merge a directory page into the table (fetch-merge-upsert per row so scan /
    /// details intel survives).
    public static func upsert(
        directory items: [Components.Schemas.AppSchemasReplicantsReplicantSearchItemSchema],
        into db: Database,
        now: Date
    ) throws {
        for item in items {
            guard let code = item.replicantCode, !code.isEmpty else { continue }
            let existing = try KnownReplicant.where { $0.replicantCode.eq(code) }.fetchOne(db)
            let merged = (existing ?? .fresh(code: code, now: now)).merging(directoryItem: item, now: now)
            try KnownReplicant.upsert { merged }.execute(db)
        }
    }

    /// Merge a fetched details payload into the table.
    public static func upsert(
        detailsFor code: String,
        schema: Components.Schemas.AppSchemasReplicantsReplicantStatusSchema,
        blob: JSONValue,
        into db: Database,
        now: Date
    ) throws {
        let existing = try KnownReplicant.where { $0.replicantCode.eq(code) }.fetchOne(db)
        let merged = (existing ?? .fresh(code: code, now: now)).merging(details: schema, blob: blob, now: now)
        try KnownReplicant.upsert { merged }.execute(db)
    }

    /// Record scan sightings, creating rows for newly-seen replicants and updating
    /// last-known-location for ones we already track.
    public static func record(
        sightings: [ScanSighting],
        into db: Database,
        now: Date
    ) throws {
        for sighting in sightings {
            let existing = try KnownReplicant.where { $0.replicantCode.eq(sighting.code) }.fetchOne(db)
            let merged = (existing ?? .fresh(code: sighting.code, now: now)).merging(sighting: sighting, now: now)
            try KnownReplicant.upsert { merged }.execute(db)
        }
    }

    /// Set a replicant's public `plan` in its local record, preserving the rest of
    /// the details blob. Used to reflect a just-accepted PATCH without refetching.
    public static func upsert(
        planFor code: String,
        plan: String,
        into db: Database,
        now: Date
    ) throws {
        let existing = try KnownReplicant.where { $0.replicantCode.eq(code) }.fetchOne(db)
        let merged = (existing ?? .fresh(code: code, now: now)).settingPlan(plan, now: now)
        try KnownReplicant.upsert { merged }.execute(db)
    }

    /// Seed the table from the owned roster so the account's own replicants always
    /// appear (with current location) alongside the galaxy directory.
    public static func upsert(
        roster replicants: [Replicant],
        into db: Database,
        now: Date
    ) throws {
        for replicant in replicants {
            let existing = try KnownReplicant.where { $0.replicantCode.eq(replicant.replicantCode) }.fetchOne(db)
            let merged = (existing ?? .fresh(code: replicant.replicantCode, now: now)).merging(roster: replicant, now: now)
            try KnownReplicant.upsert { merged }.execute(db)
        }
    }
}

// MARK: - Detail accessors

extension KnownReplicant {
    /// A device the replicant currently carries, from the details `stowed_devices`
    /// / `attached_devices` arrays (`{device_code, device_type}`).
    public struct CarriedDevice: Equatable, Sendable, Identifiable {
        public let deviceCode: String
        public let deviceType: String
        public var id: String { deviceCode }
    }

    public var pronouns: String? { detail["pronouns"]?.stringValue }
    public var plan: String? { detail["plan"]?.stringValue }
    public var project: String? { detail["project"]?.stringValue }
    public var descriptionText: String? { detail["description"]?.stringValue }
    public var cohortPermission: String? { detail["cohort_permission"]?.stringValue }

    public var stowedDevices: [CarriedDevice] { Self.devices(detail["stowed_devices"]) }
    public var attachedDevices: [CarriedDevice] { Self.devices(detail["attached_devices"]) }

    /// The number of cargo entries the replicant is carrying, from details.
    public var cargoCount: Int { detail["cargo"]?.arrayValue?.count ?? 0 }

    private static func devices(_ value: JSONValue?) -> [CarriedDevice] {
        value?.arrayValue?.compactMap { entry in
            guard let code = entry["device_code"]?.stringValue else { return nil }
            return CarriedDevice(deviceCode: code, deviceType: entry["device_type"]?.stringValue ?? "")
        } ?? []
    }
}

// MARK: - Schema

extension KnownReplicant {
    /// Creates the `knownReplicants` table. Kept beside the model so the schema
    /// and the type never drift.
    public static let createKnownReplicants = SchemaMigration("Create 'knownReplicants' table") { db in
        try #sql(
            """
            CREATE TABLE "knownReplicants" (
              "replicantCode" TEXT PRIMARY KEY NOT NULL,
              "name" TEXT NOT NULL DEFAULT '',
              "isNPC" INTEGER NOT NULL DEFAULT 0,
              "directoryLocation" TEXT,
              "lastKnownLocation" TEXT,
              "lastKnownLocationName" TEXT,
              "lastSeenAt" TEXT,
              "status" TEXT,
              "experiencePoints" INTEGER NOT NULL DEFAULT 0,
              "hostedDeviceCode" TEXT,
              "detail" TEXT NOT NULL DEFAULT '{}',
              "detailFetchedAt" TEXT,
              "firstSeenAt" TEXT NOT NULL,
              "updatedAt" TEXT NOT NULL
            ) STRICT
            """
        )
        .execute(db)
    }
}
