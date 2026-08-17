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

    /// Whether `bot` answers to the fleet tagged `owner` — exactly, by either
    /// side's unscoped form, or, wearing no fleet tag, to anyone. Root-tolerant
    /// in BOTH directions while the fleet is half-migrated.
    public static func answers(_ bot: Device, to owner: FleetTag?) -> Bool {
        guard bot.tags.contains(where: { Device.normalizedTag($0).hasPrefix(FleetTag.prefix) })
        else { return true }
        guard let owner else { return false }
        if bot.carries(owner, policy: .exactOrUnscoped) { return true }
        return !owner.isScoped && bot.fleetTags.contains { $0.goal == owner.goal }
    }

    /// The service bots stowed aboard `vessel` in `world` that answer to `owner`,
    /// identified by the `service` directive rather than `device_type` so a
    /// differently-named repair device still matches.
    public static func bots(
        aboard vessel: Device, in world: WorldSnapshot, owner: FleetTag? = nil
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
        deployedNear location: String?, in world: WorldSnapshot, owner: FleetTag? = nil
    ) -> [Device] {
        guard let location else { return [] }
        return deployed(in: world, system: SiteAssay.system(of: location), owner: owner)
    }

    /// The service bots answering to `owner` that a departure must not leave: those
    /// deployed in `location`'s system, plus any in transit under an open operation.
    /// A recall clears the bot's location for its whole cruise home.
    public static func botsOut(
        near location: String?, in world: WorldSnapshot, owner: FleetTag? = nil
    ) -> [Device] {
        (bots(deployedNear: location, in: world, owner: owner) + inTransit(in: world, owner: owner))
            .sorted { $0.deviceCode < $1.deviceCode }
    }

    /// Whether `world` holds a deployed service bot answering to `owner` — what a
    /// step with no vessel location must answer before waiting on bots. Narrowed to
    /// `system` where the caller knows one.
    public static func anyBotDeployed(
        in world: WorldSnapshot, system: String?, owner: FleetTag? = nil
    ) -> Bool {
        !deployed(in: world, system: system, owner: owner).isEmpty
    }

    /// `anyBotDeployed` widened to count a bot in transit, for the steps that
    /// answer it in order to decide whether the run may leave the system.
    public static func anyBotOut(
        in world: WorldSnapshot, system: String?, owner: FleetTag? = nil
    ) -> Bool {
        anyBotDeployed(in: world, system: system, owner: owner)
            || !inTransit(in: world, owner: owner).isEmpty
    }

    private static func inTransit(in world: WorldSnapshot, owner: FleetTag?) -> [Device] {
        world.devices.values
            .filter { $0.stowedInDeviceCode == nil && $0.location == nil }
            .filter { $0.availableDirectives.contains("service") }
            .filter { answers($0, to: owner) }
            .filter { world.openOperation(for: $0.deviceCode) != nil }
    }

    private static func deployed(
        in world: WorldSnapshot, system: String?, owner: FleetTag?
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
        of vessel: Device, in world: WorldSnapshot, owner: FleetTag? = nil
    ) -> [Device] {
        let aboard = world.devices.values.filter { $0.stowedInDeviceCode == vessel.deviceCode }
        return (bots(deployedNear: vessel.location, in: world, owner: owner) + aboard)
            .sorted { $0.deviceCode < $1.deviceCode }
    }
}
