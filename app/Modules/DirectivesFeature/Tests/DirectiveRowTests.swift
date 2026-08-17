//
//  DirectiveRowTests.swift
//  Replicould — Directives feature
//
//  The unified list's merge: built-in rows derived from Device state (never
//  persisted) beside custom rows from the Directive table, in one stable order.
//

import DirectiveEngine
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
    tags: [String] = [],
    location: String = "ATIANFU-3"
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
        location: location,
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

/// The depot every haul fixture is stamped for — and so the sink a controller
/// must name to read as doing this run's work.
private let haulDepot = "AINALRAM-BELT-1"

private func mission(
    id: String,
    kind: DirectiveKind = .surveyRun,
    status: DirectiveStatus = .running,
    deviceCode: String = "VESSEL1",
    controllerCode: String? = nil,
    targets: [String] = ["TAU", "SHERATANON"],
    targetIndex: Int = 1,
    roamCentre: String? = nil,
    fleetTag: String? = nil,
    theatreDepot: String? = haulDepot
) -> Directive {
    Directive(
        id: id, kind: kind, status: status, deviceCode: deviceCode,
        controllerCode: controllerCode,
        roamCentre: roamCentre, fleetTag: fleetTag,
        targets: targets, targetIndex: targetIndex, step: "surveying",
        stepStartedAt: Date(timeIntervalSince1970: 0),
        returnToOrigin: false, originDesignation: "SOL", attentionReason: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        theatreDepot: theatreDepot
    )
}

/// A tagged AMI transport controller, optionally running a haul config — the
/// only place a Haul Run's row subtitle can read what it is working from
/// (design spec §9; the run stores no assignment state of its own).
private func haulController(
    code: String = "HAUL1",
    collecting: String? = nil,
    directive: String = "ferry",
    deliver: String = haulDepot,
    tags: [String] = ["auto:haul"],
    location: String = "ATIANFU-3"
) -> Device {
    guard let collecting else {
        return device(code: code, type: "ami_transport_controller", tags: tags, location: location)
    }
    return device(
        code: code, type: "ami_transport_controller", directive: directive,
        config: .object(["collect": .string(collecting), "deliver": .string(deliver)]),
        tags: tags, location: location
    )
}

/// A Haul Run row: no queue, no `roamCentre`, nothing on the row to count.
private func haulRun(
    id: String = "H1", fleetTag: String? = nil, theatreDepot: String? = haulDepot
) -> Directive {
    mission(
        id: id, kind: .haulRun, targets: [], targetIndex: 0,
        fleetTag: fleetTag, theatreDepot: theatreDepot
    )
}

