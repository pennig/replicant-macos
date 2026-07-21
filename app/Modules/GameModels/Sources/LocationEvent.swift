//
//  LocationEvent.swift
//  Replicould — GameModels
//
//  A discovered location event — a "quest": a time-limited or community objective
//  sited at a location, with tiered rewards you fulfil by delivering resources or
//  devices. Distinct from the `Operation` ledger (your own device commands): this
//  is the galaxy asking *you* to do something.
//
//  The whole account-wide list arrives from a single authoritative endpoint
//  (`GET /v1/accounts/events?status=all`), which carries full detail for every
//  event — criteria, live per-resource/-device progress, and rewards. We upsert
//  it into this table (preserving `firstSeenAt`) so the Location Events screen and
//  its sidebar badge stay live via `@FetchAll`, survive relaunch, and refresh off
//  a stream nudge the same way the inbox does. Summary columns are denormalised for
//  list rows and the badge; the full payload rides along in `detail` for the quest
//  sheet, decoded on demand into `LocationEventDetail`.
//

import Foundation
import SQLiteData
import Utils

/// A single discovered location event ("quest"), account-wide. Upserted from the
/// authoritative `accounts/events` list; the full payload lives in `detail`.
@Table
public struct LocationEvent: Identifiable, Equatable, Sendable {
    /// Event designation code (e.g. `KRIOS-2-EVT-001`) — the natural primary key.
    @Column(primaryKey: true) public var designation: String
    /// The location code where the event is sited (e.g. `KRIOS-2`, `SOL-3`).
    public var location: String
    public var locationName: String?
    public var eventType: String
    public var title: String
    public var category: String?
    public var tier: Int
    /// `active`, `completed`, … — drives the sidebar badge (active count) and the
    /// list's active-first ordering.
    public var status: String
    /// Whether every objective is met — the event is ready to complete. Denormalised
    /// from `detail.progress.met` so the sidebar's "ready" badge and the list's
    /// ready-first ordering stay pure SQL (no blob decode per row).
    public var objectivesMet: Bool
    public var broadcastMessage: String?
    public var eventDescription: String?
    public var discoveredAt: Date?
    public var completedAt: Date?
    /// The full event payload (criteria, progress, rewards), verbatim as JSON —
    /// decoded on demand by the quest sheet via `quest`.
    @Column(as: JSONValue.JSONRepresentation.self) public var detail: JSONValue
    /// Local-only provenance — when this event was first discovered locally.
    public var firstSeenAt: Date
    public var updatedAt: Date

    public var id: String { designation }

    public init(
        designation: String,
        location: String = "",
        locationName: String? = nil,
        eventType: String = "",
        title: String = "",
        category: String? = nil,
        tier: Int = 0,
        status: String = "active",
        objectivesMet: Bool = false,
        broadcastMessage: String? = nil,
        eventDescription: String? = nil,
        discoveredAt: Date? = nil,
        completedAt: Date? = nil,
        detail: JSONValue = .object([:]),
        firstSeenAt: Date,
        updatedAt: Date
    ) {
        self.designation = designation
        self.location = location
        self.locationName = locationName
        self.eventType = eventType
        self.title = title
        self.category = category
        self.tier = tier
        self.status = status
        self.objectivesMet = objectivesMet
        self.broadcastMessage = broadcastMessage
        self.eventDescription = eventDescription
        self.discoveredAt = discoveredAt
        self.completedAt = completedAt
        self.detail = detail
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
    }

    /// A human label for the event's location, falling back to the bare code.
    public var locationLabel: String { locationName ?? location }

    /// Whether this event is still open (drives the badge and active grouping).
    public var isActive: Bool { status.lowercased() == "active" }

    /// Whether the event is open *and* every objective is met — so it can be
    /// completed now. Drives the sidebar "ready" badge and the Complete button.
    public var isReady: Bool { isActive && objectivesMet }

