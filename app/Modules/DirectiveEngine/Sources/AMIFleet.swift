//
//  AMIFleet.swift
//  Replicould — DirectiveEngine
//
//  The adoption/stowage queries every AMI-controller-driven mission needs,
//  shared so a correction to either lands in exactly one place rather than
//  drifting between copies.
//
//  Pure by contract, like every mission query: no I/O, no clock, no randomness.
//

import GameModels

/// Fleet queries over a `WorldSnapshot` already in hand, shared by every mission
/// that stages an AMI controller aboard a vessel.
public enum AMIFleet {
    /// A device in `world` stowed aboard `vessel` that offers `directive` among
    /// its available directives — an AMI controller identified by CAPABILITY
    /// rather than `device_type`, so a differently-named controller with the
    /// same capability still matches.
    ///
    /// The fallback vocabulary behind `availableDirectives` covers only repair
    /// devices, so it can never make a non-controller match here.
    ///
    /// STOWED, not merely co-located: `launch` deploys the controller's stowed
    /// devices, and one left standing alongside the vessel is left behind the
    /// moment it departs.
    public static func stowed(
        aboard vessel: Device, in world: WorldSnapshot, offering directive: String
    ) -> Device? {
        world.devices.values
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
            .filter { $0.availableDirectives.contains(directive) }
            .min { $0.deviceCode < $1.deviceCode }
    }

    /// The drones `controller` has adopted, per `world`, that are also stowed
    /// aboard `vessel`. Both halves matter: `launch` only deploys devices this
    /// controller has adopted, and only ones that actually travelled with it.
    public static func adoptedDrones(
        of controller: Device, aboard vessel: Device, in world: WorldSnapshot
    ) -> [Device] {
        adoptedDrones(of: controller, in: world)
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
    }

    /// Every device in `world` that `controller` has adopted, wherever it
    /// currently is — including the ones still deployed. The recall gate needs
    /// the whole set (the `aboard:` variant answers a different question: who
    /// came along), because "some drones are home" is precisely the state that
    /// loses the others.
    ///
    /// Adoption is read from BOTH ends of the link. The controller's side,
    /// `controlled_devices`, ships only in the single-device payload and a
    /// fleet-wide list sync rewrites the whole `detail` blob over it, so reading
    /// that end alone reports a perfectly staged vessel as unstaged. The drone's
    /// side, `controller_device_code`, is a promoted column present in every
    /// payload.
    public static func adoptedDrones(of controller: Device, in world: WorldSnapshot) -> [Device] {
        let claimed = Set(controller.controlledDeviceCodes)
        return world.devices.values
            .filter { $0.controllerDeviceCode == controller.deviceCode || claimed.contains($0.deviceCode) }
            .sorted { $0.deviceCode < $1.deviceCode }
    }
}
