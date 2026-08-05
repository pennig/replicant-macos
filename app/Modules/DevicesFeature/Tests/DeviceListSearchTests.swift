//
//  DeviceListSearchTests.swift
//  Replicould — Devices feature tests
//
//  `DeviceListLayout` search: AND across whitespace-split terms, OR across the
//  per-device haystack fields, case- and diacritic-insensitive.
//

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
