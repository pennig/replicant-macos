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

    /// The pane's label. Without this the detail view renders the raw case name
    /// ("needsAttention") straight at the user.
    public var displayName: String {
        switch self {
        case .running: "Running"
        case .needsAttention: "Needs Attention"
        case .paused: "Paused"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        }
    }
}

/// Why a directive stalled into `.needsAttention`. A closed set (design spec
/// §8) — the engine pauses and surfaces rather than improvising, so every
/// stall it can produce has a name here.
public enum DirectiveAttentionReason: String, Codable, Equatable, Sendable, CaseIterable, QueryBindable {
    /// No relay is co-located with the vessel for a Relay Run step.
    case noRelayCoLocated
    /// No survey drone is aboard the vessel for a Survey Run step.
    case noSurveyDroneAboard
    /// No AMI survey controller is stowed aboard the vessel. Staging one is the
    /// player's job — a Survey Run uses what is already aboard and adopted, it
    /// never stows or adopts (adoption is persistent state that would outlive
    /// the mission).
    case noSurveyControllerAboard
    /// The device the step needs is unreachable (offline/unknown state).
    case unreachableDevice
    /// The `locations/{star}` backstop read disagrees with a completion event.
    case surveyIncomplete
    /// The server rejected the step's command.
    case commandRejected

    /// The stall panel's headline.
    public var displayName: String {
        switch self {
        case .noRelayCoLocated: "No relay aboard"
        case .noSurveyDroneAboard: "No survey drone aboard"
        case .noSurveyControllerAboard: "No survey controller aboard"
        case .unreachableDevice: "Device unreachable"
        case .surveyIncomplete: "Survey incomplete"
        case .commandRejected: "Command rejected"
        }
    }

    /// What the user can do about it. Staging is the player's job — a Survey Run
    /// never stows or adopts — so these name the fix rather than implying the
    /// engine will sort it out on its own.
    public var guidance: String {
        switch self {
        case .noRelayCoLocated:
            "Stow an FTL relay aboard the vessel, then retry."
        case .noSurveyDroneAboard:
            "Stow a survey drone aboard the vessel and adopt it with the controller, then retry."
        case .noSurveyControllerAboard:
            "Stow an AMI survey controller aboard the vessel, then retry."
        case .unreachableDevice:
            "The mission's device is missing from the fleet. Cancel the run, or retry once it's back."
        case .surveyIncomplete:
            "The controller reported finishing, but the system isn't fully scanned. Retry to keep waiting, or skip this target."
        case .commandRejected:
            "The server refused the last command. Check the device, then retry or skip this target."
        }
    }
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
    /// The AMI controller this mission is currently driving, once it has issued
    /// `set_directive` on one. Nil before that step, and after the mission
    /// clears it.
    ///
    /// This is what makes the resulting built-in row's ownership knowable: a
    /// server-run directive on `controllerCode` is the engine's own work, not
    /// something the user should Reconfigure or Clear out from under a step
    /// that is waiting on it. `deviceCode` cannot stand in for this — a Survey
    /// Run's vessel and its controller are two different devices.
    public var controllerCode: String?
    /// The ordered queue of star-system designations still to visit.
    @Column(as: [String].JSONRepresentation.self) public var targets: [String]
    /// How far through `targets` the run is. Equal to `targets.count` when done.
    public var targetIndex: Int
    /// The current step's identifier within the mission's step machine.
    ///
    /// Deliberately a bare `String`, not an enum: each `DirectiveKind` has its
    /// own step vocabulary (Survey Run's steps aren't Relay Run's), so there is
    /// no single closed set to type this against. Do not "fix" this.
    public var step: String
    /// When the current `step` began. Mirrors `Operation.startedAt`: the
    /// completion guard is `eventTime >= stepStartedAt - 5s`, issue-time
    /// relative rather than wall-clock relative, exactly like
    /// `Reconciler.completeOpenOperation` (design spec §5). Cannot be
    /// reconstructed from `DirectiveLogEntry` alone, hence its own column.
    public var stepStartedAt: Date
    /// Append a final leg home when the queue empties. Default off — the common
    /// case is chaining onward, and an unwanted return leg costs fuel and time.
    public var returnToOrigin: Bool
    /// The system the run started from, so `returnToOrigin` has a destination.
    public var originDesignation: String?
    /// Set only while `status == .needsAttention`.
    public var attentionReason: DirectiveAttentionReason?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        kind: DirectiveKind,
        status: DirectiveStatus,
        deviceCode: String,
        controllerCode: String? = nil,
        targets: [String],
        targetIndex: Int,
        step: String,
        stepStartedAt: Date,
        returnToOrigin: Bool,
        originDesignation: String?,
        attentionReason: DirectiveAttentionReason?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.deviceCode = deviceCode
        self.controllerCode = controllerCode
        self.targets = targets
        self.targetIndex = targetIndex
        self.step = step
        self.stepStartedAt = stepStartedAt
        self.returnToOrigin = returnToOrigin
        self.originDesignation = originDesignation
        self.attentionReason = attentionReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Progress through the queue, for the list row's "m/n" readout.
    public var progress: (completed: Int, total: Int) {
        (Swift.min(targetIndex, targets.count), targets.count)
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
    /// Which step (`Directive.step`) this entry belongs to, set for
    /// `.stepStarted` entries. Without this the only way to tell which step a
    /// timeline entry names is string-matching `summary`.
    public var step: String?
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
        step: String?,
        operationID: String?,
        eventID: String?,
        occurredAt: Date
    ) {
        self.id = id
        self.directiveID = directiveID
        self.deviceCode = deviceCode
        self.kind = kind
        self.summary = summary
        self.step = step
        self.operationID = operationID
        self.eventID = eventID
        self.occurredAt = occurredAt
    }
}

