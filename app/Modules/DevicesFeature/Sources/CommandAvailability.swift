//
//  CommandAvailability.swift
//  Replicould — Devices feature
//
//  Which commands the inspector offers for a device, and the candidate lists that
//  parameterize them. This is policy, not presentation: "can this controller adopt
//  anything", "is this carrier full", "does Replicate have a matrix to spawn into".
//
//  It lived inside `CommandGrid` until V3.6 T6 called it out — real rules embedded
//  in a view, where nothing could reach them. Extracted here per the precedent set
//  by `DevicePresentation`/`DeviceStatusPresentation`, which is also what makes it
//  testable: the fleet-shaped inputs are plain arrays, so a test states a roster
//  and asserts the offered commands without standing up a view or a store.
//
//  Deliberately a top-level enum in its own file rather than statics on the view —
//  pure logic hung off a SwiftUI view traps under `swift test` (see the
//  swiftui-view-statics-trap-in-tests memory note).
//
//  SwiftUI-free by design. Keep it that way.
//

import Foundation
import GameModels

enum CommandAvailability {

    // MARK: Candidate lists

    /// The devices this controller can adopt: fleet members of the type it
    /// shepherds (mining drones for a mining controller, etc.) that it doesn't
    /// already control. Empty for a non-controller.
    static func adoptCandidates(device: Device, fleet: [Device]) -> [DeviceOption] {
        guard let type = DeviceCommand.controllableType(for: device.deviceType) else { return [] }
        let controlled = Set(device.controlledDeviceCodes)
        return fleet
            .filter { $0.deviceType == type && !controlled.contains($0.deviceCode) }
            .map { DeviceOption(id: $0.deviceCode, subtitle: adoptSubtitle($0)) }
    }

    /// "Idle · ATIANFU-1" — a candidate's status and where it is, for the row.
    private static func adoptSubtitle(_ device: Device) -> String {
        let status = device.statusBase.capitalized
        if let place = device.locationName ?? device.location { return "\(status) · \(place)" }
        return status
    }

    /// The devices this controller already controls, for the release checkbox list.
    static func releaseCandidates(device: Device) -> [DeviceOption] {
        device.controlledDevices.map {
            DeviceOption(id: $0.deviceCode, subtitle: controlledSubtitle($0))
        }
    }

    /// "Tracking · ATIANFU-BELT-1" — a controlled device's status and location.
    private static func controlledSubtitle(_ device: Device.ControlledDevice) -> String {
        let status = (device.status?.isEmpty == false ? device.status! : device.deviceType).capitalized
        if let place = device.location, !place.isEmpty { return "\(status) · \(place)" }
        return status
    }

    /// The devices this carrier could attach: fleet members sharing its location
    /// that aren't already attached to something. Empty when the device can't
    /// attach or reports no location of its own. Capacity is *not* filtered here —
    /// a full carrier still lists candidates so the command surfaces its "full"
    /// notice rather than vanishing. The subtitle is the device's display type, so
    /// an entry reads "Mining Drone · 32658E70".
    static func attachCandidates(device: Device, fleet: [Device]) -> [DeviceOption] {
        guard device.features.contains("attach"), device.attachCapacity > 0 else { return [] }
        guard let location = device.location, !location.isEmpty else { return [] }
        let attached = Set(device.attachedDeviceCodes)
        return fleet
            .filter {
                $0.deviceCode != device.deviceCode
                    && $0.location == location
                    && $0.attachedToDeviceCode == nil
                    && !attached.contains($0.deviceCode)
            }
            .map { DeviceOption(id: $0.deviceCode, subtitle: DevicePresentation.displayName($0.deviceType)) }
    }

    /// The devices currently attached to this carrier, for the detach dropdown. The
    /// codes come from the carrier's `attached_devices` tail; the display type is
    /// looked up in the fleet so the entry reads "Autofactory · 43C9B54A". Empty
    /// when nothing is attached.
    static func detachCandidates(device: Device, fleet: [Device]) -> [DeviceOption] {
        device.attachedDeviceCodes.map { code in
            let type = fleet.first { $0.deviceCode == code }?.deviceType
            return DeviceOption(id: code, subtitle: type.map(DevicePresentation.displayName) ?? "Attached")
        }
    }

