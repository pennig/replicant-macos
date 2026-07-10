//
//  LocationEventPolicy.swift
//  Replicould — GameServices
//
//  Pure decision logic for the composition root's passive-scan / roster-location
//  relay route (the `locations.scan` route in `ReplicantApp`). Given a game
//  `event` and the replicant it concerns, it decides two things:
//
//    • whether the replicant's current system is worth a passive re-scan, and
//    • whether a *host-vessel arrival* advanced the replicant's roster location
//      (so `currentStar`/`currentLocation` can be folded in immediately, without
//      waiting on the next `accounts/me` refresh).
//
//  A scan only ever reads the replicant's *current* location, so an event is
//  worth a scan only when it actually concerns that location:
//    • an arrival matters only when it's the replicant's own host vessel that
//      moved (gate on `deviceCode == hostedDeviceCode`) — an arrival of some
//      other device leaves the replicant put; and
//    • a location-scoped event (shop / asteroid / object / megastructure / …)
//      matters only when it happened in the system the replicant is currently in
//      (gate on the event's system matching `currentStar`).
//
//  Extracted from the route so the policy is unit-testable without the relay, the
//  database, or the scan side effect.
//

import API
import Foundation
import GameModels
import Utils

public enum LocationEventPolicy {

    /// Event types (substring-matched, case-insensitive) that describe a change
    /// at a *location* — worth a scan only when that location is the replicant's
    /// current system. Arrivals are handled separately (host-device gated).
    static let locationScopedTriggers = ["megastructure", "contribut", "object", "asteroid", "shop", "location_event"]

    /// A roster location advance carried by a host-vessel arrival.
    public struct RosterLocationUpdate: Equatable, Sendable {
        public var star: String
        public var location: String
        /// True when the system changed, so the cached star display name is now
        /// stale (the arrival payload carries no display names).
        public var systemChanged: Bool

        public init(star: String, location: String, systemChanged: Bool) {
            self.star = star
            self.location = location
            self.systemChanged = systemChanged
        }
    }

    /// What a relay event implies for the replicant's current location.
    public struct Decision: Equatable, Sendable {
        /// Whether the current system should be (passively) re-scanned.
        public var shouldScan: Bool
        /// The roster location advance to apply first, if the arrival moved the
        /// replicant. Nil for non-arrivals, unchanged locations, or arrivals that
        /// carry no location.
        public var rosterUpdate: RosterLocationUpdate?

        public init(shouldScan: Bool, rosterUpdate: RosterLocationUpdate? = nil) {
            self.shouldScan = shouldScan
            self.rosterUpdate = rosterUpdate
        }

        /// The event concerns nothing about the replicant's location.
        public static let ignore = Decision(shouldScan: false, rosterUpdate: nil)
    }

    /// Decide what a relay `event` implies for `replicant`'s current location.
    public static func decide(event: UnifiedEvent, replicant: Replicant) -> Decision {
        let type = (event.eventType ?? "").lowercased()
        let isArrival = type.contains("arrived")
        let isLocationScoped = locationScopedTriggers.contains(where: type.contains)
        guard isArrival || isLocationScoped else { return .ignore }

        if isArrival {
            // Only the replicant's own host vessel moving changes its location.
            guard let device = event.deviceCode, device == replicant.hostedDeviceCode else {
                return .ignore
            }
            return Decision(shouldScan: true, rosterUpdate: arrivalUpdate(event: event, replicant: replicant))
        }
        // Location-scoped: relevant only in the replicant's current system.
        let match = replicant.currentStar != nil && system(for: event) == replicant.currentStar
        return Decision(shouldScan: match)
    }

    /// The star system an event concerns, if its payload names a place: `star` is
    /// already a system designation; `location` / `planet` / `designation` are
    /// location codes whose system is the prefix before the first hyphen
    /// (`ATIANFU-1-L4` → `ATIANFU`). Nil when the payload names none.
    public static func system(for event: UnifiedEvent) -> String? {
        let payload = event.payload
        func systemPrefix(_ key: String) -> String? {
            guard let value = payload?[key]?.stringValue else { return nil }
            let prefix = String(value.split(separator: "-").first ?? "")
            return prefix.isEmpty ? nil : prefix
        }
        return payload?["star"]?.stringValue
            ?? systemPrefix("location") ?? systemPrefix("planet") ?? systemPrefix("designation")
    }

    /// The roster advance an arrival carries: the destination `location` (and
    /// `star`, else its system prefix), when it differs from what we hold. Nil if
    /// the arrival names no location or the replicant is already there.
    static func arrivalUpdate(event: UnifiedEvent, replicant: Replicant) -> RosterLocationUpdate? {
        guard let location = event.payload?["location"]?.stringValue, !location.isEmpty else { return nil }
        let star = event.payload?["star"]?.stringValue ?? String(location.split(separator: "-").first ?? "")
        guard location != replicant.currentLocation || star != replicant.currentStar else { return nil }
        return RosterLocationUpdate(star: star, location: location, systemChanged: star != replicant.currentStar)
    }
}
