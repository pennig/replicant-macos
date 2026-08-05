//
//  DeviceListSearchTests.swift
//  Replicould — Devices feature tests
//
//  `DeviceListLayout` search: AND across whitespace-split terms, OR across the
//  per-device haystack fields, case- and diacritic-insensitive.
//

import CustomDump
import Foundation
import GameModels
import Testing
@testable import DevicesFeature

@Suite struct DeviceListSearchTests {

    @Test func emptyQueryMatchesEverything() {
        let query = DeviceListLayout.Query("   ")
        #expect(query.isEmpty)
        #expect(DeviceListLayout.matches(makeDevice("A1B2C3D4"), query: query))
    }

    @Test func matchesOnDeviceCode() {
        let device = makeDevice("A1B2C3D4")
        #expect(DeviceListLayout.matches(device, query: .init("b2c3")))
        #expect(!DeviceListLayout.matches(device, query: .init("zzzz")))
    }

    @Test func matchesOnDisplayNameAndRawType() {
        // "survey_drone" displays as "Survey Drone", so both the display name
        // and the raw type are in the haystack and both are reachable.
        let device = makeDevice("A1B2C3D4", type: "survey_drone")
        #expect(DeviceListLayout.matches(device, query: .init("Survey Drone")))
        #expect(DeviceListLayout.matches(device, query: .init("survey")))
        #expect(DeviceListLayout.matches(device, query: .init("survey_drone")))
    }

    @Test func matchesOnLocationAndLocationName() {
        let device = makeDevice("A1B2C3D4", location: "ATIANFU-1-L4", locationName: "Atianfu Prime")
        #expect(DeviceListLayout.matches(device, query: .init("atianfu-1")))
        #expect(DeviceListLayout.matches(device, query: .init("prime")))
    }

    @Test func matchesOnTagsAndStatusBase() {
        let device = makeDevice("A1B2C3D4", status: "mining (iron)", tags: ["auto:survey"])
        #expect(DeviceListLayout.matches(device, query: .init("auto:survey")))
        #expect(DeviceListLayout.matches(device, query: .init("mining")))
        // The status *parameter* is not part of the haystack — `statusBase` is.
        #expect(!DeviceListLayout.matches(device, query: .init("iron")))
    }

    @Test func everyTermMustMatchSomeField() {
        let device = makeDevice("A1B2C3D4", type: "survey_drone", location: "ATIANFU-1-L4")
        #expect(DeviceListLayout.matches(device, query: .init("survey ATIANFU")))
        #expect(!DeviceListLayout.matches(device, query: .init("survey POLARISUM")))
    }

    @Test func caseAndDiacriticInsensitive() {
        let device = makeDevice("A1B2C3D4", locationName: "Ésellusau")
        #expect(DeviceListLayout.matches(device, query: .init("esellusau")))
        #expect(DeviceListLayout.matches(device, query: .init("ÉSELLUSAU")))
    }
}

@Suite struct DeviceListSearchPruningTests {

    private var fleet: [Device] {
        [
            makeDevice("VESSEL", type: "heaven_vessel", location: "ATIANFU-1-L4"),
            makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL"),
            makeDevice("DRONEA", type: "survey_drone", stowedIn: "VESSEL", controlledBy: "CTRL"),
            makeDevice("RELAY", type: "ftl_relay", status: "relaying", location: "POLARISUM-1"),
        ]
    }

    private func sections(_ search: String, expanded: Set<String> = []) -> [DeviceListSection] {
        DeviceListLayout.sections(
            fleet: fleet,
            attentionDirectives: [],
            searchText: search,
            expandedHosts: expanded,
            collapsedGroups: []
        )
    }

    /// A match on a child of a collapsed host is revealed, ancestors and all.
    @Test func matchOnACollapsedChildIsRevealed() {
        let entries = sections("survey_drone").flatMap(\.entries)
        expectNoDifference(entries.map(\.id), ["VESSEL", "CTRL", "DRONEA"])
    }

    /// The reveal is transient. `expandedHosts` is an input, so a query cannot
    /// leave the operator's disclosure state changed behind it: clearing the
    /// query with the same (empty) collapse set must return to that same
    /// collapsed tree, not the one the query revealed. Asserting the input
    /// set is "still empty" afterwards would prove nothing — `Set` is a value
    /// type, so no implementation could ever fail that; this instead checks
    /// the actual before/after shape of the rendered rows.
    @Test func revealIsTransientAndLeavesCollapseStateIntact() {
        let revealed = sections("survey_drone").flatMap(\.entries).map(\.id)
        let afterClearing = sections("").flatMap(\.entries).map(\.id)

        expectNoDifference(revealed, ["VESSEL", "CTRL", "DRONEA"])
        // No query and an empty `expandedHosts`: both roots are present but
        // collapsed. "FTL Relay" < "HEAVEN Vessel" lexicographically, so RELAY
        // precedes VESSEL; VESSEL's children stay hidden since nothing forces
        // them open once the query is gone.
        expectNoDifference(afterClearing, ["RELAY", "VESSEL"])
    }

    /// A host that matches on its own keeps its own collapse state — its
    /// children are pruned out, so it reports no children to disclose.
    @Test func aHostMatchingAloneKeepsItsChildrenHidden() {
        let entries = sections("POLARISUM").flatMap(\.entries)
        expectNoDifference(entries.map(\.id), ["RELAY"])
    }

    @Test func nonMatchingBranchesAreDropped() {
        let entries = sections("ftl_relay").flatMap(\.entries)
        expectNoDifference(entries.map(\.id), ["RELAY"])
    }

    /// Search runs before sectioning; a section left with nothing is dropped.
    @Test func noMatchesYieldsNoSections() {
        expectNoDifference(sections("zzzznothing"), [])
    }

    /// Ancestors are retained even though they don't match, and their
    /// `childCount` reflects the retained children only.
    @Test func retainedAncestorReportsRetainedChildCount() {
        let entries = sections("DRONEA").flatMap(\.entries)
        expectNoDifference(entries.map(\.id), ["VESSEL", "CTRL", "DRONEA"])
        expectNoDifference(entries.map(\.childCount), [1, 1, 0])
    }

    /// A flagged device promoted into Needs Attention is searchable there too.
    @Test func attentionSectionIsFilteredToo() {
        let flaggedFleet = fleet + [makeDevice("HURT", type: "mining_drone", capacity: 5)]
        let result = DeviceListLayout.sections(
            fleet: flaggedFleet,
            attentionDirectives: [],
            searchText: "mining",
            expandedHosts: [],
            collapsedGroups: []
        )
        expectNoDifference(result.map(\.id), [DeviceListSection.attentionID])
        expectNoDifference(result[0].entries.map(\.id), ["HURT"])
    }
}
