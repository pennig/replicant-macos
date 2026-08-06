//
//  DeviceListGroupingTests.swift
//  Replicould — Devices feature tests
//
//  The grouping dimension and the partition each of its cases produces.
//

import CustomDump
import Foundation
import GameModels
import Testing
@testable import DevicesFeature

@Suite struct DeviceGroupingTests {

    /// The declaration order is the picker's order, so it is asserted rather
    /// than left to the reader of the enum.
    @Test func casesAreInPickerOrder() {
        expectNoDifference(
            DeviceGrouping.allCases,
            [.carrier, .type, .system, .mission, .flat]
        )
    }

    /// Raw values are persisted to app storage, so renaming one silently resets
    /// every operator's saved choice to the default.
    @Test func rawValuesAreStorageAndDoNotDrift() {
        expectNoDifference(
            DeviceGrouping.allCases.map(\.rawValue),
            ["carrier", "type", "system", "mission", "flat"]
        )
    }

    @Test func everyCaseIsPresentable() {
        for grouping in DeviceGrouping.allCases {
            #expect(!grouping.label.isEmpty)
            #expect(!grouping.symbol.isEmpty)
            expectNoDifference(grouping.id, grouping.rawValue)
        }
    }

    /// Only three cases partition the fleet into headered sections. Carrier and
    /// Flat produce one unheadered section and never reach `buckets`.
    @Test func onlyThreeCasesCarryADimension() {
        expectNoDifference(DeviceGrouping.carrier.dimension, nil)
        expectNoDifference(DeviceGrouping.flat.dimension, nil)
        expectNoDifference(DeviceGrouping.type.dimension, .type)
        expectNoDifference(DeviceGrouping.system.dimension, .system)
        expectNoDifference(DeviceGrouping.mission.dimension, .mission)
    }
}

@Suite struct DeviceListBucketTests {

    private func hosts(_ devices: [Device]) -> [String: Device] {
        Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Type

    @Test func typeBucketsOnDeviceTypeAndTitlesWithTheDisplayName() {
        let relay = makeDevice("AAAA", type: "ftl_relay")
        expectNoDifference(
            DeviceListLayout.buckets(for: relay, dimension: .type, hosts: [:]),
            [GroupBucket(id: "type:ftl_relay", title: "FTL Relay", isDesignation: false, sortsLast: false)]
        )
    }

    // MARK: System

    /// `ATIANFU-1-L4` and `ATIANFU-BELT-1` are the same system, which is the
    /// whole point of the roll-up: 51 sites collapse to far fewer systems.
    @Test func systemRollsSitesUpToTheFirstSegment() {
        let inner = makeDevice("AAAA", location: "ATIANFU-1-L4")
        let belt = makeDevice("BBBB", location: "ATIANFU-BELT-1")
        expectNoDifference(
            DeviceListLayout.buckets(for: inner, dimension: .system, hosts: [:]),
            [GroupBucket(id: "system:ATIANFU", title: "ATIANFU", isDesignation: true, sortsLast: false)]
        )
        expectNoDifference(
            DeviceListLayout.buckets(for: belt, dimension: .system, hosts: [:]).map(\.id),
            ["system:ATIANFU"]
        )
    }

    /// A drone in a controller in a vessel is wherever the vessel is — the right
    /// answer for every locationless device in a carrier.
    @Test func aLocationlessDeviceInheritsItsHostsSystemThroughTwoLevels() {
        let vessel = makeDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let controller = makeDevice("CTRL", type: "ami_survey_controller", stowedIn: "VESSEL")
        let drone = makeDevice("DRONE", stowedIn: "VESSEL", controlledBy: "CTRL")
        let byCode = hosts([vessel, controller, drone])
        expectNoDifference(DeviceListLayout.systemKey(for: controller, hosts: byCode), "SOL")
        expectNoDifference(DeviceListLayout.systemKey(for: drone, hosts: byCode), "SOL")
    }

    @Test func aLocationlessHostlessDeviceFallsToUnknown() {
        let adrift = makeDevice("AAAA")
        expectNoDifference(DeviceListLayout.systemKey(for: adrift, hosts: [:]), nil)
        expectNoDifference(
            DeviceListLayout.buckets(for: adrift, dimension: .system, hosts: [:]),
            [GroupBucket(id: "system:unknown", title: "Unknown", isDesignation: false, sortsLast: true)]
        )
    }

    /// An unresolved host is not a location, and the walk must not mistake it
    /// for one.
    @Test func anUnresolvedHostFallsToUnknown() {
        let orphan = makeDevice("AAAA", stowedIn: "NOTINFLEET")
        expectNoDifference(DeviceListLayout.systemKey(for: orphan, hosts: [:]), nil)
    }

    /// The inheritance walk climbs declared hosts, so it must survive the same
    /// cycle the forest already guards against.
    @Test func aCycleInTheHostChainTerminates() {
        let a = makeDevice("AAAA", stowedIn: "BBBB")
        let b = makeDevice("BBBB", stowedIn: "AAAA")
        let byCode = hosts([a, b])
        expectNoDifference(DeviceListLayout.systemKey(for: a, hosts: byCode), nil)
        expectNoDifference(
            DeviceListLayout.buckets(for: a, dimension: .system, hosts: byCode).map(\.id),
            ["system:unknown"]
        )
    }

    /// A device with its own location never consults its host.
    @Test func ownLocationBeatsTheHosts() {
        let vessel = makeDevice("VESSEL", type: "heaven_vessel", location: "SOL-3")
        let drone = makeDevice("DRONE", location: "ESELLUSAU-1", stowedIn: "VESSEL")
        expectNoDifference(
            DeviceListLayout.systemKey(for: drone, hosts: hosts([vessel, drone])),
            "ESELLUSAU"
        )
    }

    // MARK: Mission

    @Test func missionBucketsOneSectionPerTag() {
        let tagged = makeDevice("AAAA", tags: ["auto:survey"])
        expectNoDifference(
            DeviceListLayout.buckets(for: tagged, dimension: .mission, hosts: [:]),
            [GroupBucket(id: "mission:auto:survey", title: "auto:survey", isDesignation: false, sortsLast: false)]
        )
    }

    /// Mission is a facet, not a partition: a two-tag device appears under both
    /// sections and the headers then sum above the fleet count.
    @Test func aMultiTagDeviceBucketsUnderEachTag() {
        let both = makeDevice("AAAA", tags: ["taxi", "auto:haul"])
        expectNoDifference(
            DeviceListLayout.buckets(for: both, dimension: .mission, hosts: [:]).map(\.id),
            ["mission:auto:haul", "mission:taxi"]
        )
    }

    @Test func anUntaggedDeviceFallsToUntagged() {
        expectNoDifference(
            DeviceListLayout.buckets(for: makeDevice("AAAA"), dimension: .mission, hosts: [:]),
            [GroupBucket(id: "mission:untagged", title: "Untagged", isDesignation: false, sortsLast: true)]
        )
    }

    /// Every dimension places every device somewhere — a device that bucketed
    /// nowhere would vanish from the list.
    @Test func everyDimensionPlacesEveryDevice() {
        let fleet = [
            makeDevice("AAAA", type: "ftl_relay", location: "SOL-1"),
            makeDevice("BBBB", tags: ["taxi"]),
            makeDevice("CCCC"),
        ]
        let byCode = hosts(fleet)
        for dimension in [GroupDimension.type, .system, .mission] {
            for device in fleet {
                #expect(!DeviceListLayout.buckets(for: device, dimension: dimension, hosts: byCode).isEmpty)
            }
        }
    }
}
