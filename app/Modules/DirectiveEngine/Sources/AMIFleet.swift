//
//  AMIFleet.swift
//  Replicould — DirectiveEngine
//
//  The adoption/stowage queries every AMI-controller-driven mission needs,
//  shared so a correction to either lands in exactly one place rather than
//  drifting between copies (extracted from `SurveyRun`, 2026-07-30, operator
//  ruling — `SalvageRun` needs the identical two-ended read and duplicating it
//  was rejected outright).
//
//  Pure by contract, like every mission query: no I/O, no clock, no randomness.
//

import GameModels

/// Fleet queries shared by every mission that stages an AMI controller aboard a
/// vessel. Plain namespace — no TCA, no I/O — over a `WorldSnapshot` already in
/// hand.
public enum AMIFleet {
    /// A device stowed aboard `vessel` that offers `directive` among its
    /// available directives — an AMI controller identified by CAPABILITY
    /// (e.g. `survey_system`, `gather_salvage`) rather than `device_type`, so a
    /// differently-named controller with the same capability still works. The
    /// fallback vocabulary behind `availableDirectives` covers only repair
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

    /// The controller's adopted drones that are also aboard the vessel. Both
    /// halves matter: `launch` only deploys devices this controller has adopted,
    /// and only ones that actually travelled with it.
    ///
    /// Adoption is read from BOTH ends of the link, because only one end is
    /// always present. `controlled_devices` — the controller's side — ships only
    /// in the single-device payload (`GET devices/{code}`); the fleet-wide
    /// `GET devices` omits it entirely, and since a list sync rewrites the whole
    /// `detail` blob it also erases whatever a previous inspector read had put
    /// there. The drone's side, `controller_device_code`, is a promoted column
    /// present in every payload. Reading only the controller's side meant a
    /// perfectly staged vessel looked unstaged unless someone had recently
    /// opened that controller's inspector.
    public static func adoptedDrones(
        of controller: Device, aboard vessel: Device, in world: WorldSnapshot
    ) -> [Device] {
        adoptedDrones(of: controller, in: world)
            .filter { $0.stowedInDeviceCode == vessel.deviceCode }
    }

    /// Every device this controller has adopted, wherever it currently is —
    /// including the ones still deployed. The recall gate needs the whole set
    /// (the `aboard:` variant above answers a different question: who came
    /// along), because "some drones are home" is precisely the state that loses
    /// the others.
    public static func adoptedDrones(of controller: Device, in world: WorldSnapshot) -> [Device] {
        let claimed = Set(controller.controlledDeviceCodes)
        return world.devices.values
            .filter { $0.controllerDeviceCode == controller.deviceCode || claimed.contains($0.deviceCode) }
            .sorted { $0.deviceCode < $1.deviceCode }
    }
}