/// A per-mine ferry row: pinned to one belt through `targets.first`, driving
/// its own `deviceCode`. Its fleet tag is per-belt and worn by no device.
private func pinnedHaulRun(
    id: String = "H2", belt: String = "ACHERNUR-BELT-1", ferry: String = "FERRY1"
) -> Directive {
    mission(
        id: id, kind: .haulRun, deviceCode: ferry, controllerCode: ferry,
        targets: [belt], targetIndex: 0, fleetTag: "auto:mine:\(belt)"
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
        #expect(builtIns[0].drivenBy == DirectiveOwner(holder: .mission(id: "D1"), title: "Survey Run"))
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
                drivenBy: DirectiveOwner(holder: .mission(id: "D1"), title: "Survey Run")
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
                haulController(
                    code: "HAUL1", collecting: "ATIANFU-BELT-1", tags: ["auto:haul:ATIANFU-3"]
                ),
                haulController(
                    code: "HAUL2", collecting: "AINALRAM-2", tags: ["auto:haul:AINALRAM-9"]
                ),
            ],
            directives: [haulRun(fleetTag: "auto:haul:AINALRAM-9")]
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

    /// The sink is the row's own stamp, never a fixed depot: an unstamped row
    /// delivers nowhere the list can name, so no pile is claimed for it.
    @Test func anUnstampedHaulRunClaimsNoPile() {
        let rows = DirectiveRow.merge(
            devices: [haulController(collecting: "ATIANFU-BELT-1")],
            directives: [haulRun(theatreDepot: nil)]
        )
        #expect(rows.first?.headlineDesignation == nil)
        #expect(rows.first?.subtitle == "Nothing reachable")
    }

    /// A second theatre's run reads against ITS depot — the two must not both
    /// claim a controller delivering to only one of them.
    @Test func aHaulRunReadsAgainstItsOwnDepot() {
        let devices = [haulController(collecting: "ATIANFU-BELT-1", deliver: "DENEBED-BELT-1")]
        #expect(
            DirectiveRow.merge(devices: devices, directives: [haulRun(theatreDepot: "DENEBED-BELT-1")])
                .first?.headlineDesignation == "ATIANFU-BELT-1"
        )
        #expect(DirectiveRow.merge(devices: devices, directives: [haulRun()]).first?.headlineDesignation == nil)
    }

    // MARK: Pinned Haul Run

    /// A per-mine ferry row is driven by `deviceCode`, never by its tag: the
    /// per-belt tag is worn by NO device, so the tag lookup the general drainer
    /// uses is structurally blind to it and reported "Nothing reachable" about
    /// a ferry that was hauling.
    @Test func aPinnedHaulRunNamesItsBeltWhileTheFerryIsInForce() {
        let rows = DirectiveRow.merge(
            devices: [haulController(
                code: "FERRY1", collecting: "ACHERNUR-BELT-1", tags: ["auto:mine"]
            )],
            directives: [pinnedHaulRun()]
        )
        #expect(rows.first?.headlineDesignation == "ACHERNUR-BELT-1")
        #expect(rows.first?.title == "Haul Run → ACHERNUR-BELT-1")
        #expect(rows.first?.subtitle == "Hauling belt inventory")
    }

    /// The pin is a fact of the ROW, so the belt renders before the ferry has
    /// taken the config — but the subtitle must not claim work that is not in
    /// flight, and "Nothing reachable" is false about a pile the row names.
    @Test func aPinnedHaulRunNamesItsBeltBeforeTheFerryTakesTheConfig() {
        let rows = DirectiveRow.merge(
            devices: [haulController(code: "FERRY1", tags: ["auto:mine"])],
            directives: [pinnedHaulRun()]
        )
        #expect(rows.first?.headlineDesignation == "ACHERNUR-BELT-1")
        #expect(rows.first?.subtitle == "Pointing the ferry")
    }

    /// The row reads its OWN ferry. A tagged controller draining some other
    /// pile belongs to the general drainer and must not answer for this row.
    @Test func aPinnedHaulRunReadsItsOwnFerryNotTheTaggedFleet() {
        let rows = DirectiveRow.merge(
            devices: [
                haulController(code: "FERRY1", tags: ["auto:mine"]),
                haulController(code: "HAUL1", collecting: "ATIANFU-BELT-1"),
            ],
            directives: [pinnedHaulRun()]
        )
        #expect(rows.first?.headlineDesignation == "ACHERNUR-BELT-1")
        #expect(rows.first?.subtitle == "Pointing the ferry")
    }

    /// Mid-repoint the ferry still runs the previous pile's config. The row
    /// names what it is pinned to and admits the work has not landed.
    @Test func aPinnedHaulRunOnAFerryStillDrainingAnotherPileIsNotHauling() {
        let rows = DirectiveRow.merge(
            devices: [haulController(
                code: "FERRY1", collecting: "ATIANFU-BELT-1", tags: ["auto:mine"]
            )],
            directives: [pinnedHaulRun()]
        )
        #expect(rows.first?.headlineDesignation == "ACHERNUR-BELT-1")
        #expect(rows.first?.subtitle == "Pointing the ferry")
    }

    /// The lock half: the ferry's built-in row names the run driving it, which
    /// is what the Reconfigure/Clear refusals key on.
    @Test func aPinnedHaulRunDrivesItsFerrysBuiltInRow() {
        let rows = DirectiveRow.merge(
            devices: [haulController(
                code: "FERRY1", collecting: "ACHERNUR-BELT-1", tags: ["auto:mine"]
            )],
            directives: [pinnedHaulRun()]
        )
        guard case let .builtIn(builtIn)? = rows.last else {
            Issue.record("expected the ferry's built-in row")
            return
        }
        #expect(builtIn.drivenBy?.title == "Haul Run")
        #expect(rows.last?.subtitle == "driven by Haul Run")
    }
}


// MARK: - Fleet-tag ownership

/// The mine's belt controllers hold directives no mission row owns — `mineRun`
/// finishes after install and the brain re-derives mine health statelessly — so
/// their `auto:` fleet tag is what marks the row engine-owned.
private let mineBelt = "ACHERNUR-BELT-1"

private func miningController(
    code: String = "MINE1", directive: String = "gather_evenly", location: String = mineBelt
) -> Device {
    device(
        code: code, type: "ami_mining_controller", directive: directive,
        tags: [MineRecipe.fleetTag.string], location: location
    )
}

@Suite("Directive row fleet-tag ownership")
struct DirectiveRowFleetTagOwnershipTests {
    /// The mine's `gather_evenly` controller: a directive in force, no mission
    /// row to stamp, and one Clear away from breaking the permanent mine.
    @Test func aTaggedControllerWithNoOwningMissionIsEngineOwned() {
        let rows = DirectiveRow.merge(devices: [miningController()], directives: [])
        guard case let .builtIn(builtIn)? = rows.first else {
            Issue.record("expected the controller's built-in row")
            return
        }
        #expect(builtIn.drivenBy != nil)
        #expect(rows.first?.subtitle == "part of the mine")
    }

    /// The belt is what tells two installed mines apart, so it rides the
    /// headline — the half rendered in a mono token (house rule).
    @Test func aMineControllerNamesTheBeltItWorks() {
        let rows = DirectiveRow.merge(devices: [miningController()], directives: [])
        #expect(rows.first?.headlineDesignation == mineBelt)
        #expect(rows.first?.title == "Gather Evenly → ACHERNUR-BELT-1")
    }

