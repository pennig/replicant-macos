//
//  DirectiveRowTests.swift
//  Replicould — Directives feature
//
//  The unified list's merge: built-in rows derived from Device state (never
//  persisted) beside custom rows from the Directive table, in one stable order.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import DirectivesFeature

/// A device fixture. `detail` carries the in-force `ami_directive` block when
/// `directive` is set, mirroring what the backend sends.
private func device(
    code: String,
    type: String = "ami_survey_controller",
    directive: String? = nil,
    config: JSONValue? = nil,
    controlled: [JSONValue] = []
) -> Device {
    var detail: [String: JSONValue] = [:]
    if let directive {
        var block: [String: JSONValue] = ["name": .string(directive)]
        if let config { block["config"] = config }
        detail["ami_directive"] = .object(block)
    }
    if !controlled.isEmpty { detail["controlled_devices"] = .array(controlled) }
    return Device(
        deviceCode: code,
        deviceType: type,
        replicantCode: "R1",
        status: "idle",
        location: "ATIANFU-3",
        locationName: nil,
        operationalCapacity: 100,
        queueSize: 0,
        stowedInDeviceCode: nil,
        controllerDeviceCode: nil,
        attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [],
        features: [],
        tags: [],
        detail: .object(detail),
        updatedAt: Date(timeIntervalSince1970: 0),
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func mission(
    id: String,
    kind: DirectiveKind = .surveyRun,
    targets: [String] = ["TAU", "SHERATANON"],
    targetIndex: Int = 1
) -> Directive {
    Directive(
        id: id, kind: kind, status: .running, deviceCode: "VESSEL1",
        targets: targets, targetIndex: targetIndex, step: "surveying",
        stepStartedAt: Date(timeIntervalSince1970: 0),
        returnToOrigin: false, originDesignation: "SOL", attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite("Directive rows")
struct DirectiveRowTests {
    /// Only devices with a directive in force become built-in rows.
    @Test func derivesBuiltInRowsFromDevicesWithADirective() {
        let rows = DirectiveRow.merge(
            devices: [
                device(code: "AMI1", directive: "survey_system"),
                device(code: "AMI2"),
                device(code: "AMI3", directive: "gather_salvage"),
            ],
            directives: []
        )
        #expect(rows.count == 2)
        #expect(rows.map(\.deviceCode) == ["AMI1", "AMI3"])
    }

    /// A built-in row carries the config and controlled devices the detail pane
    /// renders, straight off the Device row.
    @Test func builtInRowCarriesConfigAndControlledDevices() {
        let rows = DirectiveRow.merge(
            devices: [device(
                code: "AMI1",
                directive: "survey_system",
                config: .object(["planets": .string("all"), "moons": .string("all")]),
                controlled: [.object([
                    "device_code": .string("DRONE1"),
                    "device_type": .string("survey_drone"),
                    "status": .string("tracking"),
                ])]
            )],
            directives: []
        )
        guard case let .builtIn(builtIn)? = rows.first else {
            Issue.record("expected a built-in row")
            return
        }
        #expect(builtIn.directive == "survey_system")
        #expect(builtIn.config?["planets"]?.stringValue == "all")
        #expect(builtIn.controlledDevices.map(\.deviceCode) == ["DRONE1"])
    }

    /// Custom rows sort as a whole block ahead of built-ins — not merely ahead of
    /// a single one — and each source's own internal ordering (the caller's,
    /// since the queries are already ordered) is preserved within its block.
    @Test func customRowsSortAheadOfBuiltIns() {
        let rows = DirectiveRow.merge(
            devices: [
                device(code: "AMI1", directive: "survey_system"),
                device(code: "AMI2", directive: "gather_salvage"),
            ],
            directives: [mission(id: "D1"), mission(id: "D2")]
        )
        #expect(rows.map(\.id) == ["custom:D1", "custom:D2", "builtin:AMI1", "builtin:AMI2"])
    }

    /// Row ids are stable and namespaced, so a device code and a directive id
    /// can never collide in the selection.
    @Test func rowIDsAreNamespaced() {
        let rows = DirectiveRow.merge(
            devices: [device(code: "X", directive: "patrol")],
            directives: [mission(id: "X")]
        )
        #expect(Set(rows.map(\.id)) == ["custom:X", "builtin:X"])
    }

    /// A custom row's title names the mission and its current target.
    @Test func customRowTitleNamesKindAndTarget() {
        let rows = DirectiveRow.merge(devices: [], directives: [mission(id: "D1")])
        #expect(rows.first?.title == "Survey Run → SHERATANON")
    }

    /// The headline splits so the view can render the designation half in a
    /// mono token — a single interpolated string forces one font on both.
    @Test func missionHeadlineSplitsOffTheDesignation() {
        let row = DirectiveRow.custom(mission(id: "D1"))
        #expect(row.headline == "Survey Run")
        #expect(row.headlineDesignation == "SHERATANON")
        #expect(row.title == "Survey Run → SHERATANON")
    }

    /// An exhausted queue has no current target, so there is no designation half.
    @Test func exhaustedMissionHasNoDesignation() {
        let row = DirectiveRow.custom(mission(id: "D1", targets: ["SOL"], targetIndex: 1))
        #expect(row.headline == "Survey Run")
        #expect(row.headlineDesignation == nil)
        #expect(row.title == "Survey Run")
    }

    /// A live mission driving a controller marks that controller's built-in row
    /// as engine-owned, so the pane can badge and lock it.
    @Test func liveMissionOwnsItsControllersBuiltInRow() {
        var driving = mission(id: "D1")
        driving.controllerCode = "AMI1"
        let rows = DirectiveRow.merge(
            devices: [device(code: "AMI1", directive: "survey_system")],
            directives: [driving]
        )
        let builtIns = rows.compactMap { row -> BuiltInDirective? in
            if case let .builtIn(builtIn) = row { return builtIn } else { return nil }
        }
        #expect(builtIns.count == 1)
        #expect(builtIns[0].drivenBy == DirectiveOwner(directiveID: "D1", kindTitle: "Survey Run"))
    }

    /// A finished mission releases its controller — the row is the user's again.
    @Test func finishedMissionDoesNotOwnItsController() {
        for status in [DirectiveStatus.completed, .cancelled] {
            var finished = mission(id: "D1")
            finished.controllerCode = "AMI1"
            finished.status = status
            let rows = DirectiveRow.merge(
                devices: [device(code: "AMI1", directive: "survey_system")],
                directives: [finished]
            )
            let builtIns = rows.compactMap { row -> BuiltInDirective? in
                if case let .builtIn(builtIn) = row { return builtIn } else { return nil }
            }
            #expect(builtIns[0].drivenBy == nil, "\(status) must not hold ownership")
        }
    }

    /// A paused or stalled mission KEEPS ownership: its directive is still in
    /// force server-side, and the user resolving the stall expects it intact.
    @Test func pausedAndStalledMissionsKeepOwnership() {
        for status in [DirectiveStatus.paused, .needsAttention] {
            var held = mission(id: "D1")
            held.controllerCode = "AMI1"
            held.status = status
            let rows = DirectiveRow.merge(
                devices: [device(code: "AMI1", directive: "survey_system")],
                directives: [held]
            )
            let builtIns = rows.compactMap { row -> BuiltInDirective? in
                if case let .builtIn(builtIn) = row { return builtIn } else { return nil }
            }
            #expect(builtIns[0].drivenBy != nil, "\(status) must hold ownership")
        }
    }

    /// A controller no mission is driving stays unowned — the common case, and
    /// the one a bug here would wrongly lock.
    @Test func unrelatedControllerIsUnowned() {
        var elsewhere = mission(id: "D1")
        elsewhere.controllerCode = "AMI9"
        let rows = DirectiveRow.merge(
            devices: [device(code: "AMI1", directive: "survey_system")],
            directives: [elsewhere]
        )
        let builtIns = rows.compactMap { row -> BuiltInDirective? in
            if case let .builtIn(builtIn) = row { return builtIn } else { return nil }
        }
        #expect(builtIns[0].drivenBy == nil)
    }

    /// A device whose `ami_directive.name` is present but EMPTY contributes no
    /// built-in row. The guard matters because an empty name would otherwise
    /// render a row with a blank headline and a Clear button that clears
    /// nothing.
    @Test func emptyDirectiveNameYieldsNoBuiltInRow() {
        let rows = DirectiveRow.merge(devices: [device(code: "AMI1", directive: "")], directives: [])
        #expect(rows.isEmpty)
    }

    /// A built-in row names a directive, never a place — so it has no
    /// designation half at all.
    @Test func builtInRowHasNoDesignation() {
        let row = DirectiveRow.merge(
            devices: [device(code: "AMI1", directive: "survey_system")],
            directives: []
        ).first
        #expect(row?.headlineDesignation == nil)
        #expect(row?.headline == row?.title)
    }
}
