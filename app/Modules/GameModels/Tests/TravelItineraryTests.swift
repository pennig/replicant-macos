//
//  TravelItineraryTests.swift
//  Replicould — GameModels
//
//  The one itinerary rule every travel surface reads, and the normalization of
//  the backend's bare-system proxy codes.
//
//  The backend names a travel destination two ways in the SAME payload: a bare
//  system designation (`ASTELLIO`) standing in for that system's entry point,
//  and the resolved code (`ASTELLIO-1-L4`). Which one appears where varies by
//  endpoint, so the map used to anchor a riser on the star while the sidebar
//  named the Lagrange point. These pin the substitution down.
//

import Foundation
import Testing
import Utils
@testable import GameModels

/// A leg with just the fields the normalization reads.
private func leg(_ index: Int, _ from: String?, _ to: String?) -> TravelSnapshot.Leg {
    TravelSnapshot.Leg(index: index, from: from, fromName: nil, to: to, toName: nil,
                       type: nil, timeSeconds: nil, active: false)
}

private func snapshot(origin: String? = nil, destination: String? = nil,
                      legs: [TravelSnapshot.Leg] = []) -> TravelSnapshot {
    var s = TravelSnapshot(travelObject: .object(["destination": .string("PLACEHOLDER")]))!
    s.origin = origin
    s.destination = destination
    s.legs = legs
    return s
}

struct TravelItinerarySelectionTests {
    @Test func prefersTheFrozenDispatchRouteWhenItHasLegs() {
        let stored = snapshot(destination: "MEREDIANA-3",
                              legs: [leg(1, "AINALRAM-BELT-1", "AINALRAM-1-L4")])
        let live = snapshot(destination: "AINALRAM-BELT-1", legs: [leg(1, "X-1", "X-2")])

        #expect(TravelSnapshot.itinerary(stored: stored, live: live)?.destination == "MEREDIANA-3")
    }

    @Test func fallsBackToTheLiveBlockWhenTheStoredRouteHasNoLegs() {
        // A surge-plate command response carries no `route` at all.
        let stored = snapshot(origin: "SOL-3", destination: "AINALRAM")
        let live = snapshot(destination: "AINALRAM-BELT-1",
                            legs: [leg(1, "AINALRAM-1-L4", "AINALRAM-BELT-1")])

        #expect(TravelSnapshot.itinerary(stored: stored, live: live)?.legs.count == 1)
        #expect(TravelSnapshot.itinerary(stored: stored, live: live)?.destination == "AINALRAM-BELT-1")
    }

    @Test func fallsBackToTheLiveBlockWhenThereIsNoStoredRoute() {
        let live = snapshot(destination: "AINALRAM-BELT-1")
        #expect(TravelSnapshot.itinerary(stored: nil, live: live)?.destination == "AINALRAM-BELT-1")
    }

    @Test func isNilWhenNeitherSourceExists() {
        #expect(TravelSnapshot.itinerary(stored: nil, live: nil) == nil)
    }
}

struct SystemProxyResolutionTests {
    @Test func proxyDiscrimination() {
        #expect(TravelSnapshot.isSystemProxy("ASTELLIO"))
        #expect(!TravelSnapshot.isSystemProxy("ASTELLIO-1-L4"))
        #expect(!TravelSnapshot.isSystemProxy("SOL-BELT-1"))
        #expect(!TravelSnapshot.isSystemProxy(""))
    }

    /// The live block for a device mid-surge to a bare system: the leg names the
    /// proxy, `final_destination` names the entry point. The riser must anchor on
    /// the entry point, not the star.
    @Test func proxyResolvesFromTheItinerarysOwnDestination() {
        let s = snapshot(origin: "ALKALUROP-3-L4", destination: "ASTELLIO-1-L4",
                         legs: [leg(1, "ALKALUROP-3-L4", "ASTELLIO")])

        #expect(s.resolvingSystemProxies.legs[0].to == "ASTELLIO-1-L4")
    }

    /// When another leg already names a specific code in that system, it wins over
    /// the destination — it is nearer in the route.
    @Test func proxyResolvesToTheNearestSpecificCodeInTheSameSystem() {
        let s = snapshot(origin: "SOL-3", destination: "MEREDIANA-3",
                         legs: [leg(1, "SOL-3", "MEREDIANA"),
                                leg(2, "MEREDIANA-4-L4", "MEREDIANA-3")])

        #expect(s.resolvingSystemProxies.legs[0].to == "MEREDIANA-4-L4")
    }

    /// Nothing specific is known for that system anywhere in the itinerary, so the
    /// proxy survives untouched — we never invent an entry point.
    @Test func proxyWithNothingSpecificToSubstituteIsLeftAlone() {
        let s = snapshot(origin: "SOL-3", destination: "AINALRAM",
                         legs: [leg(1, "SOL-3", "AINALRAM")])

        #expect(s.resolvingSystemProxies.legs[0].to == "AINALRAM")
    }

    /// A route that visits one system twice resolves each proxy against its OWN
    /// neighbourhood, not a single global pick for that system.
    @Test func eachProxyResolvesAgainstItsOwnPositionInTheRoute() {
        let s = snapshot(origin: "SOL-3", destination: "MID-4",
                         legs: [leg(1, "SOL-3", "MID"),
                                leg(2, "MID-1-L4", "FAR-2"),
                                leg(3, "FAR-2", "MID"),
                                leg(4, "MID-9-L5", "MID-4")])
        let r = s.resolvingSystemProxies

        #expect(r.legs[0].to == "MID-1-L4")   // nearest downstream neighbour
        #expect(r.legs[2].to == "MID-9-L5")   // nearest to THIS proxy, not the first
    }

    /// A specific `from` in a foreign system is untouched, and a leg missing an
    /// endpoint entirely stays missing.
    @Test func specificCodesAndMissingEndpointsPassThrough() {
        let s = snapshot(origin: "SOL-3", destination: "ASTELLIO-1-L4",
                         legs: [leg(1, "SOL-3", nil), leg(2, nil, "ASTELLIO-1-L4")])
        let r = s.resolvingSystemProxies

        #expect(r.legs[0].from == "SOL-3")
        #expect(r.legs[0].to == nil)
        #expect(r.legs[1].from == nil)
        #expect(r.legs[1].to == "ASTELLIO-1-L4")
    }

    /// Normalization rewrites LEG endpoints only. `origin`/`destination` are read as
    /// substitution sources but left as the backend sent them, so the labels the
    /// sidebar and device detail already render correctly are not disturbed.
    @Test func originAndDestinationAreNotRewritten() {
        let s = snapshot(origin: "AINALRAM", destination: "ASTELLIO-1-L4",
                         legs: [leg(1, "AINALRAM-1-L4", "ASTELLIO")])
        let r = s.resolvingSystemProxies

        #expect(r.origin == "AINALRAM")
        #expect(r.destination == "ASTELLIO-1-L4")
        #expect(r.legs[0].to == "ASTELLIO-1-L4")
    }
}
