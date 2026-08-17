//
//  MineRecipe.swift
//  Replicould — DirectiveEngine
//
//  The mine-fleet recipe as data, and the fleet-membership queries the print
//  run, the mine run, and the brain's readiness verdicts share.
//

import Foundation
import GameModels

/// The eleven-device mine fleet: what to print, what rides the carrier, and
/// how to recognise the pieces in device rows.
public enum MineRecipe {
    public static let fleetTag = FleetTag(goal: .mine)

    /// The tag `Brain.ensureMine` stamps on the mineRun DIRECTIVE row — never
    /// on recipe MEMBERS, which stay bare-tagged from print. Mirrors
    /// `SurveyRun.fleetTag(forTheatre:)`.
    public static func fleetTag(forTheatre depot: String) -> FleetTag {
        FleetTag(goal: .mine, scope: .theatre(depot: depot))
    }

    /// The carrier pool's tag — the one definition; `EventRun` reuses it.
    public static let carrierTag = FleetTag(goal: .carrier)
    public static let carrierDeviceType = "surge_carrier"

    /// The nine that ride the carrier to the belt.
    public static let carried: [(deviceType: String, quantity: Int)] = [
        ("ami_mining_controller", 1),
        ("mining_drone", 3),
        ("ami_survey_controller", 1),
        ("survey_drone", 2),
        ("service_bot", 2),
    ]

    /// The two that stay at the hub or move themselves.
    public static let selfMoving: [(deviceType: String, quantity: Int)] = [
        ("ami_transport_controller", 1),
        ("cargo_freighter", 1),
    ]

    public static var all: [(deviceType: String, quantity: Int)] { carried + selfMoving }

    /// Whether `device` is a free recipe member standing at `hub`: tagged, idle,
    /// unadopted, unattached, unstowed, and running no AMI directive.
    public static func isUnassigned(_ device: Device, hub: String) -> Bool {
        device.carries(fleetTag, policy: .exact)
            && device.location == hub
            && device.stowedInDeviceCode == nil
            && device.attachedToDeviceCode == nil
            && device.controllerDeviceCode == nil
            && device.currentDirective == nil
    }

    /// Free recipe members at `hub` by type, lowest-coded first, capped at each
    /// type's recipe quantity so a surplus never inflates the fleet.
    public static func unassignedFleet(
        at hub: String, in devices: some Sequence<Device>
    ) -> [String: [Device]] {
        let free = devices.filter { isUnassigned($0, hub: hub) }
        var out: [String: [Device]] = [:]
        for (type, quantity) in all {
            out[type] = free
                .filter { $0.deviceType == type }
                .sorted { $0.deviceCode < $1.deviceCode }
                .prefix(quantity)
                .map { $0 }
        }
        return out
    }

    /// Recipe slots not yet standing free at `hub`. Empty means a full fleet.
    public static func shortfall(
        at hub: String, in devices: some Sequence<Device>
    ) -> [String: Int] {
        let fleet = unassignedFleet(at: hub, in: devices)
        var missing: [String: Int] = [:]
        for (type, quantity) in all {
            let have = fleet[type]?.count ?? 0
            if have < quantity { missing[type] = quantity - have }
        }
        return missing
    }

    /// Belts holding an installed mine: locations of tagged mining controllers
    /// standing away from the hub. Safe only for a single-theatre-scoped
    /// check — never for a global installed/occupied set; use `hubs:` there.
    public static func installedBelts(
        in devices: some Sequence<Device>, hub: String?
    ) -> Set<String> {
        installedBelts(in: devices, hubs: hub.map { [$0] } ?? [])
    }

    /// `installedBelts(in:hub:)` generalised to every depot in `hubs` at
    /// once — filtering one exclusion set, never unioning several: a union
    /// per theatre would re-admit each depot through every OTHER pass.
    public static func installedBelts(
        in devices: some Sequence<Device>, hubs: Set<String>
    ) -> Set<String> {
        Set(
            devices
                .filter { $0.deviceType == "ami_mining_controller" && $0.carries(fleetTag, policy: .exact) }
                .compactMap(\.location)
                .filter { !hubs.contains($0) }
        )
    }

    /// The delivery vehicle: lowest-coded idle tagged surge carrier at `hub`.
    public static func idleCarrier(
        at hub: String, in devices: some Sequence<Device>
    ) -> Device? {
        devices
            .filter {
                $0.deviceType == carrierDeviceType && $0.carries(carrierTag, policy: .exact)
                    && $0.location == hub && $0.status == "idle"
            }
            .min { $0.deviceCode < $1.deviceCode }
    }
}
