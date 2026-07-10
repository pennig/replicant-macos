//
//  Operation.swift
//  Replicould — shared dependency clients
//
//  A long-running server action as a first-class local row (IMPLEMENTATION_PLAN
//  §4). One `Operation` tracks the lifecycle of a command on a device — from the
//  instant the user fires it (optimistic) through confirmation (active/enqueued)
//  to completion — so every screen showing the device reflects its task by
//  observing SQLite, and the deadline scheduler (Phase 4) has rows to watch.
//
//  Correlation is by `entityCode` (the device code): there is at most one open
//  operation per device, enforced by a partial unique index. The provisional
//  `optimistic` state is deliberately excluded from that index so firing a
//  command never conflicts with a still-running prior op — the prior op is only
//  superseded once the new one is *confirmed* (so a 4xx rejection leaves the
//  prior op untouched).
//

import Foundation
import SQLiteData
import Utils

@Table
public struct Operation: Identifiable, Equatable, Sendable {
    /// Client-local UUID — there is no server-side operation id to correlate on.
    @Column(primaryKey: true) public var id: String
    /// The device this operation runs on (`device_code`).
    public var entityCode: String
    /// `OperationKind.rawValue`.
    public var kind: String
    /// Lifecycle state, stored as its `rawValue` in a `TEXT` column.
    public var status: OperationStatus
    /// Which writer last touched this row, stored as its `rawValue` in a `TEXT`
    /// column.
    public var source: OperationSource
    public var startedAt: Date
    /// When the action completes; nil for enqueued ops with no deadline yet.
    /// Drives the Phase-4 deadline scheduler and the progress bar.
    public var completesAt: Date?
    /// Freshness — when a writer last confirmed this row against the server.
    public var lastConfirmedAt: Date
    /// Command params and result (e.g. travel `destination`, print
    /// `new_device_code`), kept loosely typed since they vary by kind.
    @Column(as: JSONValue.JSONRepresentation.self) public var detail: JSONValue

    public init(
        id: String,
        entityCode: String,
        kind: String,
        status: OperationStatus,
        source: OperationSource,
        startedAt: Date,
        completesAt: Date?,
        lastConfirmedAt: Date,
        detail: JSONValue
    ) {
        self.id = id
        self.entityCode = entityCode
        self.kind = kind
        self.status = status
        self.source = source
        self.startedAt = startedAt
        self.completesAt = completesAt
        self.lastConfirmedAt = lastConfirmedAt
        self.detail = detail
    }
}

// MARK: - Taxonomy

/// The lifecycle state of an operation (IMPLEMENTATION_PLAN §4 state machine).
public enum OperationStatus: String, Sendable, CaseIterable, QueryBindable {
    /// Provisional, just inserted on dispatch — excluded from the open-uniqueness
    /// index so it never conflicts with a still-running prior op.
    case optimistic
    case enqueued
    case active
    case completed
    case failed
    case rejected
    case superseded
    case unknown

    /// optimistic + enqueued + active — an operation still in flight (see `isOpen`).
    /// Shared so the Swift property and the `.in(_:)` query predicates agree by
    /// construction.
    public static let openCases: [OperationStatus] = [.optimistic, .enqueued, .active]

    /// The subset the partial unique index enforces as "one open per device".
    /// Excludes `optimistic` by design, so dispatch can stage a row without
    /// conflicting with the op it may replace.
    public static let liveCases: [OperationStatus] = [.enqueued, .active]

    public var isOpen: Bool { Self.openCases.contains(self) }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .rejected, .superseded, .unknown: return true
        case .optimistic, .enqueued, .active: return false
        }
    }
}

