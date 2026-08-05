//
//  DeviceListCollapseTests.swift
//  Replicould — Devices feature tests
//
//  Flattening: a collapsed host contributes no entries, depth clamps, and the
//  emitted order *is* `orderedIDs` — arrow-key navigation skips hidden rows by
//  construction rather than by a second rule that could drift.
//

import CustomDump
import Foundation
import GameModels
import Testing
@testable import DevicesFeature

@Suite struct DeviceListCollapseTests {

    private var fleet: [Device] {
        [
            makeDevice("VESSEL", type: "heaven_vessel"),
            makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL"),
            makeDevice("DRONEA", stowedIn: "VESSEL", controlledBy: "CTRL"),
            makeDevice("DRONEB", stowedIn: "VESSEL", controlledBy: "CTRL"),
        ]
    }

    private func flatten(expanded: Set<String>, forced: Set<String> = []) -> [DeviceEntry] {
        DeviceListLayout.flatten(
            DeviceListLayout.forest(fleet: fleet),
            expandedHosts: expanded,
            forcedOpen: forced,
            attention: [:]
        )
    }

    @Test func hostsDefaultCollapsed() {
        expectNoDifference(flatten(expanded: []).map(\.id), ["VESSEL"])
    }

    @Test func expandingOneLevelRevealsOnlyThatLevel() {
        expectNoDifference(flatten(expanded: ["VESSEL"]).map(\.id), ["VESSEL", "CTRL"])
    }

    @Test func expandingBothLevelsRevealsTheDrones() {
        expectNoDifference(
            flatten(expanded: ["VESSEL", "CTRL"]).map(\.id),
            ["VESSEL", "CTRL", "DRONEA", "DRONEB"]
        )
    }

    @Test func childCountAndExpansionAreReported() {
        let entries = flatten(expanded: ["VESSEL"])
        expectNoDifference(entries.map(\.childCount), [1, 2])
        expectNoDifference(entries.map(\.isExpanded), [true, false])
    }

    /// A leaf is never "expanded" even if its code sits in `expandedHosts`.
    @Test func leavesAreNeverExpanded() throws {
        let entries = flatten(expanded: ["VESSEL", "CTRL", "DRONEA"])
        let drone = try #require(entries.first { $0.id == "DRONEA" })
        expectNoDifference(drone.childCount, 0)
        expectNoDifference(drone.isExpanded, false)
    }

    @Test func depthIsCarriedAndClamped() {
        let deep = [
            makeDevice("L0", type: "heaven_vessel"),
            makeDevice("L1", type: "ami_survey_controller", stowedIn: "L0"),
            makeDevice("L2", type: "survey_drone", controlledBy: "L1"),
            makeDevice("L3", type: "mining_drone", controlledBy: "L2"),
        ]
        let entries = DeviceListLayout.flatten(
            DeviceListLayout.forest(fleet: deep),
            expandedHosts: ["L0", "L1", "L2"],
            forcedOpen: [],
            attention: [:]
        )
        expectNoDifference(entries.map(\.id), ["L0", "L1", "L2", "L3"])
        expectNoDifference(entries.map(\.depth), [0, 1, 2, 2])
    }

    /// `forcedOpen` reveals a subtree the operator has not opened — the reveal a
    /// search query applies, with `expandedHosts` left empty.
    @Test func forcedOpenRevealsWithoutTouchingExpandedHosts() {
        expectNoDifference(
            flatten(expanded: [], forced: ["VESSEL", "CTRL"]).map(\.id),
            ["VESSEL", "CTRL", "DRONEA", "DRONEB"]
        )
        // And with neither set, the same forest is closed again — proving the
        // reveal lives entirely in the argument, not in any stored state.
        expectNoDifference(flatten(expanded: []).map(\.id), ["VESSEL"])
    }

    @Test func badgeCarriesTheNonWinningRelation() throws {
        let entries = flatten(expanded: ["VESSEL", "CTRL"])
        let drone = try #require(entries.first { $0.id == "DRONEA" })
        expectNoDifference(drone.host, .stowed(in: "VESSEL"))
        let controller = try #require(entries.first { $0.id == "CTRL" })
        expectNoDifference(controller.host, nil)
    }

    @Test func attentionFlagsAreAttachedByCode() {
        let entries = DeviceListLayout.flatten(
            DeviceListLayout.forest(fleet: fleet),
            expandedHosts: [],
            forcedOpen: [],
            attention: ["VESSEL": [.outOfControlRange]]
        )
        expectNoDifference(entries.map(\.attention), [[.outOfControlRange]])
    }
}
