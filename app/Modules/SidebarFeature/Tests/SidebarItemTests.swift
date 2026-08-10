//
//  SidebarItemTests.swift
//  Replicould — Sidebar feature
//
//  Guards the Logistics sidebar case's five wiring points.
//

import Testing
@testable import SidebarFeature

@Suite struct SidebarItemTests {
    @Test func logisticsSitsInOperationsAndHasNoDetailPane() {
        #expect(SidebarItem.logistics.title == "Logistics")
        #expect(SidebarItem.logistics.symbol == "shippingbox")
        #expect(!SidebarItem.logistics.hasDetail)
        let operations = SidebarItem.groups.first { $0.id == "Operations" }
        #expect(operations?.items.contains(.logistics) == true)
    }
}
