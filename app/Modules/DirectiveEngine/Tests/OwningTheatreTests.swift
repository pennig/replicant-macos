//
//  OwningTheatreTests.swift
//  Replicould — DirectiveEngine
//
//  `Brain.owningTheatre(of:view:)` — the per-device theatre partition.
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
        #expect(Brain.owningTheatre(of: device, view: view)?.depot == "AINALRAM-BELT-1")
    }

    @Test("With two operational theatres, a device is owned by exactly one")
    func exactlyOneOwner() {
        let view = twoTheatreView()
        let device = deviceFixture(code: "V1", location: "OMEROPE-BELT-1")
        let owner = Brain.owningTheatre(of: device, view: view)
        #expect(owner?.depot == "DENEBED-BELT-1")
        #expect(owner?.depot != "AINALRAM-BELT-1")
    }

    @Test("A device with no location is owned by no theatre")
    func noLocationOwnsNothing() {
        let view = twoTheatreView()
        let device = deviceFixture(code: "V1", location: nil)
        #expect(Brain.owningTheatre(of: device, view: view) == nil)
    }

    @Test("A device in a system absent from the census is owned by no theatre")
    func offCensusOwnsNothing() {
        let view = twoTheatreView()
        let device = deviceFixture(code: "V1", location: "NOWHERE-1")
        #expect(Brain.owningTheatre(of: device, view: view) == nil)
    }

    @Test("Resolution is deterministic across repeated calls")
    func deterministic() {
        let view = twoTheatreView()
        let device = deviceFixture(code: "V1", location: "GRAZ-1-L4")
        let first = Brain.owningTheatre(of: device, view: view)
        let second = Brain.owningTheatre(of: device, view: view)
        #expect(first == second)
        #expect(first?.depot == "AINALRAM-BELT-1")
    }
}