    /// The status to render in a badge: a met-but-open event reads as `ready`
    /// (its own tone) rather than the bare backend `active`.
    public var displayStatus: String { isReady ? "ready" : status }

    /// The rich quest payload decoded from `detail` — criteria progress and
    /// rewards. Nil when no detail has been captured yet.
    public var quest: LocationEventDetail? { LocationEventDetail(detail) }
}

// MARK: - Merge

extension LocationEvent {
    /// A blank record for an event we've only just discovered, stamped `now`.
    static func fresh(designation: String, now: Date) -> LocationEvent {
        LocationEvent(designation: designation, firstSeenAt: now, updatedAt: now)
    }

    /// Fold one authoritative event payload (a `LocationEventSchema` object, as a
    /// loosely-typed `JSONValue`) into this record, preserving local provenance.
    /// Works off `JSONValue` so it's independent of the freeform generated schema.
    func merging(event: JSONValue, now: Date) -> LocationEvent {
        var copy = self
        if let location = event["location"]?.stringValue { copy.location = location }
        copy.locationName = event["location_name"]?.stringValue
        if let eventType = event["event_type"]?.stringValue { copy.eventType = eventType }
        if let title = event["title"]?.stringValue { copy.title = title }
        copy.category = event["category"]?.stringValue
        if let tier = event["tier"]?.numberValue { copy.tier = Int(tier) }
        if let status = event["status"]?.stringValue { copy.status = status }
        copy.objectivesMet = event["progress"]?["met"]?.boolValue ?? false
        copy.broadcastMessage = event["broadcast_message"]?.stringValue
        copy.eventDescription = event["description"]?.stringValue
        copy.discoveredAt = event["discovered_at"]?.stringValue.flatMap(DiversionSnapshot.parseDate)
        copy.completedAt = event["completed_at"]?.stringValue.flatMap(DiversionSnapshot.parseDate)
        copy.detail = event
        copy.updatedAt = now
        return copy
    }
}

// MARK: - Persistence helpers

extension LocationEvent {
    /// Merge an authoritative `accounts/events` page into the table (fetch-merge-
    /// upsert per row so `firstSeenAt` survives). Entries without a designation are
    /// skipped (nothing to key on).
    public static func upsert(
        events: [JSONValue],
        into db: Database,
        now: Date
    ) throws {
        for event in events {
            guard let designation = event["designation"]?.stringValue, !designation.isEmpty
            else { continue }
            let existing = try LocationEvent.where { $0.designation.eq(designation) }.fetchOne(db)
            let merged = (existing ?? .fresh(designation: designation, now: now))
                .merging(event: event, now: now)
            try LocationEvent.upsert { merged }.execute(db)
        }
    }
}

// MARK: - Schema

