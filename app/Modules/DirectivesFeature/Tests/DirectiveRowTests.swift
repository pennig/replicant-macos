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
    controlled: [JSONValue] = [],
    tags: [String] = []
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
        tags: tags,
        detail: .object(detail),
        updatedAt: Date(timeIntervalSince1970: 0),
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

private func mission(
    id: String,
    kind: DirectiveKind = .surveyRun,
    status: DirectiveStatus = .running,
    targets: [String] = ["TAU", "SHERATANON"],
    targetIndex: Int = 1,
    roamCentre: String? = nil,
    fleetTag: String? = nil
) -> Directive {
    Directive(
        id: id, kind: kind, status: status, deviceCode: "VESSEL1",
        roamCentre: roamCentre, fleetTag: fleetTag,
        targets: targets, targetIndex: targetIndex, step: "surveying",
        stepStartedAt: Date(timeIntervalSince1970: 0),
        returnToOrigin: false, originDesignation: "SOL", attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

/// A tagged AMI transport controller, optionally running a haul config — the
/// only place a Haul Run's row subtitle can read what it is working from
/// (design spec §9; the run stores no assignment state of its own).
private func haulController(
    code: String = "HAUL1",
    collecting: String? = nil,
    directive: String = "ferry",
    deliver: String = "AINALRAM-BELT-1",
    tags: [String] = ["auto:haul"]
) -> Device {
    guard let collecting else {
        return device(code: code, type: "ami_transport_controller", tags: tags)
    }
    return device(
        code: code, type: "ami_transport_controller", directive: directive,
        config: .object(["collect": .string(collecting), "deliver": .string(deliver)]),
        tags: tags
    )
}

/// A Haul Run row: no queue, no `roamCentre`, nothing on the row to count.
private func haulRun(id: String = "H1", fleetTag: String? = nil) -> Directive {
    mission(id: id, kind: .haulRun, targets: [], targetIndex: 0, fleetTag: fleetTag)
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


// MARK: - Subtitle

/// The row's second line. Moved off `DirectiveRowView` onto `DirectiveRow` so it
/// can be tested at all — it was a private computed property on a SwiftUI View.
@Suite("Directive row subtitle")
struct DirectiveRowSubtitleTests {
    @Test func aFixedQueueRunCountsAgainstItsTotal() {
        let row = DirectiveRow.custom(
            mission(id: "D1", targets: ["A", "B", "C"], targetIndex: 1)
        )
        #expect(row.subtitle == "1/3")
    }

    /// A Relay Run is single-target and never advances the cursor, so a
    /// finished one carries `targetIndex == 0` and the row must still count
    /// its delivery.
    @Test func aCompletedSingleTargetRunReadsAsDelivered() {
        let row = DirectiveRow.custom(
            mission(id: "D1", kind: .relayRun, status: .completed, targets: ["NERVIU"], targetIndex: 0)
        )
        #expect(row.subtitle == "1/1")
    }

    @Test func aRunningSingleTargetRunHasDeliveredNothingYet() {
        let row = DirectiveRow.custom(
            mission(id: "D1", kind: .relayRun, status: .running, targets: ["NERVIU"], targetIndex: 0)
        )
        #expect(row.subtitle == "0/1")
    }

    /// The bug this branch exists for: a continuous run sits at
    /// `targetIndex == targets.count` between systems, so "n/n" would read as a
    /// finished run for most of its life.
    @Test func aContinuousRunCountsWhatItHasSurveyed() {
        let row = DirectiveRow.custom(
            mission(id: "D1", targets: ["A", "B"], targetIndex: 2, roamCentre: "ATIANFU")
        )
        #expect(row.subtitle == "2 surveyed")
    }

    @Test func aContinuousRunThatHasSurveyedNothingSaysSo() {
        let row = DirectiveRow.custom(
            mission(id: "D1", targets: [], targetIndex: 0, roamCentre: "ATIANFU")
        )
        #expect(row.subtitle == "0 surveyed")
    }

    /// A Salvage Run is continuous the same way a Survey Run is —
    /// `targetIndex == targets.count` for the whole window between systems —
    /// so it needs the same work-done readout, just its own verb and a plural
    /// that actually agrees with the count.
    @Test func aRoamingSalvageRunReportsWorkDoneNotMOverN() {
        let row = DirectiveRow.custom(
            mission(id: "D1", kind: .salvageRun, targets: ["TOSLIT", "WATTL"], targetIndex: 2, roamCentre: "AINALRAM")
        )
        #expect(row.subtitle == "2 systems drained")
    }

    /// The pluralisation the m/n branch never had to worry about: "1 system",
    /// not "1 systems".
    @Test func aSingleDrainedSystemIsNotPluralised() {
        let row = DirectiveRow.custom(
            mission(id: "D1", kind: .salvageRun, targets: ["TOSLIT"], targetIndex: 1, roamCentre: "AINALRAM")
        )
        #expect(row.subtitle == "1 system drained")
    }

    @Test func aRoamingSalvageRunThatHasDrainedNothingSaysSo() {
        let row = DirectiveRow.custom(
            mission(id: "D1", kind: .salvageRun, targets: [], targetIndex: 0, roamCentre: "AINALRAM")
        )
        #expect(row.subtitle == "0 systems drained")
    }

    @Test func aBuiltInRowWithNoDronesHasNoSubtitle() {
        let row = DirectiveRow.builtIn(
            BuiltInDirective(
                deviceCode: "AMI1", deviceType: "ami_survey_controller",
                directive: "survey_system", config: nil,
                controlledDevices: [], drivenBy: nil
            )
        )
        #expect(row.subtitle == nil)
    }

    @Test func aDrivenBuiltInRowNamesTheMission() {
        let row = DirectiveRow.builtIn(
            BuiltInDirective(
                deviceCode: "AMI1", deviceType: "ami_survey_controller",
                directive: "survey_system", config: nil,
                controlledDevices: [],
                drivenBy: DirectiveOwner(directiveID: "D1", kindTitle: "Survey Run")
            )
        )
        #expect(row.subtitle == "driven by Survey Run")
    }

    // MARK: Haul Run

    /// **IMPORTANT regression guard (2026-07-31 final review).** A Haul Run has
    /// `roamCentre == nil` and `targets == []`, so both progress readouts above
    /// resolve to `0/0` — forever, on the only surface that could tell a working
    /// run from an idled one. Spec §9: "the row subtitle names the work in
    /// flight rather than a count… read from the controllers' own in-force
    /// config. A count of drained piles is deliberately not offered."
    @Test func aHaulRunNamesTheWorkInFlightRatherThanACount() {
        let rows = DirectiveRow.merge(
            devices: [haulController(collecting: "ATIANFU-BELT-1")],
            directives: [haulRun()]
        )
        let row = rows.first
        #expect(row?.subtitle == "Hauling")
        #expect(row?.subtitle != "0/0")
        // The designation rides the headline, which is the half rendered in a
        // mono token (`.rcBodyEmphMono`) — a location designation must never
        // land in the `.rcCaption` subtitle (house rule).
        #expect(row?.headlineDesignation == "ATIANFU-BELT-1")
        #expect(row?.title == "Haul Run → ATIANFU-BELT-1")
    }

    /// The complement, and the state `0/0` made invisible: nothing reachable.
    @Test func aHaulRunWithNoControllerHoldingAHaulConfigSaysNothingReachable() {
        let rows = DirectiveRow.merge(
            devices: [haulController()],
            directives: [haulRun()]
        )
        #expect(rows.first?.subtitle == "Nothing reachable")
        #expect(rows.first?.headlineDesignation == nil)
        #expect(rows.first?.title == "Haul Run")
    }

    /// The tag is the operator's opt-in, so an untagged controller — however
    /// busy — is not this run's work and must not be reported as it.
    @Test func aHaulRunIgnoresAnUntaggedController() {
        let rows = DirectiveRow.merge(
            devices: [haulController(collecting: "ATIANFU-BELT-1", tags: [])],
            directives: [haulRun()]
        )
        #expect(rows.first?.subtitle == "Nothing reachable")
    }

    /// A `shuttle` — the in-system half of the same supply line — counts as
    /// work in flight exactly as `ferry` does.
    @Test func aHaulRunReportsAShuttleAsWorkInFlight() {
        let rows = DirectiveRow.merge(
            devices: [haulController(collecting: "AINALRAM-2", directive: "shuttle")],
            directives: [haulRun()]
        )
        #expect(rows.first?.headlineDesignation == "AINALRAM-2")
        #expect(rows.first?.subtitle == "Hauling")
    }

    /// A controller delivering somewhere ELSE is not doing this run's work —
    /// the same `deliver` check `confirming` makes, so the row and the machine
    /// cannot disagree about what counts.
    @Test func aHaulRunIgnoresAControllerDeliveringElsewhere() {
        let rows = DirectiveRow.merge(
            devices: [haulController(collecting: "ATIANFU-BELT-1", deliver: "SHERATANON-6-1")],
            directives: [haulRun()]
        )
        #expect(rows.first?.subtitle == "Nothing reachable")
    }

    /// A row carrying its own fleet tag resolves against THAT tag, exactly as
    /// the machine resolves its working set on every evaluation.
    @Test func aHaulRunHonoursItsOwnFleetTag() {
        let rows = DirectiveRow.merge(
            devices: [
                haulController(code: "HAUL1", collecting: "ATIANFU-BELT-1", tags: ["auto:haul"]),
                haulController(code: "HAUL2", collecting: "AINALRAM-2", tags: ["auto:haul-b"]),
            ],
            directives: [haulRun(fleetTag: "auto:haul-b")]
        )
        #expect(rows.first?.headlineDesignation == "AINALRAM-2")
    }

    /// Several controllers on different piles: name the lowest-coded one's, so
    /// the row is stable across evaluations rather than flickering with
    /// dictionary order.
    @Test func aHaulRunNamesTheLowestCodedControllersPile() {
        let rows = DirectiveRow.merge(
            devices: [
                haulController(code: "HAUL2", collecting: "AINALRAM-2"),
                haulController(code: "HAUL1", collecting: "ATIANFU-BELT-1"),
            ],
            directives: [haulRun()]
        )
        #expect(rows.first?.headlineDesignation == "ATIANFU-BELT-1")
    }
}