// MARK: - Schema

extension Directive {
    /// Registers the `directives` table migration. Kept beside the model so the
    /// schema and the type never drift.
    public static let createDirectives = SchemaMigration("Create 'directives' table") { db in
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
              "stepStartedAt" TEXT NOT NULL,
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

    /// A separate migration, not an edit to the one above: the original
    /// shipped 2026-07-25 and is already applied in real databases.
    public static let addControllerCode = SchemaMigration("Add 'controllerCode' to 'directives'") { db in
        try #sql(
            """
            ALTER TABLE "directives" ADD COLUMN "controllerCode" TEXT
            """
        )
        .execute(db)
    }

    /// Temporary shim so `GameDatabase` keeps compiling mid-conversion.
    /// Deleted in the manifest task.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        createDirectives.register(in: &migrator)
        addControllerCode.register(in: &migrator)
    }
}

extension DirectiveLogEntry {
    /// Registers the `directiveLogEntries` table migration.
    public static let createDirectiveLogEntries = SchemaMigration("Create 'directiveLogEntries' table") { db in
        try #sql(
            """
            CREATE TABLE "directiveLogEntries" (
              "id" TEXT PRIMARY KEY NOT NULL,
              "directiveID" TEXT,
              "deviceCode" TEXT,
              "kind" TEXT NOT NULL,
              "summary" TEXT NOT NULL DEFAULT '',
              "step" TEXT,
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
        // Replay immunity (design spec §6): the `directive.*` SSE route's
        // only job is writing one of these rows, and a replayed or
        // catch-up-redelivered event must not duplicate the timeline entry.
        // `eventID` is nullable (not every entry comes from an event), so
        // the uniqueness only applies where it's set.
        try #sql(
            """
            CREATE UNIQUE INDEX "directive_log_unique_event"
              ON "directiveLogEntries" ("eventID") WHERE "eventID" IS NOT NULL
            """
        )
        .execute(db)
    }

    /// Temporary shim so `GameDatabase` keeps compiling mid-conversion.
    /// Deleted in the manifest task.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        createDirectiveLogEntries.register(in: &migrator)
    }
}