    /// The mine's second controller stands at the same belt, so it names the
    /// same mine — the belt comes from the installed mining controller, not
    /// from the device's own type.
    @Test func theBeltSearchControllerNamesTheSameMine() {
        let rows = DirectiveRow.merge(
            devices: [
                miningController(),
                device(
                    code: "SURV1", directive: "belt_search",
                    tags: [MineRecipe.fleetTag.string], location: mineBelt
                ),
            ],
            directives: []
        )
        let belt = rows.first { $0.deviceCode == "SURV1" }
        #expect(belt?.headlineDesignation == mineBelt)
        #expect(belt?.subtitle == "part of the mine")
    }

    /// A tagged device standing somewhere no mine is installed claims no belt.
    /// The mine's ferry lives at the delivery sink, and naming that as its mine
    /// would be a designation the fleet does not establish.
    @Test func aTaggedDeviceAwayFromAnInstalledBeltClaimsNoBelt() {
        let rows = DirectiveRow.merge(
            devices: [
                miningController(),
                haulController(
                    code: "FERRY1", collecting: mineBelt, tags: [MineRecipe.fleetTag.string]
                ),
            ],
            directives: []
        )
        let ferry = rows.first { $0.deviceCode == "FERRY1" }
        #expect(ferry?.headlineDesignation == nil)
        #expect(ferry?.subtitle == "part of the mine")
    }

    /// The predicate is the `auto:` prefix, not the mine: a service bot armed
    /// by the Survey Run is engine-owned the same way, and clearing its
    /// `service` directive would silently disarm repair.
    @Test func aServiceBotOnAnotherFleetsTagIsEngineOwnedToo() {
        let rows = DirectiveRow.merge(
            devices: [device(
                code: "BOT1", type: "service_bot", directive: "service",
                tags: [SurveyRun.defaultFleetTag.string], location: "MOTHALELAH-5-13"
            )],
            directives: []
        )
        #expect(rows.first?.subtitle == "part of the survey fleet")
        #expect(rows.first?.headlineDesignation == nil)
    }

    /// An untagged controller is the operator's, however busy — the tag is the
    /// opt-in, and taking it back is what un-tagging means.
    @Test func anUntaggedControllerStaysTheOperators() {
        let rows = DirectiveRow.merge(
            devices: [device(code: "AMI1", directive: "survey_system")],
            directives: []
        )
        guard case let .builtIn(builtIn)? = rows.first else {
            Issue.record("expected a built-in row")
            return
        }
        #expect(builtIn.drivenBy == nil)
    }

    /// A device already held by a live mission reports THAT, never its tag —
    /// one row, one owner, and the mission is the more specific answer.
    @Test func aMissionOwnedControllerDoesNotAlsoReportItsTag() {
        var driving = mission(id: "D1")
        driving.controllerCode = "AMI1"
        let rows = DirectiveRow.merge(
            devices: [device(
                code: "AMI1", directive: "survey_system",
                tags: [SurveyRun.defaultFleetTag.string]
            )],
            directives: [driving]
        )
        let builtIn = rows.first { $0.deviceCode == "AMI1" && $0.id.hasPrefix("builtin:") }
        #expect(builtIn?.subtitle == "driven by Survey Run")
        #expect(builtIn?.headlineDesignation == nil)
    }

    /// Ownership is derived from a directive IN FORCE. A tagged device running
    /// nothing has no row to lock, so the tag alone locks nothing.
    @Test func aTaggedDeviceRunningNoDirectiveIsNoRowAtAll() {
        let rows = DirectiveRow.merge(
            devices: [device(code: "IDLE1", tags: [MineRecipe.fleetTag.string], location: mineBelt)],
            directives: []
        )
        #expect(rows.isEmpty)
    }

    /// A mine fleet still standing at the hub is inventory, not a mine — its
    /// mining controller runs nothing yet — so a tagged sibling working there
    /// must not be labelled with the hub as its belt.
    @Test func anIdleMineFleetAtTheHubIsNotAMine() {
        let hub = "AINALRAM-BELT-1"
        let rows = DirectiveRow.merge(
            devices: [
                device(
                    code: "MINE2", type: "ami_mining_controller",
                    tags: [MineRecipe.fleetTag.string], location: hub
                ),
                haulController(
                    code: "FERRY1", collecting: mineBelt,
                    tags: [MineRecipe.fleetTag.string], location: hub
                ),
            ],
            directives: []
        )
        let ferry = rows.first { $0.deviceCode == "FERRY1" }
        #expect(ferry?.subtitle == "part of the mine")
        #expect(ferry?.headlineDesignation == nil)
    }

    /// The server lowercases every tag, and a row written before a sync can
    /// still hold whatever was typed — so the predicate normalises both sides.
    @Test func aCaseDriftedTagStillOwnsTheRow() {
        let rows = DirectiveRow.merge(
            devices: [device(
                code: "AMI1", directive: "belt_search",
                tags: ["Auto:Mine"], location: mineBelt
            )],
            directives: []
        )
        #expect(rows.first?.subtitle == "part of the mine")
    }
}
