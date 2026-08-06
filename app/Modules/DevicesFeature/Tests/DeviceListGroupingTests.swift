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
}
