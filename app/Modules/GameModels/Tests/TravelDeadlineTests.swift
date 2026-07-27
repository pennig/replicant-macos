//
//  TravelDeadlineTests.swift
//  Replicould — GameModels
//
//  Resolving a `travel` block's deadline from its two parallel timing sets.
//
//  The rule is NOT "always the route end". A surge plate mid-hop reports a
//  perfectly live active leg alongside a `final_arrives_at` left over from a
//  previous route — days in the past — and preferring that unconditionally
//  births every travel op already overdue.
//

import Foundation
import Testing
import Utils
@testable import GameModels

private func travellingDevice(_ travel: [String: JSONValue], status: String = "travelling") -> Device {
    Device(
        deviceCode: "PLATE1", deviceType: "surge_plate", replicantCode: "R1", status: status,
        location: nil, locationName: nil, operationalCapacity: 100, queueSize: 0,
        stowedInDeviceCode: nil, controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0), availableCommands: [], features: [], tags: [],
        detail: .object(["travel": .object(travel)]),
        updatedAt: Date(timeIntervalSince1970: 1_000), firstSeenAt: Date(timeIntervalSince1970: 1_000)
    )
}

private func moment(_ iso: String) throws -> Date {
    try Date(iso, strategy: Date.ISO8601FormatStyle())
}

/// The exact block read off surge plate `DC2209EF` on 2026-07-27 while it was
/// 45% through a live cruise leg. Note `final_arrives_at` three days in the
/// past, `route_eta_seconds: 0` and `route_progress_percent: 100` — the
/// route-level fields describe a journey that already ended, while the leg
/// fields describe the one actually under way.
private let stalePlateTravel: [String: JSONValue] = [
    "departed_at": .string("2026-07-26T23:47:32-05:00"),
    "arrives_at": .string("2026-07-26T23:50:11-05:00"),
    "final_arrives_at": .string("2026-07-23T21:11:01-05:00"),
    "destination": .string("AINALRAM"),
    "final_destination": .string("AINALRAM-BELT-1"),
    "eta_seconds": .number(86.7),
    "progress_percent": .number(45.5),
    "route_eta_seconds": .number(0),
    "route_progress_percent": .number(100),
    "type": .string("surge"),
]

@Suite("Travel deadline resolution")
struct TravelDeadlineTests {
    /// The multi-leg case the route-level preference exists for: the route ends
    /// after the active leg, so it wins and the trip doesn't end a leg early.
    @Test func prefersTheRouteEndWhenItIsLaterThanTheLeg() throws {
        let leg = try moment("2026-06-29T01:33:54-05:00")
        let route = try moment("2026-06-29T01:36:22-05:00")
        #expect(Device.travelDeadline(routeEnd: route, legEnd: leg) == route)
    }

    /// The bug. A route end that predates the active leg cannot be this trip's
    /// end — it is a leftover. The leg is the honest deadline.
    @Test func ignoresARouteEndThatPredatesTheActiveLeg() throws {
        let leg = try moment("2026-07-26T23:50:11-05:00")
        let route = try moment("2026-07-23T21:11:01-05:00")
        #expect(Device.travelDeadline(routeEnd: route, legEnd: leg) == leg)
    }

    /// A single-leg trip reports the same instant twice.
    @Test func acceptsEitherWhenTheyAgree() throws {
        let same = try moment("2026-07-26T23:50:11-05:00")
        #expect(Device.travelDeadline(routeEnd: same, legEnd: same) == same)
    }

    /// Whichever half the payload actually carries is used on its own — an
    /// absent leg is not a reason to discard a route end, or vice versa.
    @Test func fallsBackToWhicheverEndIsPresent() throws {
        let route = try moment("2026-06-29T01:36:22-05:00")
        let leg = try moment("2026-06-29T01:33:54-05:00")
        #expect(Device.travelDeadline(routeEnd: route, legEnd: nil) == route)
        #expect(Device.travelDeadline(routeEnd: nil, legEnd: leg) == leg)
        #expect(Device.travelDeadline(routeEnd: nil, legEnd: nil) == nil)
    }

    /// End to end through `activityDeadline`: the live surge-plate payload
    /// resolves to its active leg, not to the three-day-old route end.
    ///
    /// This is what `DeadlineScheduler` reads to re-arm, and what made it log
    /// "still busy 268370s past its deadline" and mark the op `unknown` on the
    /// very first pass — 215 times in two days across five plates.
    @Test func activityDeadlineIgnoresAStaleRouteEnd() throws {
        let expected = try moment("2026-07-26T23:50:11-05:00")
        #expect(travellingDevice(stalePlateTravel).activityDeadline == expected)
    }

    /// The same rule on the adoption path, which is what stamps an op's
    /// `completesAt` when a device is met mid-flight.
    @Test func derivedActivityIgnoresAStaleRouteEnd() throws {
        let expected = try moment("2026-07-26T23:50:11-05:00")
        let derived = travellingDevice(stalePlateTravel).derivedActivity
        #expect(derived?.kind == .travel)
        #expect(derived?.completesAt == expected)
    }

    /// A genuine multi-leg payload still adopts the route's end here too.
    @Test func derivedActivityKeepsTheRouteEndOnARealMultiLegRoute() throws {
        let device = travellingDevice([
            "departed_at": .string("2026-06-29T01:33:04-05:00"),
            "arrives_at": .string("2026-06-29T01:33:54-05:00"),
            "final_arrives_at": .string("2026-06-29T01:36:22-05:00"),
        ])
        #expect(device.derivedActivity?.completesAt == (try moment("2026-06-29T01:36:22-05:00")))
    }
}
