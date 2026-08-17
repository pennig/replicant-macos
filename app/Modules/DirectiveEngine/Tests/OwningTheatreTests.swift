//
//  OwningTheatreTests.swift
//  Replicould — DirectiveEngine
//
//  The theatre partition, by device (`Brain.owningTheatre`) and by system.
//

import Foundation
import GameModels
import Testing
import UniverseModels
@testable import DirectiveEngine

@Suite("Owning theatre")
struct OwningTheatreTests {
    @Test("A device in a theatre's own system is owned by that theatre")
    func ownSystemIsOwned() {
        let view = twoTheatreView()
        let device = deviceFixture(code: "V1", location: "AINALRAM-2-L4")
        #expect(Brain.owningTheatre(of: device, view: view, goal: nil)?.depot == "AINALRAM-BELT-1")
    }

    @Test("With two operational theatres, a device is owned by exactly one")
    func exactlyOneOwner() {
        let view = twoTheatreView()
        let device = deviceFixture(code: "V1", location: "OMEROPE-BELT-1")
        let owner = Brain.owningTheatre(of: device, view: view, goal: nil)
        #expect(owner?.depot == "DENEBED-BELT-1")
        #expect(owner?.depot != "AINALRAM-BELT-1")
    }

    @Test("A device with no location is owned by no theatre")
    func noLocationOwnsNothing() {
        let view = twoTheatreView()
        let device = deviceFixture(code: "V1", location: nil)
        #expect(Brain.owningTheatre(of: device, view: view, goal: nil) == nil)
    }

    @Test("A device in a system absent from the census is owned by no theatre")
    func offCensusOwnsNothing() {
        let view = twoTheatreView()
        let device = deviceFixture(code: "V1", location: "NOWHERE-1")
        #expect(Brain.owningTheatre(of: device, view: view, goal: nil) == nil)
    }

    @Test("Resolution is deterministic across repeated calls")
    func deterministic() {
        let view = twoTheatreView()
        let device = deviceFixture(code: "V1", location: "GRAZ-1-L4")
        let first = Brain.owningTheatre(of: device, view: view, goal: nil)
        let second = Brain.owningTheatre(of: device, view: view, goal: nil)
        #expect(first == second)
        #expect(first?.depot == "AINALRAM-BELT-1")
    }

    @Test("The nearest fallback wins when the device's own component has no theatre")
    func fallbackWinsAcrossComponents() {
        let view = WorldView(
            devices: [:],
            starPositions: ["REMOTE": Position(x: 0, y: 0, z: 0), "FARAWAY": Position(x: 3, y: 4, z: 0)],
            meshSystems: ["REMOTE", "FARAWAY"],
            salvageUnits: [:], eventSystems: [],
            theatres: [
                Theatre(depot: "FARAWAY-BELT-1", system: "FARAWAY", origin: .derived,
                        readiness: .operational, stock: 500),
            ],
            components: ["REMOTE": "REMOTE", "FARAWAY": "FARAWAY"],
            now: Date(timeIntervalSince1970: 5_000)
        )
        let device = deviceFixture(code: "V1", location: "REMOTE-1")
        #expect(Brain.owningTheatre(of: device, view: view, goal: nil)?.depot == "FARAWAY-BELT-1")
    }

    // MARK: - The system-taking seam

    /// `owningTheatre(ofSystem:)` must answer exactly what the device-taking
    /// resolver answers for a device standing in that system — one rule,
    /// two entry points.
    @Test("owningTheatre(ofSystem:) agrees with the device-taking resolver")
    func systemSeamAgreesWithDeviceResolver() {
        let view = twoTheatreView()
        #expect(view.owningTheatre(ofSystem: "AINALRAM")?.depot == "AINALRAM-BELT-1")
        #expect(view.owningTheatre(ofSystem: "OMEROPE")?.depot == "DENEBED-BELT-1")
    }

    @Test("owningTheatre(ofSystem:) is nil for a system absent from the census")
    func systemSeamOffCensusOwnsNothing() {
        #expect(twoTheatreView().owningTheatre(ofSystem: "NOWHERE") == nil)
    }
}
