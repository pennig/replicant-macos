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
    /// `OperationStatus.rawValue`.
    public var status: String
    /// `OperationSource.rawValue` — which writer last touched this row.
    public var source: String
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
        status: String,
        source: String,
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
public enum OperationStatus: String, Sendable, CaseIterable {
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

    /// The states the partial unique index treats as "one per device". Note this
    /// excludes `optimistic` by design.
    public var isOpen: Bool { self == .enqueued || self == .active }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .rejected, .superseded, .unknown: return true
        case .optimistic, .enqueued, .active: return false
        }
    }
}

/// The kind of action. `rawValue` is the backend `command` discriminator where
/// they align; `print` maps to the `enqueue_print` command.
public enum OperationKind: String, Sendable {
    case travel
    case mine
    case scan
    case census
    case print
}

/// Which writer last touched an operation row (provenance for the §6 guard).
public enum OperationSource: String, Sendable {
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