/// The kind of action. `rawValue` is a stable local identifier stored in
/// `Operation.kind`; the backend `command` string it maps to is resolved in
/// `CommandClient` (e.g. `mine` → `start_mining`, `print` → `enqueue_print`,
/// `census` → `stellar_census`).
///
/// Modeled as a `RawRepresentable` newtype rather than a closed enum so simple,
/// parameter-less lifecycle commands (`deactivate`, `recall`, …) can be
/// represented by their backend verb without a dedicated case per command.
public struct OperationKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Tracked actions — each creates a first-class `Operation` row whose
    /// lifecycle is driven to completion (deadline, continuous, or relay event).
    public static let travel = OperationKind(rawValue: "travel")
    public static let mine   = OperationKind(rawValue: "mine")
    public static let print  = OperationKind(rawValue: "print")

    /// Compact for transport — the device packs itself down so it can be stowed
    /// and carried. Long-running and self-describing: both the POST response and
    /// the device's `compact` block report `completes_at`, so it's a tracked
    /// deadline op (like travel), completed by the settled-device path (or the
    /// deadline scheduler) once the device finishes compacting. Fires from the
    /// backend verb `compact`, so its `rawValue` matches `simple("compact")`.
    public static let compact = OperationKind(rawValue: "compact")

    /// Survey-drone belt search — the drone scours rocks until it locates a
    /// mining cluster (status `searching`, a `scan` activity block with an
    /// `eta_seconds` countdown). Tracked as a deadline op that completes when the
    /// site is found; the server announces that with a `scan_complete` relay event
    /// (the drone then *tracks* the site rather than settling to idle, so the
    /// event — not a settled status — is the completion signal).
    public static let search = OperationKind(rawValue: "search")

    /// Remove one queued print job by its position in the printer's `print_queue`
    /// (the active job is untouched). Immediate: the server drops the entry and
    /// answers with the updated queue, so it creates no tracked op.
    public static let dequeuePrint = OperationKind(rawValue: "dequeue_print")

    /// Immediate reads — the server answers synchronously with data, so they
    /// create no tracked operation (firing them never disturbs a running action).
    /// `scan` here is the heaven-vessel `system_scan` (a synchronous stellar read);
    /// the survey-drone body scan is the long-running `surveyScan` below.
    public static let scan   = OperationKind(rawValue: "scan")
    public static let census = OperationKind(rawValue: "census")

    /// Survey-drone body scan (`scan` command) — a long-running scan of the body
    /// at the drone's location that reports `completes_at` (deadline-tracked, like
    /// travel). Distinct from the immediate heaven-vessel `system_scan` and from
    /// belt `search`: all three differ only by the device status they drive
    /// (`scanning` vs `searching`), since a body scan and a belt search surface an
    /// identical `scan` activity block.
    public static let surveyScan = OperationKind(rawValue: "survey_scan")

    /// Mid-mining modifier — changes the active mining op's `resource_type` in
    /// place (server-gated on the device actually mining). Immediate.
    public static let retarget = OperationKind(rawValue: "retarget")
    /// Stow into the nearest carrier — status-only topology change. Immediate.
    public static let stow     = OperationKind(rawValue: "stow")

    /// Set an AMI controller's autonomous directive (e.g. a survey controller to
    /// `belt_search`, a mining controller to `gather_evenly`) — a synchronous
    /// configuration change gated on the device's `available_directives`.
    /// Immediate: the controller adopts the directive at once; no tracked op.
    public static let setDirective = OperationKind(rawValue: "set_directive")

    /// Adopt one or more worker devices under an AMI controller (mining drones
    /// under a mining controller, survey drones under a survey controller) so the
    /// controller's directive drives them. Immediate: a synchronous topology change
    /// that adds to the controller's `controlled_devices`; no tracked op.
    public static let adopt = OperationKind(rawValue: "adopt")

    /// Release one or more devices from an AMI controller, handing them back to
    /// direct control. The inverse of `adopt`; likewise an immediate topology
    /// change (removes from `controlled_devices`), no tracked op.
    public static let release = OperationKind(rawValue: "release")

    /// Attach one or more devices to a carrier (e.g. a surge plate) so they ride
    /// along when it moves between systems. The target(s) must be at the carrier's
    /// location. Immediate: a synchronous topology change (adds to the carrier's
    /// `attached_devices`); no tracked op.
    public static let attach = OperationKind(rawValue: "attach")

    /// Detach one or more devices from a carrier, releasing them at its current
    /// location. The inverse of `attach`; likewise an immediate topology change
    /// (removes from `attached_devices`), no tracked op.
    public static let detach = OperationKind(rawValue: "detach")

    /// A simple, parameter-less lifecycle command, identified by its backend
    /// verb (e.g. `deactivate`, `deploy`, `recall`). Status-only, completes at
    /// once; the body maps to the matching no-param command in `CommandClient`.
    public static func simple(_ command: String) -> OperationKind { OperationKind(rawValue: command) }
}

/// Which writer last touched an operation row (provenance for the §6 guard).
public enum OperationSource: String, Sendable, QueryBindable {
    case optimistic
    case event
    case poll
}

// MARK: - Schema

extension Operation {
    /// Registers the `operations` table migration plus the partial unique index
    /// that enforces at most one open operation per device.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'operations' table") { db in
            try #sql(
                """
                CREATE TABLE "operations" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "entityCode" TEXT NOT NULL,
                  "kind" TEXT NOT NULL,
                  "status" TEXT NOT NULL,
                  "source" TEXT NOT NULL,
                  "startedAt" TEXT NOT NULL,
                  "completesAt" TEXT,
                  "lastConfirmedAt" TEXT NOT NULL,
                  "detail" TEXT NOT NULL DEFAULT '{}'
                ) STRICT
                """
            )
            .execute(db)
            // One open operation per device. `optimistic` is intentionally not in
            // this set, so dispatch can stage a row without conflicting with the
            // op it may replace.
            try #sql(
                """
                CREATE UNIQUE INDEX "operation_one_open_per_device"
                  ON "operations" ("entityCode")
                  WHERE "status" IN ('enqueued', 'active')
                """
            )
            .execute(db)
        }
    }
}