extension LocationEvent {
    /// Registers the `locationEvents` table migration. Kept beside the model so the
    /// schema and the type never drift. Composed into `bootstrapDatabase` alongside
    /// the other tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'locationEvents' table") { db in
            try #sql(
                """
                CREATE TABLE "locationEvents" (
                  "designation" TEXT PRIMARY KEY NOT NULL,
                  "location" TEXT NOT NULL DEFAULT '',
                  "locationName" TEXT,
                  "eventType" TEXT NOT NULL DEFAULT '',
                  "title" TEXT NOT NULL DEFAULT '',
                  "category" TEXT,
                  "tier" INTEGER NOT NULL DEFAULT 0,
                  "status" TEXT NOT NULL DEFAULT 'active',
                  "broadcastMessage" TEXT,
                  "eventDescription" TEXT,
                  "discoveredAt" TEXT,
                  "completedAt" TEXT,
                  "detail" TEXT NOT NULL DEFAULT '{}',
                  "firstSeenAt" TEXT NOT NULL,
                  "updatedAt" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }
        migrator.registerMigration("Add 'objectivesMet' to locationEvents") { db in
            try #sql(
                """
                ALTER TABLE "locationEvents"
                ADD COLUMN "objectivesMet" INTEGER NOT NULL DEFAULT 0
                """
            )
            .execute(db)
        }
    }
}

// MARK: - Quest detail (decoded from `detail` on demand)

/// The rich, decoded quest payload for the detail pane: overall completion state,
/// each fulfilment option's per-resource/-device progress, and the rewards. Parsed
/// straight from the loosely-typed event `detail` blob so spec drift can't break
/// it (unknown keys ignored, missing keys default).
public struct LocationEventDetail: Equatable, Sendable {
    /// A resource requirement with live progress (`current` toward `required`).
    public struct ResourceRequirement: Equatable, Sendable, Identifiable {
        public let resourceType: String
        public let current: Int
        public let required: Int
        public let met: Bool
        public var id: String { resourceType }
        public var fraction: Double { required > 0 ? min(1, Double(current) / Double(required)) : (met ? 1 : 0) }
    }

    /// A device requirement with live progress (`current` toward `required`).
    public struct DeviceRequirement: Equatable, Sendable, Identifiable {
        public let deviceType: String
        public let current: Int
        public let required: Int
        public let met: Bool
        public var id: String { deviceType }
        public var fraction: Double { required > 0 ? min(1, Double(current) / Double(required)) : (met ? 1 : 0) }
    }

    /// One way to satisfy the event (usually a single "default" option).
    public struct Option: Equatable, Sendable, Identifiable {
        public let name: String
        public let met: Bool
        public let resources: [ResourceRequirement]
        public let devices: [DeviceRequirement]
        public var id: String { name }
    }

    /// A granted resource amount on completion.
    public struct RewardResource: Equatable, Sendable, Identifiable {
        public let resourceType: String
        public let amount: Int
        public var id: String { resourceType }
    }

    public let met: Bool
    public let replicantPresent: Bool
    public let options: [Option]
    public let experiencePoints: Int?
    public let civilisationPoints: Int?
    public let completionAchievement: String?
    public let rewardResources: [RewardResource]

    /// Decode from a raw event `detail` blob. Returns nil only when the blob has no
    /// `progress` *and* no `rewards` (i.e. it was never hydrated).
    public init?(_ json: JSONValue) {
        let progress = json["progress"]
        let rewards = json["rewards"]
        guard progress != nil || rewards != nil else { return nil }

        met = progress?["met"]?.boolValue ?? false
        replicantPresent = progress?["replicant_present"]?.boolValue ?? false
        options = (progress?["options"]?.arrayValue ?? []).map { opt in
            Option(
                name: opt["name"]?.stringValue ?? "default",
                met: opt["met"]?.boolValue ?? false,
                resources: (opt["resources"]?.arrayValue ?? []).compactMap { r in
                    guard let type = r["resource_type"]?.stringValue else { return nil }
                    return ResourceRequirement(
                        resourceType: type,
                        current: Int(r["current"]?.numberValue ?? 0),
                        required: Int(r["required"]?.numberValue ?? 0),
                        met: r["met"]?.boolValue ?? false
                    )
                },
                devices: (opt["devices"]?.arrayValue ?? []).compactMap { d in
                    guard let type = d["device_type"]?.stringValue else { return nil }
                    return DeviceRequirement(
                        deviceType: type,
                        current: Int(d["current"]?.numberValue ?? 0),
                        required: Int(d["required"]?.numberValue ?? 0),
                        met: d["met"]?.boolValue ?? false
                    )
                }
            )
        }

        experiencePoints = rewards?["xp"]?.numberValue.map(Int.init)
        civilisationPoints = rewards?["civilisation_points"]?.numberValue.map(Int.init)
        completionAchievement = rewards?["completion_achievement"]?.stringValue
        if case .object(let dict)? = rewards?["resources"] {
            rewardResources = dict
                .compactMap { key, value in
                    value.numberValue.map { RewardResource(resourceType: key, amount: Int($0)) }
                }
                .sorted { $0.resourceType < $1.resourceType }
        } else {
            rewardResources = []
        }
    }
}
