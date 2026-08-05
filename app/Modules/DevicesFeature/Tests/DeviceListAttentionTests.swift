//
//  DeviceListAttentionTests.swift
//  Replicould — Devices feature tests
//
//  The three Needs Attention predicates, the three directive join paths, and
//  the section's own sort order.
//

import CustomDump
import Foundation
import GameModels
import Testing
import Utils
@testable import DevicesFeature

@Suite struct DeviceListAttentionTests {

    @Test func damagedBelowThresholdOnly() {
        let hurt = makeDevice("A1", capacity: 42)
        let fine = makeDevice("A2", capacity: 60)
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: hurt, directives: []),
            [.damaged(capacity: 42)]
        )
        expectNoDifference(DeviceListLayout.attentionFlags(for: fine, directives: []), [])
    }

    @Test func thresholdIsExclusive() {
        let edge = makeDevice("A1", capacity: DeviceListLayout.damagedCapacityThreshold)
        expectNoDifference(DeviceListLayout.attentionFlags(for: edge, directives: []), [])
    }

    @Test func outOfControlRangeFlags() {
        let cut = makeDevice("A1", detail: .object(["in_control_range": .bool(false)]))
        let ok = makeDevice("A2", detail: .object(["in_control_range": .bool(true)]))
        let unknown = makeDevice("A3")
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: cut, directives: []),
            [.outOfControlRange]
        )
        expectNoDifference(DeviceListLayout.attentionFlags(for: ok, directives: []), [])
        expectNoDifference(DeviceListLayout.attentionFlags(for: unknown, directives: []), [])
    }

    /// Modeled on the live fleet's `E992E400` (`cargo_freighter`, `surging`,
    /// out of range mid-surge-plate jump): the flag must be fully suppressed,
    /// not merely reordered.
    @Test func surgingOutOfRangeDeviceIsNotFlagged() {
        let surging = makeDevice(
            "E992E400",
            type: "cargo_freighter",
            status: "surging",
            controlledBy: "7D1569BF",
            detail: .object(["in_control_range": .bool(false)])
        )
        expectNoDifference(DeviceListLayout.attentionFlags(for: surging, directives: []), [])
    }

    /// Modeled on the live fleet's `1F63E913` (`ftl_beacon`, `monitoring`, out
    /// of range): a non-surging status must keep the flag exactly as before.
    @Test func nonSurgingOutOfRangeDeviceStillFlags() {
        let monitoring = makeDevice(
            "1F63E913",
            type: "ftl_beacon",
            status: "monitoring",
            detail: .object(["in_control_range": .bool(false)])
        )
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: monitoring, directives: []),
            [.outOfControlRange]
        )
    }

    /// The suppression is surgical to `.outOfControlRange` — a surging device
    /// that is *also* damaged must still report `.damaged`, proving this isn't
    /// a blanket "ignore surging devices" rule.
    @Test func surgingDamagedDeviceStillFlagsDamaged() {
        let surgingAndHurt = makeDevice(
            "A1",
            status: "surging",
            capacity: 10,
            detail: .object(["in_control_range": .bool(false)])
        )
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: surgingAndHurt, directives: []),
            [.damaged(capacity: 10)]
        )
    }

    /// The owner confirmed `travelling` directly: a device mid-FTL-route has
    /// left the relay mesh on purpose and will rejoin at the final leg, so the
    /// flag carries no information — same rationale as `surging`.
    @Test func travellingOutOfRangeDeviceIsNotFlagged() {
        let travelling = makeDevice(
            "T001",
            type: "cargo_freighter",
            status: "travelling",
            detail: .object(["in_control_range": .bool(false)])
        )
        expectNoDifference(DeviceListLayout.attentionFlags(for: travelling, directives: []), [])
    }

    /// `cruising` is the per-leg status of the same whole-route trip
    /// `travelling` names (`device_cruise_arrived` fires once per leg,
    /// `device_travel_arrived` once at the final destination). With
    /// `travelling` and `surging` both exempt, leaving `cruising` flagged
    /// would make a mid-route device flicker in and out of the triage list
    /// as its legs change — exactly the noise this constant removes.
    @Test func cruisingOutOfRangeDeviceIsNotFlagged() {
        let cruising = makeDevice(
            "C001",
            type: "cargo_freighter",
            status: "cruising",
            detail: .object(["in_control_range": .bool(false)])
        )
        expectNoDifference(DeviceListLayout.attentionFlags(for: cruising, directives: []), [])
    }

    /// `recalling` is a drone returning to its controller — a different
    /// mechanic from FTL travel — and there is no live evidence it goes
    /// out of range. Pinned deliberately excluded: if a future author adds
    /// `recalling` to `rangeCheckExemptStatuses`, this test breaks and forces
    /// them to read why it wasn't included in the first place.
    @Test func recallingOutOfRangeDeviceStillFlags() {
        let recalling = makeDevice(
            "R001",
            type: "survey_drone",
            status: "recalling",
            detail: .object(["in_control_range": .bool(false)])
        )
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: recalling, directives: []),
            [.outOfControlRange]
        )
    }

    /// The suppression is surgical to `.outOfControlRange` — a travelling
    /// device that is *also* damaged must still report `.damaged`, proving
    /// this isn't a blanket "ignore travelling devices" rule.
    @Test func travellingDamagedDeviceStillFlagsDamaged() {
        let travellingAndHurt = makeDevice(
            "T002",
            status: "travelling",
            capacity: 10,
            detail: .object(["in_control_range": .bool(false)])
        )
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: travellingAndHurt, directives: []),
            [.damaged(capacity: 10)]
        )
    }

    @Test func directiveJoinsOnDeviceCode() {
        let device = makeDevice("A1")
        let directive = makeDirective(deviceCode: "A1", reason: .commandRejected)
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: device, directives: [directive]),
            [.directive(.commandRejected)]
        )
    }

    @Test func directiveJoinsOnControllerCode() {
        let device = makeDevice("CTRL1")
        let directive = makeDirective(deviceCode: "VESSEL1", controllerCode: "CTRL1", reason: .noSurveyDroneAboard)
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: device, directives: [directive]),
            [.directive(.noSurveyDroneAboard)]
        )
    }

    @Test func directiveJoinsOnFleetTag() {
        let device = makeDevice("A1", tags: ["auto:haul"])
        let directive = makeDirective(deviceCode: "OTHER", fleetTag: "auto:haul", reason: .noHaulControllerTagged)
        let untagged = makeDevice("A2")
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: device, directives: [directive]),
            [.directive(.noHaulControllerTagged)]
        )
        expectNoDifference(DeviceListLayout.attentionFlags(for: untagged, directives: [directive]), [])
    }

    @Test func directiveWithNoRecordedReasonStillFlags() {
        let device = makeDevice("A1")
        let directive = makeDirective(deviceCode: "A1", reason: nil)
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: device, directives: [directive]),
            [.directive(nil)]
        )
        #expect(AttentionFlag.directive(nil).label == "Directive needs attention")
    }

    @Test func flagsAccumulate() {
        let device = makeDevice("A1", capacity: 10, detail: .object(["in_control_range": .bool(false)]))
        let directive = makeDirective(deviceCode: "A1", reason: .commandRejected)
        expectNoDifference(
            DeviceListLayout.attentionFlags(for: device, directives: [directive]),
            [.outOfControlRange, .damaged(capacity: 10), .directive(.commandRejected)]
        )
    }

    /// Out-of-control-range first, then damaged ascending by capacity, then
    /// directive-flagged, then device code.
    @Test func sectionOrdering() {
        let cut = makeDevice("Z9", detail: .object(["in_control_range": .bool(false)]))
        let badlyHurt = makeDevice("M5", capacity: 10)
        let hurt = makeDevice("B2", capacity: 40)
        let flagged = makeDevice("A1")
        let alsoFlagged = makeDevice("A0")
        let directives = [
            makeDirective(id: "D1", deviceCode: "A1"),
            makeDirective(id: "D2", deviceCode: "A0"),
        ]
        let fleet = [flagged, hurt, cut, badlyHurt, alsoFlagged]
        let attention = Dictionary(
            uniqueKeysWithValues: fleet.map {
                ($0.deviceCode, DeviceListLayout.attentionFlags(for: $0, directives: directives))
            }
        )
        let ordered = fleet
            .sorted { DeviceListLayout.attentionPrecedes($0, $1, attention: attention) }
            .map(\.deviceCode)
        expectNoDifference(ordered, ["Z9", "M5", "B2", "A0", "A1"])
    }
}
