//
//  RepairFleet.swift
//  Replicould — DirectiveEngine
//
//  The service-bot queries the repair phases share. Pure by contract, like
//  every mission query: no I/O, no clock, no randomness.
//

import GameModels

/// Fleet queries over a `WorldSnapshot` already in hand, shared by every mission
/// that carries service bots.
public enum RepairFleet {
    /// Capacity below which a fleet is worth holding for repair.
    public static let repairThreshold: Double = 50

    /// The service bots stowed aboard `vessel` in `world`, identified by the
    /// `service` directive rather than `device_type` so a differently-named
    /// repair device still matches.
    public static func bots(aboard vessel: Device, in world: WorldSnapshot) -> [Device] {
        world.devices.values
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
            .filter { $0.availableDirectives.contains("service") }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// The service bots standing at `location` in `world`. A stowed device has no
    /// location, so this returns only genuinely deployed bots.
    public static func bots(deployedAt location: String?, in world: WorldSnapshot) -> [Device] {
        guard let location else { return [] }
        return world.devices.values
            .filter { $0.stowedInDeviceCode == nil && $0.location == location }
            .filter { $0.availableDirectives.contains("service") }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// Whether `bot` is mid-repair, from the `repair` block the server populates
    /// with the target and its progress.
    public static func isRepairing(_ bot: Device) -> Bool {
        bot.detail["repair"]?["target_device_code"]?.stringValue != nil
    }

    /// Whether any of `devices` is worn enough to hold the fleet for.
    public static func needsRepair(_ devices: [Device]) -> Bool {
        devices.contains { $0.operationalCapacity < repairThreshold }
    }

    /// Everything a repair gate judges: the bots standing in the system plus
    /// whatever is stowed aboard `vessel`, which by departure is every drone.
    public static func fleet(of vessel: Device, in world: WorldSnapshot) -> [Device] {
        let aboard = world.devices.values.filter { $0.stowedInDeviceCode == vessel.deviceCode }
        return (bots(deployedAt: vessel.location, in: world) + aboard)
            .sorted { $0.deviceCode < $1.deviceCode }
    }
}
