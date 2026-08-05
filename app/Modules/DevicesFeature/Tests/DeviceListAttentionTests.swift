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
