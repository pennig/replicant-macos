//
//  DeviceListSectionsTests.swift
//  Replicould — Devices feature tests
//
//  The entry point: a pinned Needs Attention section above one unheadered
//  carrier section, with flagged devices *promoted* (not duplicated).
//

import CustomDump
import Foundation
import GameModels
import Testing
@testable import DevicesFeature

@Suite struct DeviceListSectionsTests {

    private func sections(
        fleet: [Device],
        directives: [Directive] = [],
        search: String = "",
        expanded: Set<String> = [],
        collapsedGroups: Set<String> = []
    ) -> [DeviceListSection] {
        DeviceListLayout.sections(
            fleet: fleet,
            attentionDirectives: directives,
            searchText: search,
            expandedHosts: expanded,
            collapsedGroups: collapsedGroups
        )
    }

    @Test func noAttentionSectionWhenNothingIsFlagged() {
        let result = sections(fleet: [makeDevice("AAAA"), makeDevice("BBBB")])
        expectNoDifference(result.map(\.id), [DeviceListSection.fleetID])
        expectNoDifference(result[0].header, nil)
    }

    @Test func flaggedDeviceIsPromotedNotDuplicated() {
        let fleet = [makeDevice("AAAA", capacity: 10), makeDevice("BBBB")]
        let result = sections(fleet: fleet)
        expectNoDifference(result.map(\.id), [DeviceListSection.attentionID, DeviceListSection.fleetID])
        expectNoDifference(result[0].entries.map(\.id), ["AAAA"])
        expectNoDifference(result[1].entries.map(\.id), ["BBBB"])
    }

    /// A flagged device is lifted out at whatever depth it sat, taking its own
    /// subtree with it, and re-rooted at depth 0 of the attention section. Its
    /// former host stays put with `childCount` reduced.
    @Test func promotionLiftsTheSubtreeAndReducesTheFormerHostsChildCount() throws {
        let fleet = [
            makeDevice("VESSEL", type: "heaven_vessel"),
            makeDevice("CTRL", type: "ami_survey_controller", capacity: 20, stowedIn: "VESSEL"),
            makeDevice("DRONEA", stowedIn: "VESSEL", controlledBy: "CTRL"),
            makeDevice("OTHER", type: "ami_survey_controller", stowedIn: "VESSEL"),
        ]
        let result = sections(fleet: fleet, expanded: ["VESSEL", "CTRL"])

        let attention = result[0]
        expectNoDifference(attention.entries.map(\.id), ["CTRL", "DRONEA"])
        expectNoDifference(attention.entries.map(\.depth), [0, 1])

        let vessel = try #require(result[1].entries.first { $0.id == "VESSEL" })
        expectNoDifference(vessel.childCount, 1)
        expectNoDifference(result[1].entries.map(\.id), ["VESSEL", "OTHER"])
    }

    /// A flagged device inside a flagged device's subtree appears once, under it.
    @Test func nestedFlaggedDeviceAppearsOnlyOnce() {
        let fleet = [
            makeDevice("CTRL", type: "ami_survey_controller", capacity: 20),
            makeDevice("DRONEA", capacity: 10, controlledBy: "CTRL"),
        ]
        let result = sections(fleet: fleet, expanded: ["CTRL"])
        expectNoDifference(result.map(\.id), [DeviceListSection.attentionID])
        expectNoDifference(result[0].entries.map(\.id), ["CTRL", "DRONEA"])
    }

    @Test func attentionSectionOrdersByReason() {
        let fleet = [
            makeDevice("AAAA", capacity: 40),
            makeDevice("BBBB", detail: .object(["in_control_range": .bool(false)])),
            makeDevice("CCCC", capacity: 10),
        ]
        let result = sections(fleet: fleet)
        expectNoDifference(result[0].entries.map(\.id), ["BBBB", "CCCC", "AAAA"])
    }

    @Test func collapsedAttentionSectionKeepsItsHeaderAndDropsItsEntries() throws {
        let fleet = [makeDevice("AAAA", capacity: 10), makeDevice("BBBB")]
        let result = sections(fleet: fleet, collapsedGroups: [DeviceListSection.attentionID])
        expectNoDifference(result[0].entries, [])
        let header = try #require(result[0].header)
        expectNoDifference(header.isCollapsed, true)
        expectNoDifference(header.count, 1)
        expectNoDifference(header.hasDamaged, true)
    }

    @Test func headerReportsItsStatusDistribution() throws {
        let fleet = [
            makeDevice("AAAA", status: "relaying", capacity: 10),
            makeDevice("BBBB", status: "relaying", capacity: 20),
            makeDevice("CCCC", status: "idle", capacity: 30),
        ]
        let header = try #require(sections(fleet: fleet)[0].header)
        expectNoDifference(
            header.statusShares,
            [StatusShare(status: "relaying", count: 2), StatusShare(status: "idle", count: 1)]
        )
    }

    @Test func directiveFlaggedDeviceIsPromoted() {
        let fleet = [makeDevice("AAAA"), makeDevice("BBBB")]
        let directives = [makeDirective(deviceCode: "BBBB", reason: .commandRejected)]
        let result = sections(fleet: fleet, directives: directives)
        expectNoDifference(result[0].entries.map(\.id), ["BBBB"])
        expectNoDifference(result[0].entries[0].attention, [.directive(.commandRejected)])
        expectNoDifference(result[1].entries.map(\.id), ["AAAA"])
    }

    /// The header's `count` is the whole population under it — the flagged
    /// root plus every non-flagged descendant carried along with it — not the
    /// number of promoted roots. Every other fixture in this suite is flat, so
    /// roots happen to equal members; this one has a flagged host with an
    /// *unflagged* child, which is the case that would let a regression back
    /// to `attentionRoots.count` (one root, but two devices and rows under the
    /// header) slip through unnoticed.
    @Test func headerCountIsTheWholeSectionNotJustThePromotedRoots() throws {
        let fleet = [
            makeDevice("CTRL", type: "ami_survey_controller", capacity: 10),
            makeDevice("DRONEA", controlledBy: "CTRL"),
        ]
        let result = sections(fleet: fleet, expanded: ["CTRL"])
        let header = try #require(result[0].header)
        expectNoDifference(header.count, 2)
        expectNoDifference(result[0].entries.map(\.id), ["CTRL", "DRONEA"])
    }

    @Test func orderedIDsAreTheVisibleOrderExactly() {
        let fleet = [
            makeDevice("VESSEL", type: "heaven_vessel"),
            makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL"),
            makeDevice("DRONEA", stowedIn: "VESSEL", controlledBy: "CTRL"),
            makeDevice("HURT", capacity: 5),
        ]
        let result = sections(fleet: fleet, expanded: ["VESSEL"])
        expectNoDifference(
            result.flatMap(\.entries).map(\.id),
            ["HURT", "VESSEL", "CTRL"]
        )
    }
}
