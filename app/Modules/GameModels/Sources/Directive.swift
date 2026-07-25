//
//  Directive.swift
//  Replicould — Directives feature
//
//  A custom directive (a multi-step mission the app executes) and the shared
//  audit trail both directive kinds write to. Built-in AMI directives get NO
//  row here on purpose: the server owns that state and it is already carried on
//  the `Device` row (`ami_directive`), so mirroring it locally would invent a
//  drift bug. `DirectiveLogEntry` is the one thing both kinds share — hence its
//  optional `directiveID` (custom) / `deviceCode` (built-in) pair.
//
//  Both tables are account-scoped and wiped on logout (see
//  `ReplicantApp.registerSessionCleanup`).
//

import Foundation
import SQLiteData

/// Which baked-in procedure a custom directive runs.
public enum DirectiveKind: String, Codable, Equatable, Sendable, CaseIterable, QueryBindable {
    case surveyRun
    case relayRun

    /// The list row's label, e.g. "Survey Run".
    public var title: String {
        switch self {
        case .surveyRun: "Survey Run"
        case .relayRun: "Relay Run"
        }
    }
}

/// A custom directive's lifecycle state. `needsAttention` is the pause-and-surface
/// stall state — the engine never improvises or auto-retries at the mission layer.
public enum DirectiveStatus: String, Codable, Equatable, Sendable, CaseIterable, QueryBindable {
    case running
    case needsAttention
    case paused
    case completed
    case cancelled
}

/// One custom mission instance. Policy-ready by design: nothing here records
/// whether a click or a future standing policy created the row.
@Table
public struct Directive: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var id: String
    public var kind: DirectiveKind
    public var status: DirectiveStatus
    /// The vessel carrying out the mission.
    public var deviceCode: String
    /// The ordered queue of star-system designations still to visit.
    @Column(as: [String].JSONRepresentation.self) public var targets: [String]
    /// How far through `targets` the run is. Equal to `targets.count` when done.
    public var targetIndex: Int
    /// The current step's identifier within the mission's step machine.
    public var step: String
    /// Append a final leg home when the queue empties. Default off — the common
    /// case is chaining onward, and an unwanted return leg costs fuel and time.
    public var returnToOrigin: Bool
    /// The system the run started from, so `returnToOrigin` has a destination.
    public var originDesignation: String?
    /// Set only while `status == .needsAttention`.
    public var attentionReason: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        kind: DirectiveKind,
        status: DirectiveStatus,
        deviceCode: String,
        targets: [String],
        targetIndex: Int,
        step: String,
        returnToOrigin: Bool,
        originDesignation: String?,
        attentionReason: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.deviceCode = deviceCode
        self.targets = targets
        self.targetIndex = targetIndex
        self.step = step
        self.returnToOrigin = returnToOrigin
        self.originDesignation = originDesignation
        self.attentionReason = attentionReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Progress through the queue, for the list row's "m/n" readout.
    public var progress: (completed: Int, total: Int) {
        (min(targetIndex, targets.count), targets.count)
    }

    /// The target currently being worked, or nil when the queue is exhausted.
    public var currentTarget: String? {
        targets.indices.contains(targetIndex) ? targets[targetIndex] : nil
    }
}

/// What a log entry records.
public enum DirectiveLogKind: String, Codable, Equatable, Sendable, CaseIterable, QueryBindable {
    case stepStarted
    case commandDispatched
    case opCompleted
    case directiveCompleted
    case stalled
    case resolved
}

/// One audit-trail entry. Feeds the custom detail pane's live step timeline and
/// the built-in detail pane's completion history.
@Table
public struct DirectiveLogEntry: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var id: String
    /// Set for a custom mission's entry.
    public var directiveID: String?
    /// Set for a built-in AMI directive's entry (keyed by the controller).
    public var deviceCode: String?
    public var kind: DirectiveLogKind
    /// The human-readable line shown in the timeline.
    public var summary: String
    /// The op this entry created or closed, when there is one.
    public var operationID: String?
    /// The SSE event that produced this entry, when there is one.
    public var eventID: String?
    public var occurredAt: Date

    public init(
        id: String,
        directiveID: String?,
        deviceCode: String?,
        kind: DirectiveLogKind,
        summary: String,
        operationID: String?,
        eventID: String?,
        occurredAt: Date
    ) {
        self.id = id
        self.directiveID = directiveID
        self.deviceCode = deviceCode
        self.kind = kind
        self.summary = summary
        self.operationID = operationID
        self.eventID = eventID
        self.occurredAt = occurredAt
    }
}

// MARK: - Schema

extension Directive {
    /// Registers the `directives` table migration. Kept beside the model so the
    /// schema and the type never drift.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'directives' table") { db in
            try #sql(
                """
                CREATE TABLE "directives" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "kind" TEXT NOT NULL,
                  "status" TEXT NOT NULL,
                  "deviceCode" TEXT NOT NULL DEFAULT '',
                  "targets" TEXT NOT NULL DEFAULT '[]',
                  "targetIndex" INTEGER NOT NULL DEFAULT 0,
                  "step" TEXT NOT NULL DEFAULT '',
                  "returnToOrigin" INTEGER NOT NULL DEFAULT 0,
                  "originDesignation" TEXT,
                  "attentionReason" TEXT,
                  "createdAt" TEXT NOT NULL,
                  "updatedAt" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}

extension DirectiveLogEntry {
    /// Registers the `directiveLogEntries` table migration.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'directiveLogEntries' table") { db in
            try #sql(
                """
                CREATE TABLE "directiveLogEntries" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "directiveID" TEXT,
                  "deviceCode" TEXT,
                  "kind" TEXT NOT NULL,
                  "summary" TEXT NOT NULL DEFAULT '',
                  "operationID" TEXT,
                  "eventID" TEXT,
                  "occurredAt" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
            // The timeline reads are always "entries for one directive" or
            // "entries for one device", newest last.
            try #sql(
                """
                CREATE INDEX "directive_log_by_directive"
                  ON "directiveLogEntries" ("directiveID", "occurredAt")
                """
            )
            .execute(db)
            try #sql(
                """
                CREATE INDEX "directive_log_by_device"
                  ON "directiveLogEntries" ("deviceCode", "occurredAt")
                """
            )
            .execute(db)
        }
    }
}