    /// The vessels this device could be stowed into: fleet members sharing its
    /// location that report free stow capacity, excluding the device itself.
    /// Empty when the device reports no location — the stow command then just
    /// confirms and the server stows it in the replicant owner's vessel. The
    /// subtitle pairs the vessel's display type with its free slots, so an entry
    /// reads "Heaven Vessel · 2 free" (the picker appends the device code).
    static func stowTargets(device: Device, fleet: [Device]) -> [DeviceOption] {
        guard let location = device.location, !location.isEmpty else { return [] }
        return fleet
            .filter {
                $0.deviceCode != device.deviceCode
                    && $0.location == location
                    && $0.stowRemaining > 0
            }
            .map { DeviceOption(id: $0.deviceCode, subtitle: "\(DevicePresentation.displayName($0.deviceType)) · \($0.stowRemaining) free") }
    }

    /// The account's other replicants, for the `change_owner` target picker.
    static func ownerCandidates(device: Device, replicants: [Replicant]) -> [DeviceOption] {
        replicants
            .filter { $0.replicantCode != device.replicantCode }
            .map { DeviceOption(id: $0.replicantCode, subtitle: $0.name.isEmpty ? "Replicant" : $0.name) }
    }

    /// Fleet members needing repair — anything under full operational capacity
    /// except the bot itself. The server arbitrates range/eligibility; the gate
    /// here just keeps the picker meaningful ("Mining Drone · 62%").
    static func repairCandidates(device: Device, fleet: [Device]) -> [DeviceOption] {
        fleet
            .filter { $0.deviceCode != device.deviceCode && $0.operationalCapacity < 100 }
            .map { DeviceOption(id: $0.deviceCode, subtitle: "\(DevicePresentation.displayName($0.deviceType)) · \(Int($0.operationalCapacity))%") }
    }

    /// Empty replicant matrices sharing this matrix's location — the vessels a
    /// replication can spawn into (the server requires one at the current
    /// location). Empty hides Replicate.
    static func replicateTargets(device: Device, fleet: [Device]) -> [DeviceOption] {
        guard let location = device.location, !location.isEmpty else { return [] }
        return fleet
            .filter { $0.deviceType == "empty_replicant_matrix" && $0.location == location }
            .map { DeviceOption(id: $0.deviceCode, subtitle: DevicePresentation.displayName($0.deviceType)) }
    }

    // MARK: The offered command set

    /// The dispatchable subset of the device's available commands. `retarget` is
    /// gated on the device actually mining (the server rejects it otherwise);
    /// `set_directive` only surfaces when the device offers directives, and
    /// `adopt`/`release` only when there are devices to act on — empty pickers
    /// otherwise.
    static func commands(
        device: Device,
        fleet: [Device],
        replicants: [Replicant],
        channels: [String]
    ) -> [DeviceCommand] {
        let adopt = adoptCandidates(device: device, fleet: fleet)
        let release = releaseCandidates(device: device)
        let attach = attachCandidates(device: device, fleet: fleet)
        let detach = detachCandidates(device: device, fleet: fleet)
        let owners = ownerCandidates(device: device, replicants: replicants)
        let attachedNow = device.attachedDeviceCodes.count
        let capacity = device.attachCapacity
        let repairable = repairCandidates(device: device, fleet: fleet)
        let replicateCandidates = replicateTargets(device: device, fleet: fleet)
        let stowInto = stowTargets(device: device, fleet: fleet)
        return device.availableCommands
            .compactMap {
                DeviceCommand(
                    command: $0,
                    availableDirectives: device.availableDirectives,
                    adoptCandidates: adopt,
                    releaseCandidates: release,
                    attachCandidates: attach,
                    attachedCount: attachedNow,
                    attachCapacity: capacity,
                    detachCandidates: detach,
                    currentMode: device.taxiMode,
                    ownerCandidates: owners,
                    channels: channels,
                    repairCandidates: repairable,
                    replicateTargets: replicateCandidates,
                    stowTargets: stowInto
                )
            }
            .filter { command in
                switch command {
                case .retarget:                return device.status.lowercased().contains("mining")
                case let .setDirective(opts):   return !opts.isEmpty
                case let .adopt(candidates):    return !candidates.isEmpty
                case let .release(controlled):  return !controlled.isEmpty
                case let .attach(candidates, _, _): return !candidates.isEmpty
                case let .detach(attached):     return !attached.isEmpty
                case let .changeOwner(owners):  return !owners.isEmpty
                case let .message(channels):    return !channels.isEmpty
                case let .repair(candidates):   return !candidates.isEmpty
                case let .replicate(targets):   return !targets.isEmpty
                // Cargo commands only make sense while the transport is stationed at
                // a location: Load needs free hold space, Unload needs cargo aboard.
                case .loadCargo:   return device.cargoRemaining > 0 && device.location?.isEmpty == false
                case .unloadCargo: return !device.cargoItems.isEmpty && device.location?.isEmpty == false
                default:                       return true
                }
            }
    }
}
