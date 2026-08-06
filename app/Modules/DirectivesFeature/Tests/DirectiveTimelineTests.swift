//
//  DirectiveTimelineTests.swift
//  Replicould — Directives feature
//
//  One query, two row kinds — the payoff for `DirectiveLogEntry`'s optional
//  directiveID/deviceCode pair (design spec §2).
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import DirectivesFeature

private func entry(
    _ id: String,
    directiveID: String? = nil,
    deviceCode: String? = nil,
    kind: DirectiveLogKind = .stepStarted,
    at seconds: TimeInterval
) -> DirectiveLogEntry {
    DirectiveLogEntry(
        id: id, directiveID: directiveID, deviceCode: deviceCode, kind: kind,
        summary: "entry \(id)", step: nil, operationID: nil, eventID: nil,
        occurredAt: Date(timeIntervalSince1970: seconds)
    )
}

@Suite("Directive timeline")
struct DirectiveTimelineTests {
    /// A custom mission's timeline is its own entries, newest first — the end
    /// the user is watching stays at the top.
    @Test func customTimelineIsNewestFirst() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert { entry("L1", directiveID: "D1", at: 10) }.execute(db)
            try DirectiveLogEntry.insert { entry("L2", directiveID: "D1", at: 30) }.execute(db)
            try DirectiveLogEntry.insert { entry("L3", directiveID: "D1", at: 20) }.execute(db)
        }
        let value = try await database.read { db in
            try DirectiveTimeline(directiveID: "D1", deviceCode: nil).fetch(db)
        }
        #expect(value.entries.map(\.id) == ["L2", "L3", "L1"])
    }

    /// Another mission's entries never leak in.
    @Test func customTimelineExcludesOtherMissions() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert { entry("L1", directiveID: "D1", at: 10) }.execute(db)
            try DirectiveLogEntry.insert { entry("L2", directiveID: "D2", at: 20) }.execute(db)
        }
        let value = try await database.read { db in
            try DirectiveTimeline(directiveID: "D1", deviceCode: nil).fetch(db)
        }
        #expect(value.entries.map(\.id) == ["L1"])
    }

    /// A built-in row's history is keyed by DEVICE — the completion entries the
    /// `directive.*` route writes.
    @Test func builtInHistoryIsKeyedByDevice() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                entry("L1", deviceCode: "AMI1", kind: .directiveCompleted, at: 10)
            }.execute(db)
            try DirectiveLogEntry.insert {
                entry("L2", deviceCode: "AMI2", kind: .directiveCompleted, at: 20)
            }.execute(db)
        }
        let value = try await database.read { db in
            try DirectiveTimeline(directiveID: nil, deviceCode: "AMI1").fetch(db)
        }
        #expect(value.entries.map(\.id) == ["L1"])
    }

    /// A completion attributed to a mission AND its controller appears in both
    /// timelines — the route sets both keys on purpose.
    @Test func attributedCompletionAppearsInBothTimelines() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                entry("L1", directiveID: "D1", deviceCode: "AMI1", kind: .directiveCompleted, at: 10)
            }.execute(db)
        }
        let mission = try await database.read { db in
            try DirectiveTimeline(directiveID: "D1", deviceCode: nil).fetch(db)
        }
        let controller = try await database.read { db in
            try DirectiveTimeline(directiveID: nil, deviceCode: "AMI1").fetch(db)
        }
        #expect(mission.entries.map(\.id) == ["L1"])
        #expect(controller.entries.map(\.id) == ["L1"])
    }

    /// A mission's own step entries never leak into the controller's history,
    /// even though they now carry its device code.
    ///
    /// `MissionAction.assignController` stamps the claimed controller onto the
    /// `.stepStarted` entry it writes (so a re-entry budget can be scoped to one
    /// controller), which means a Survey/Salvage/Haul Run's step transitions
    /// carry BOTH keys. They are the mission's progress, not the controller's
    /// completion history — "Step: dispatching" under a built-in AMI directive
    /// would read as that device's own work, and at one entry per transition
    /// they would push real completions past `entryLimit`.
    @Test func builtInHistoryExcludesMissionStepEntries() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert {
                entry("L1", deviceCode: "AMI1", kind: .directiveCompleted, at: 10)
            }.execute(db)
            try DirectiveLogEntry.insert {
                entry("L2", directiveID: "D1", deviceCode: "AMI1", kind: .stepStarted, at: 20)
            }.execute(db)
        }
        let mission = try await database.read { db in
            try DirectiveTimeline(directiveID: "D1", deviceCode: nil).fetch(db)
        }
        let controller = try await database.read { db in
            try DirectiveTimeline(directiveID: nil, deviceCode: "AMI1").fetch(db)
        }
        #expect(mission.entries.map(\.id) == ["L2"], "the step belongs to the mission")
        #expect(controller.entries.map(\.id) == ["L1"], "and never to the device's history")
    }

    /// Nothing selected fetches nothing — never the whole table.
    @Test func emptyRequestFetchesNothing() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try DirectiveLogEntry.insert { entry("L1", directiveID: "D1", at: 10) }.execute(db)
        }
        let value = try await database.read { db in
            try DirectiveTimeline(directiveID: nil, deviceCode: nil).fetch(db)
        }
        #expect(value.entries.isEmpty)
    }

    /// The newest `rawFetchLimit` entries are kept — a long multi-target run
    /// is otherwise unbounded.
    @Test func capsToTheNewestEntries() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            for index in 0..<(DirectiveTimeline.rawFetchLimit + 10) {
                try DirectiveLogEntry.insert {
                    entry("L\(index)", directiveID: "D1", at: TimeInterval(index))
                }.execute(db)
            }
        }
        let value = try await database.read { db in
            try DirectiveTimeline(directiveID: "D1", deviceCode: nil).fetch(db)
        }
        #expect(value.entries.count == DirectiveTimeline.rawFetchLimit)
        #expect(value.entries.first?.id == "L\(DirectiveTimeline.rawFetchLimit + 9)", "newest kept")
    }

    /// `request(for:)` maps each row kind to the right key, so no caller has to
    /// remember which id goes in which slot.
    @Test func requestMapsRowKinds() {
        let mission = Directive(
            id: "D1", kind: .surveyRun, status: .running, deviceCode: "VES1",
            targets: ["TAU"], targetIndex: 0, step: "preflight",
            stepStartedAt: Date(timeIntervalSince1970: 0), returnToOrigin: false,
            originDesignation: nil, attentionReason: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        let custom = DirectiveTimeline.request(for: .custom(mission))
        #expect(custom.directiveID == "D1")
        #expect(custom.deviceCode == nil)

        let builtIn = DirectiveTimeline.request(for: .builtIn(
            BuiltInDirective(deviceCode: "AMI1", deviceType: "ami_survey_controller",
                             directive: "survey_system", config: nil, controlledDevices: [])
        ))
        #expect(builtIn.directiveID == nil)
        #expect(builtIn.deviceCode == "AMI1")

        let none = DirectiveTimeline.request(for: nil)
        #expect(none.directiveID == nil)
        #expect(none.deviceCode == nil)
    }
}
