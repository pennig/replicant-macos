//
//  RepairFleet.swift
//  Replicould — DirectiveEngine
//
//  The service-bot queries the repair phases share. Pure by contract, like
//  every mission query: no I/O, no clock, no randomness.
//

import GameModels
import UniverseModels

/// Fleet queries over a `WorldSnapshot` already in hand, shared by every mission
/// that carries service bots.
public enum RepairFleet {
    /// Capacity below which a fleet is worth holding for repair.
    public static let repairThreshold: Double = 50

    /// The prefix that marks a tag as a fleet's own.
    public static let fleetTagPrefix = "auto:"

    /// Whether `bot` answers to the fleet tagged `owner`. A bot wearing a fleet
    /// tag answers to that fleet alone; one wearing none answers to whoever asks,
    /// which is what keeps an untagged pair working for a run that has no tag.
    public static func answers(_ bot: Device, to owner: String?) -> Bool {
        let owned = bot.tags.filter { $0.hasPrefix(fleetTagPrefix) }
        if owned.isEmpty { return true }
        return owner.map(owned.contains) ?? false
    }

    /// The service bots stowed aboard `vessel` in `world` that answer to `owner`,
    /// identified by the `service` directive rather than `device_type` so a
    /// differently-named repair device still matches.
    public static func bots(
        aboard vessel: Device, in world: WorldSnapshot, owner: String? = nil
    ) -> [Device] {
        world.devices.values
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
            .filter { $0.availableDirectives.contains("service") }
            .filter { answers($0, to: owner) }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// The service bots answering to `owner` deployed anywhere in `location`'s STAR
    /// SYSTEM. System-scoped, never site-scoped: the bot cruises to each damaged
    /// device, so a site filter loses one doing its job.
    public static func bots(
        deployedNear location: String?, in world: WorldSnapshot, owner: String? = nil
    ) -> [Device] {
        guard let location else { return [] }
        return deployed(in: world, system: SiteAssay.system(of: location), owner: owner)
    }

    /// Whether `world` holds a deployed service bot answering to `owner` — what a
    /// step with no vessel location must answer before waiting on bots. Narrowed to
    /// `system` where the caller knows one.
    public static func anyBotDeployed(
        in world: WorldSnapshot, system: String?, owner: String? = nil
    ) -> Bool {
        !deployed(in: world, system: system, owner: owner).isEmpty
    }

    private static func deployed(
        in world: WorldSnapshot, system: String?, owner: String?
    ) -> [Device] {
        world.devices.values
            .filter { $0.stowedInDeviceCode == nil && $0.availableDirectives.contains("service") }
            .filter { bot in system.map { bot.location.map(SiteAssay.system(of:)) == $0 } ?? true }
            .filter { answers($0, to: owner) }
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// The open operation a bot recall may legitimately wait on, or nil. An
    /// operation carrying no `completesAt` can never resolve — a `recall` at a bot
    /// already co-located stows instantly — so waiting on it waits on nothing.
    public static func openRecall(
        for deviceCode: String, in world: WorldSnapshot
    ) -> GameModels.Operation? {
        world.openOperation(for: deviceCode).flatMap { $0.completesAt == nil ? nil : $0 }
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

    /// Whether `bot` carries an ACTIVE `service` directive — the name alone is
    /// not enough, since a `service` directive read `paused` repairs nothing.
    public static func isArmed(_ bot: Device) -> Bool {
        bot.currentDirective == "service" && bot.currentDirectiveStatus == "active"
    }

    /// Everything a repair gate judges: the bots standing in the system plus
    /// whatever is stowed aboard `vessel`, which by departure is every drone.
    public static func fleet(
        of vessel: Device, in world: WorldSnapshot, owner: String? = nil
    ) -> [Device] {
        let aboard = world.devices.values.filter { $0.stowedInDeviceCode == vessel.deviceCode }
        return (bots(deployedNear: vessel.location, in: world, owner: owner) + aboard)
            .sorted { $0.deviceCode < $1.deviceCode }
    }
}
