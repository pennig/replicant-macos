//
//  DirectiveTargetsSectionTests.swift
//  Replicould — Directives feature
//
//  The detail pane's queue-shaped section: one branch per run shape, and the
//  two readouts a raw target checklist gets wrong (a roam, and a Haul Run).
//

import DirectiveEngine
import Foundation
import GameModels
import Testing
import Utils
@testable import DirectivesFeature

/// A haul controller fixture: `available_directives` carries `ferry`, and the
/// in-force `ami_directive` block carries the pile it drains.
private func controller(
    code: String,
    tags: [String] = [HaulRun.defaultFleetTag],
    collecting: String? = nil,
    delivering: String = HaulRun.deliveryLocation,
    directive: String = "ferry"
) -> Device {
    var detail: [String: JSONValue] = [
        "available_directives": .array([.string("ferry")]),
    ]
    if let collecting {
        detail["ami_directive"] = .object([
            "name": .string(directive),
            "config": .object([
                "collect": .string(collecting),
                "deliver": .string(delivering),
            ]),
        ])
    }
    return Device(
        deviceCode: code,
        deviceType: "ami_transport_controller",
        replicantCode: "R1",
        status: "idle",
        location: "AINALRAM-BELT-1",
        locationName: nil,
        operationalCapacity: 100,
        queueSize: 0,
        stowedInDeviceCode: nil,
        controllerDeviceCode: nil,
        attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [],
        features: [],
        tags: tags,
        detail: .object(detail),
        updatedAt: Date(timeIntervalSince1970: 0),
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func run(
    kind: DirectiveKind,
    status: DirectiveStatus = .running,
    deviceCode: String = "VESSEL1",
    targets: [String] = [],
    targetIndex: Int = 0,
    roamCentre: String? = nil,
    fleetTag: String? = nil
) -> Directive {
    Directive(
        id: "D1", kind: kind, status: status, deviceCode: deviceCode,
        roamCentre: roamCentre, fleetTag: fleetTag,
        targets: targets, targetIndex: targetIndex, step: "surveying",
        stepStartedAt: Date(timeIntervalSince1970: 0),
        returnToOrigin: false, originDesignation: "SOL", attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("Directive targets section")
struct DirectiveTargetsSectionTests {
    /// A hand-picked queue keeps the checklist, marks delivered by position,
    /// and keys by position — the same designation may legitimately repeat.
    @Test func aBoundedRunKeepsItsChecklist() {
        let directive = run(kind: .salvageRun, targets: ["TAU", "SOL", "TAU"], targetIndex: 2)
        guard case let .queue(stops) = DirectiveTargetsSection.section(for: directive, devices: [])
        else { return #expect(Bool(false), "expected a queue") }
        #expect(stops.map(\.designation) == ["TAU", "SOL", "TAU"])
        #expect(stops.map(\.delivered) == [true, true, false])
        #expect(stops.map(\.id) == [0, 1, 2])
    }

    /// A roam reports coverage instead: the live target, a count, and a
    /// newest-first trail — never a list of ticked boxes with no end.
    @Test func aRoamReportsCoverageNotAChecklist() {
        let directive = run(
            kind: .surveyRun,
            targets: ["A", "B", "C", "D"],
            targetIndex: 3,
            roamCentre: "SOL"
        )
        guard case let .coverage(coverage) = DirectiveTargetsSection.section(for: directive, devices: [])
        else { return #expect(Bool(false), "expected coverage") }
        #expect(coverage.centre == "SOL")
        #expect(coverage.current == "D")
        #expect(coverage.charted == 3)
        #expect(coverage.recent == ["C", "B", "A"])
        #expect(coverage.earlier == 0)
    }

    /// A Salvage roam reports coverage but names no centre: its planner takes
    /// none, ranking by mesh membership, units, then distance from the vessel.
    @Test func aSalvageRoamNamesNoCentre() {
        let directive = run(
            kind: .salvageRun,
            targets: ["A", "B"],
            targetIndex: 1,
            roamCentre: "SOL"
        )
        guard case let .coverage(coverage) = DirectiveTargetsSection.section(for: directive, devices: [])
        else { return #expect(Bool(false), "expected coverage") }
        #expect(coverage.centre == nil)
        #expect(coverage.charted == 1)
        #expect(coverage.current == "B")
    }

    /// The trail is capped, and what it leaves out is counted rather than
    /// dropped — this is the growth the raw checklist had no answer for.
    @Test func aLongRoamCapsTheTrailAndCountsTheRest() {
        let charted = (1...50).map { "S\($0)" }
        let directive = run(
            kind: .surveyRun,
            targets: charted + ["LIVE"],
            targetIndex: 50,
            roamCentre: "SOL"
        )
        guard case let .coverage(coverage) = DirectiveTargetsSection.section(for: directive, devices: [])
        else { return #expect(Bool(false), "expected coverage") }
        #expect(coverage.charted == 50)
        #expect(coverage.recent == ["S50", "S49", "S48", "S47", "S46"])
        #expect(coverage.earlier == 45)
    }

    /// A completed roam counts the system it finished last. `targetIndex` alone
    /// would leave it out, since a run only moves the cursor to move ON.
    @Test func aCompletedRoamCountsItsLastSystem() {
        let directive = run(
            kind: .surveyRun,
            status: .completed,
            targets: ["A", "B"],
            targetIndex: 1,
            roamCentre: "SOL"
        )
        guard case let .coverage(coverage) = DirectiveTargetsSection.section(for: directive, devices: [])
        else { return #expect(Bool(false), "expected coverage") }
        #expect(coverage.charted == 2)
        #expect(coverage.recent == ["B", "A"])
        #expect(coverage.current == nil)
    }

    /// A Haul Run has no queue at all — it reports which controller drains
    /// which pile, which is the one readout that tells a working fleet from a
    /// mispointed one.
    @Test func aHaulRunReportsFleetAssignments() {
        let devices = [
            controller(code: "HAUL2", collecting: "TAU-4"),
            controller(code: "HAUL1", collecting: "SOL-3"),
        ]
        let directive = run(kind: .haulRun)
        guard case let .assignments(_, assignments) = DirectiveTargetsSection.section(for: directive, devices: devices)
        else { return #expect(Bool(false), "expected assignments") }
        #expect(assignments.map(\.controllerCode) == ["HAUL1", "HAUL2"])
        #expect(assignments.map(\.collecting) == ["SOL-3", "TAU-4"])
    }

    /// A controller that has taken no config this run could have issued reads
    /// as unassigned rather than borrowing whatever config it does carry.
    @Test func anUnassignedControllerReportsNoPile() {
        let devices = [
            controller(code: "HAUL1"),
            controller(code: "HAUL2", collecting: "SOL-3", delivering: "ELSEWHERE"),
        ]
        let directive = run(kind: .haulRun)
        guard case let .assignments(_, assignments) = DirectiveTargetsSection.section(for: directive, devices: devices)
        else { return #expect(Bool(false), "expected assignments") }
        #expect(assignments.map(\.collecting) == [nil, nil])
    }

    /// Only the run's own fleet tag counts — an untagged controller has been
    /// taken back by the operator.
    @Test func assignmentsHonourTheRunsFleetTag() {
        let devices = [
            controller(code: "HAUL1", tags: ["auto:other"], collecting: "SOL-3"),
            controller(code: "HAUL2", tags: ["auto:other"], collecting: "TAU-4"),
        ]
        let directive = run(kind: .haulRun, fleetTag: "auto:other")
        guard case let .assignments(_, assignments) = DirectiveTargetsSection.section(for: directive, devices: devices)
        else { return #expect(Bool(false), "expected assignments") }
        #expect(assignments.count == 2)
        #expect(DirectiveTargetsSection.section(for: run(kind: .haulRun), devices: devices) == .empty)
    }

    /// A pinned per-mine row is resolved by `deviceCode`: its per-belt tag is
    /// worn by nothing, so the tag query would draw no section over a ferry
    /// that is hauling — the same blindness the list row carried.
    @Test func aPinnedHaulRunReportsItsOwnFerry() {
        let devices = [
            controller(code: "FERRY1", tags: ["auto:mine"], collecting: "ACHERNUR-BELT-1"),
            controller(code: "HAUL1", collecting: "SOL-3"),
        ]
        let directive = run(
            kind: .haulRun, deviceCode: "FERRY1",
            targets: ["ACHERNUR-BELT-1"], fleetTag: "auto:mine:ACHERNUR-BELT-1"
        )
        guard case let .assignments(_, assignments) = DirectiveTargetsSection.section(for: directive, devices: devices)
        else { return #expect(Bool(false), "expected assignments") }
        #expect(assignments.map(\.controllerCode) == ["FERRY1"])
        #expect(assignments.map(\.collecting) == ["ACHERNUR-BELT-1"])
    }

    /// The empty "Targets" header the pane used to draw over a Haul Run is now
    /// no section at all.
    @Test func aHaulRunWithNoFleetDrawsNoSection() {
        #expect(DirectiveTargetsSection.section(for: run(kind: .haulRun), devices: []) == .empty)
        #expect(DirectiveTargetsSection.section(for: run(kind: .haulRun), devices: []).title == nil)
    }

    /// A Restock Run's targets are the demand it prints against, not a route,
    /// so they carry no delivery marks.
    @Test func aRestockRunReportsDemand() {
        let directive = run(kind: .restockRun, targets: ["TAU", "SOL"])
        #expect(
            DirectiveTargetsSection.section(for: directive, devices: [])
                == .demand(["TAU", "SOL"])
        )
    }

    /// Section titles, which is what stops a Haul Run being headed "Targets".
    @Test func titlesFollowTheShape() {
        #expect(DirectiveTargetsSection.queue([]).title == "Targets")
        #expect(DirectiveTargetsSection.assignments(delivering: "X", []).title == "Assignments")
        #expect(DirectiveTargetsSection.demand([]).title == "Demand")
        #expect(DirectiveTargetsSection.empty.title == nil)
    }
}
