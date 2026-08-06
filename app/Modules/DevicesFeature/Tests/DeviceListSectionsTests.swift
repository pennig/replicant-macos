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
        grouping: DeviceGrouping = .carrier,
        search: String = "",
        expanded: Set<String> = [],
        collapsedGroups: Set<String> = []
    ) -> [DeviceListSection] {
        DeviceListLayout.sections(
            fleet: fleet,
            attentionDirectives: directives,
            grouping: grouping,
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

    /// End-to-end: a flagged device promoted into the Needs Attention section
    /// still resolves `hostDeviceType` for its controller, even though the
    /// promotion re-roots it away from its original position in the fleet
    /// forest (where a resolved controller would otherwise nest it with no
    /// badge at all). `sections(...)` builds the code→type map from the whole
    /// fleet, not just the promoted subforest, so the controller's type is
    /// still found.
    @Test func promotedDeviceStillResolvesItsControllersType() throws {
        let fleet = [
            makeDevice("CTRL", type: "ami_transport_controller"),
            makeDevice("DRONEA", capacity: 10, controlledBy: "CTRL"),
        ]
        let result = sections(fleet: fleet)
        let drone = try #require(result[0].entries.first { $0.id == "DRONEA" })
        expectNoDifference(drone.host, .controlled(by: "CTRL"))
        expectNoDifference(drone.hostDeviceType, "ami_transport_controller")
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

    // MARK: - Grouped modes

    /// A carrier whose contents would nest in Carrier mode, so every grouped
    /// test below also proves the tree is flattened.
    private var nestedFleet: [Device] {
        [
            makeDevice("VESSEL", type: "heaven_vessel", location: "ATIANFU-1-L4"),
            makeDevice("CTRL", type: "ami_survey_controller", tags: ["auto:survey"], stowedIn: "VESSEL"),
            makeDevice("DRONEA", type: "survey_drone", stowedIn: "VESSEL", controlledBy: "CTRL"),
        ]
    }

    @Test func typeSectionsOrderByCountThenDisplayName() {
        let fleet = [
            makeDevice("R1", type: "ftl_relay"),
            makeDevice("R2", type: "ftl_relay"),
            makeDevice("R3", type: "ftl_relay"),
            makeDevice("P1", type: "surge_plate"),
            makeDevice("P2", type: "surge_plate"),
            makeDevice("B1", type: "ftl_beacon"),
            makeDevice("S1", type: "survey_drone"),
        ]
        let result = sections(fleet: fleet, grouping: .type)
        expectNoDifference(
            result.map(\.id),
            ["type:ftl_relay", "type:surge_plate", "type:ftl_beacon", "type:survey_drone"]
        )
        expectNoDifference(result.map { $0.header?.count }, [3, 2, 1, 1])
        expectNoDifference(result[0].header?.title, "FTL Relay")
    }

    /// Containment does not survive a flattened mode: the drone files under its
    /// own type rather than staying buried in the vessel.
    @Test func aGroupedModeFlattensTheTree() {
        let result = sections(fleet: nestedFleet, grouping: .type)
        expectNoDifference(
            result.flatMap(\.entries).map(\.id).sorted(),
            ["CTRL", "DRONEA", "VESSEL"]
        )
        #expect(result.flatMap(\.entries).allSatisfy { $0.depth == 0 && $0.childCount == 0 })
    }

    /// A system title is a designation, so it renders monospaced; Unknown is
    /// prose and sorts last however many devices it holds.
    @Test func systemTitlesAreDesignationsAndUnknownSortsLast() {
        let fleet = [
            makeDevice("A1", location: "ATIANFU-1-L4"),
            makeDevice("A2", location: "ATIANFU-BELT-1"),
            makeDevice("S1", location: "SOL-3"),
            makeDevice("U1"),
            makeDevice("U2"),
            makeDevice("U3"),
        ]
        let result = sections(fleet: fleet, grouping: .system)
        expectNoDifference(result.map(\.id), ["system:ATIANFU", "system:SOL", "system:unknown"])
        expectNoDifference(result.map { $0.header?.titleIsDesignation }, [true, true, false])
        expectNoDifference(result.map { $0.header?.count }, [2, 1, 3])
    }

    /// A stowed device inherits its carrier's system rather than falling to
    /// Unknown.
    @Test func systemModeInheritsTheCarriersSystem() {
        let result = sections(fleet: nestedFleet, grouping: .system)
        expectNoDifference(result.map(\.id), ["system:ATIANFU"])
        expectNoDifference(result[0].header?.count, 3)
    }

    /// Mission is a facet, not a partition: a two-tag device is counted under
    /// both headers, so the headers sum above the fleet size. This is the
    /// design's one documented exception to "partitions the fleet exactly once".
    @Test func missionIsAFacetSoHeaderCountsSumAboveTheFleet() {
        let fleet = [
            makeDevice("A1", tags: ["taxi", "auto:haul"]),
            makeDevice("A2", tags: ["taxi"]),
            makeDevice("A3"),
        ]
        let result = sections(fleet: fleet, grouping: .mission)
        expectNoDifference(result.map(\.id), ["mission:taxi", "mission:auto:haul", "mission:untagged"])
        expectNoDifference(result.compactMap { $0.header?.count }.reduce(0, +), 4)
        expectNoDifference(result[0].entries.map(\.id), ["A1", "A2"])
    }

    @Test func flatIsOneUnheaderedSectionInSortOrder() {
        let fleet = [
            makeDevice("ZZZZ", type: "ftl_relay"),
            makeDevice("AAAA", type: "survey_drone"),
            makeDevice("BBBB", type: "ftl_relay"),
        ]
        let result = sections(fleet: fleet, grouping: .flat)
        expectNoDifference(result.map(\.id), [DeviceListSection.fleetID])
        expectNoDifference(result[0].header, nil)
        expectNoDifference(result[0].entries.map(\.id), ["BBBB", "ZZZZ", "AAAA"])
    }

    /// Sort within a grouped section is the same rule as within a carrier
    /// level: type display name, then device code.
    @Test func sortWithinAGroupedSectionIsTypeThenCode() {
        let fleet = [
            makeDevice("ZZZZ", type: "survey_drone", location: "SOL-1"),
            makeDevice("AAAA", type: "survey_drone", location: "SOL-1"),
            makeDevice("MMMM", type: "ftl_relay", location: "SOL-1"),
        ]
        let result = sections(fleet: fleet, grouping: .system)
        expectNoDifference(result[0].entries.map(\.id), ["MMMM", "AAAA", "ZZZZ"])
    }

    @Test func needsAttentionIsPinnedAboveTheGroupsInEveryMode() throws {
        let fleet = [makeDevice("HURT", type: "ftl_relay", capacity: 5), makeDevice("OKAY", type: "ftl_relay")]
        for grouping in DeviceGrouping.allCases {
            let result = sections(fleet: fleet, grouping: grouping)
            expectNoDifference(result.first?.id, DeviceListSection.attentionID)
            expectNoDifference(result[0].entries.map(\.id), ["HURT"])
            // Promoted, never duplicated: it is absent from its own group.
            let below = result.dropFirst().flatMap(\.entries).map(\.id)
            expectNoDifference(below, ["OKAY"])
        }
    }

    /// A collapsed section keeps its header so it can be opened again, and
    /// contributes no rows to `orderedIDs`.
    @Test func aCollapsedGroupKeepsItsHeaderAndContributesNoEntries() throws {
        let fleet = [
            makeDevice("R1", type: "ftl_relay"),
            makeDevice("S1", type: "survey_drone"),
        ]
        let result = sections(fleet: fleet, grouping: .type, collapsedGroups: ["type:ftl_relay"])
        expectNoDifference(result.map(\.id), ["type:ftl_relay", "type:survey_drone"])
        let header = try #require(result[0].header)
        expectNoDifference(header.isCollapsed, true)
        expectNoDifference(header.count, 1)
        expectNoDifference(result[0].entries, [])
        expectNoDifference(result.orderedIDs, ["S1"])
    }

    @Test func aSearchThatEmptiesASectionDropsIt() {
        let fleet = [
            makeDevice("R1", type: "ftl_relay"),
            makeDevice("S1", type: "survey_drone"),
        ]
        expectNoDifference(
            sections(fleet: fleet, grouping: .type, search: "survey").map(\.id),
            ["type:survey_drone"]
        )
        expectNoDifference(sections(fleet: fleet, grouping: .type, search: "zzzz"), [])
    }

    /// A collapsed section that the query empties is dropped like any other —
    /// collapse is applied to what survives the search, not before it.
    @Test func aCollapsedSectionTheQueryEmptiesIsStillDropped() {
        let fleet = [makeDevice("R1", type: "ftl_relay"), makeDevice("S1", type: "survey_drone")]
        expectNoDifference(
            sections(fleet: fleet, grouping: .type, search: "survey", collapsedGroups: ["type:ftl_relay"]).map(\.id),
            ["type:survey_drone"]
        )
    }

    /// Flattened modes never consult the carrier disclosure state, so switching
    /// away and back leaves it exactly as the operator left it.
    @Test func flattenedModesIgnoreExpandedHosts() {
        expectNoDifference(
            sections(fleet: nestedFleet, grouping: .type, expanded: []),
            sections(fleet: nestedFleet, grouping: .type, expanded: ["VESSEL", "CTRL"])
        )
    }

    /// Position encodes no containment in a flattened mode, so the row carries
    /// its host as a badge instead.
    @Test func aFlattenedRowBadgesItsHost() throws {
        let result = sections(fleet: nestedFleet, grouping: .type)
        let drone = try #require(result.flatMap(\.entries).first { $0.id == "DRONEA" })
        expectNoDifference(drone.host, .controlled(by: "CTRL"))
        expectNoDifference(drone.hostDeviceType, "ami_survey_controller")
    }

    /// Type and System are partitions: every device appears exactly once across
    /// the whole list. Mission is the documented exception, so it is excluded.
    @Test func typeAndSystemPlaceEveryDeviceExactlyOnce() {
        let fleet = [
            makeDevice("VESSEL", type: "heaven_vessel", location: "ATIANFU-1-L4"),
            makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL"),
            makeDevice("DRONEA", type: "survey_drone", controlledBy: "CTRL"),
            makeDevice("HURT", type: "ftl_relay", capacity: 5),
            makeDevice("LOOSE", type: "ftl_relay"),
        ]
        for grouping in [DeviceGrouping.type, .system] {
            let ids = sections(fleet: fleet, grouping: grouping).flatMap(\.entries).map(\.id)
            expectNoDifference(ids.sorted(), fleet.map(\.deviceCode).sorted())
            expectNoDifference(Set(ids).count, ids.count)
        }
    }

    /// Status shares describe the section they head.
    @Test func aGroupHeaderReadsItsOwnComposition() throws {
        let fleet = [
            makeDevice("R1", type: "ftl_relay", status: "relaying"),
            makeDevice("R2", type: "ftl_relay", status: "relaying"),
            makeDevice("R3", type: "ftl_relay", status: "idle"),
        ]
        let header = try #require(sections(fleet: fleet, grouping: .type).first?.header)
        expectNoDifference(
            header.statusShares,
            [StatusShare(status: "relaying", count: 2), StatusShare(status: "idle", count: 1)]
        )
        expectNoDifference(header.hasDamaged, false)
    }
}
