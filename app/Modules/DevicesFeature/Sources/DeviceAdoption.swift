//
//  DeviceAdoption.swift
//  Replicould — Devices feature
//
//  Who an AMI controller has adopted, and who adopted a device. Both ends of the
//  link are read, because either one alone is incomplete in normal operation.
//
//  SwiftUI-free by design, per `CommandAvailability`. Keep it that way.
//

import Foundation
import GameModels

enum DeviceAdoption {

    /// One end of an adoption link: the code, plus the fleet's record of it when
    /// the fleet has loaded that device.
    struct Link: Equatable, Identifiable, Sendable {
        let deviceCode: String
        let device: Device?
        var id: String { deviceCode }
    }

    /// Whether this device type shepherds a feature, and so can adopt at all.
    static func canAdopt(_ device: Device) -> Bool {
        DeviceCommand.controllableFeature(for: device.deviceType) != nil
    }

    /// The devices this controller has adopted, from both ends of the link:
    /// its own `controlled_devices` tail, which only a single-device read
    /// populates, and every fleet member naming it as their controller.
    static func adopted(by controller: Device, fleet: [Device]) -> [Link] {
        let byFleet = fleet.filter { $0.controllerDeviceCode == controller.deviceCode }
        var codes = Set(byFleet.map(\.deviceCode))
        codes.formUnion(controller.controlledDeviceCodes)
        return codes.sorted().map { link(code: $0, fleet: fleet) }
    }

    /// The controller that adopted this device, or nil when nothing has. The
    /// code comes from the device's own promoted column, which survives both a
    /// list sync and stowing.
    static func controller(of device: Device, fleet: [Device]) -> Link? {
        guard let code = device.controllerDeviceCode, !code.isEmpty else { return nil }
        return link(code: code, fleet: fleet)
    }

    private static func link(code: String, fleet: [Device]) -> Link {
        Link(deviceCode: code, device: fleet.first { $0.deviceCode == code })
    }
}
