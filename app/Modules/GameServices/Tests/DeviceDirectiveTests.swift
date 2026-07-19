//
//  DeviceDirectiveTests.swift
//  Replicould — GameServices
//
//  The AMI-directive accessors that back the inspector's `set_directive` picker:
//  the available directive vocabulary and the directive currently in force are
//  both read out of the device's variable `detail` tail.
//

import Foundation
import GameModels
import Testing
import Utils
@testable import GameServices

@Suite struct DeviceDirectiveTests {

    private func device(type: String = "ami_survey_controller", detail: JSONValue) -> Device {
        Device(
            deviceCode: "E45C43AB", deviceType: type, replicantCode: "R1",
            status: "coordinating", location: nil, locationName: nil, operationalCapacity: 100,
            queueSize: 0, stowedInDeviceCode: nil, controllerDeviceCode: nil,
            attachedToDeviceCode: nil, createdAt: Date(timeIntervalSince1970: 0),
            availableCommands: ["set_directive", "clear_directive"], features: [], tags: [],
            detail: detail, updatedAt: Date(timeIntervalSince1970: 1_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func controller(detail: JSONValue) -> Device { device(detail: detail) }

    /// A survey controller's `available_directives` and the current `ami_directive.name`
    /// are pulled straight out of the detail tail.
    @Test func parsesDirectiveVocabularyAndCurrent() {
        let device = controller(detail: .object([
            "available_directives": .array([.string("survey_system"), .string("belt_search")]),
            "ami_directive": .object([
                "name": .string("survey_system"),
                "config": .object([
                    "planets": .string("all"), "moons": .string("none"), "recall": .bool(true),
                ]),
            ]),
        ]))
        #expect(device.availableDirectives == ["survey_system", "belt_search"])
        #expect(device.currentDirective == "survey_system")
        #expect(device.currentDirectiveConfig?["planets"]?.stringValue == "all")
        #expect(device.currentDirectiveConfig?["moons"]?.stringValue == "none")
        #expect(device.currentDirectiveConfig?["recall"]?.boolValue == true)
    }

    /// A transport controller advertises its four directives, and an in-force
    /// `delivery` carries a nested `route` object plus a per-resource
    /// `requirement` — the shape the inspector's delivery config reads and writes.
    @Test func parsesTransportDeliveryDirective() {
        let device = device(type: "ami_transport_controller", detail: .object([
            "available_directives": .array([
                .string("delivery"), .string("ferry"), .string("shuttle"), .string("consolidate"),
            ]),
            "ami_directive": .object([
                "name": .string("delivery"),
                "config": .object([
                    "route": .object([
                        "collect": .string("ATIANFU-BELT-1"),
                        "deliver": .string("ALPHERATOZ-8-L4"),
                    ]),
                    "requirement": .object(["carbon": .number(50), "silicates": .number(100)]),
                ]),
            ]),
        ]))
        #expect(device.availableDirectives == ["delivery", "ferry", "shuttle", "consolidate"])
        #expect(device.currentDirective == "delivery")
        let config = device.currentDirectiveConfig
        #expect(config?["route"]?["collect"]?.stringValue == "ATIANFU-BELT-1")
        #expect(config?["route"]?["deliver"]?.stringValue == "ALPHERATOZ-8-L4")
        #expect(config?["requirement"]?["carbon"]?.numberValue == 50)
        #expect(config?["requirement"]?["silicates"]?.numberValue == 100)
    }

    /// A continuous transport directive (`shuttle`/`ferry`) carries flat
    /// `collect`/`deliver` endpoints and an ordered `priority` array.
    @Test func parsesTransportShuttleDirective() {
        let device = device(type: "ami_transport_controller", detail: .object([
            "ami_directive": .object([
                "name": .string("shuttle"),
                "config": .object([
                    "collect": .string("SOL-BELT-1"),
                    "deliver": .string("SOL-3-L4"),
                    "priority": .array([.string("carbon"), .string("rares")]),
                ]),
            ]),
        ]))
        #expect(device.currentDirective == "shuttle")
        let config = device.currentDirectiveConfig
        #expect(config?["collect"]?.stringValue == "SOL-BELT-1")
        #expect(config?["deliver"]?.stringValue == "SOL-3-L4")
        #expect(config?["priority"]?.arrayValue?.compactMap(\.stringValue) == ["carbon", "rares"])
    }

    /// A device with no directive tail reports an empty vocabulary and nil current —
    /// so the inspector hides the `set_directive` command rather than showing an
    /// empty picker.
    @Test func absentDirectivesAreEmpty() {
        let device = controller(detail: .object([:]))
        #expect(device.availableDirectives.isEmpty)
        #expect(device.currentDirective == nil)
        #expect(device.currentDirectiveConfig == nil)
    }

    /// The maintenance drone and service bot both accept `set_directive` but the
    /// server leaves their runtime `available_directives` empty — the per-type
    /// fallback surfaces their `patrol` directive so the command still appears.
    @Test func fallbackVocabularyForWorkerDevices() {
        #expect(device(type: "maintenance_drone", detail: .object([:])).availableDirectives == ["patrol"])
        #expect(device(type: "service_bot", detail: .object([:])).availableDirectives == ["patrol"])
    }

    /// A device type with a fallback still prefers a non-empty runtime list, so a
    /// server that later advertises directives always wins over the fallback.
    @Test func runtimeDirectivesOverrideFallback() {
        let device = device(type: "maintenance_drone", detail: .object([
            "available_directives": .array([.string("patrol"), .string("standby")]),
        ]))
        #expect(device.availableDirectives == ["patrol", "standby"])
    }

    /// A controller's `controlled_devices` yields the codes it already owns, so the
    /// adopt picker can exclude them.
    @Test func parsesControlledDeviceCodes() {
        let controller = device(type: "ami_survey_controller", detail: .object([
            "controlled_devices": .array([
                .object(["device_code": .string("CAA6D3EE"), "device_type": .string("survey_drone")]),
                .object(["device_code": .string("2586E328"), "device_type": .string("survey_drone")]),
            ]),
        ]))
        #expect(controller.controlledDeviceCodes == ["CAA6D3EE", "2586E328"])
        #expect(device(type: "ami_survey_controller", detail: .object([:])).controlledDeviceCodes.isEmpty)
    }

    /// The structured `controlledDevices` carries each device's type/status/location
    /// for the release list's subtitles.
    @Test func parsesControlledDevicesDetail() {
        let controller = device(type: "ami_survey_controller", detail: .object([
            "controlled_devices": .array([
                .object([
                    "device_code": .string("CAA6D3EE"), "device_type": .string("survey_drone"),
                    "status": .string("tracking"), "location": .string("ATIANFU-BELT-1"),
                ]),
            ]),
        ]))
        let first = controller.controlledDevices.first
        #expect(first?.deviceCode == "CAA6D3EE")
        #expect(first?.deviceType == "survey_drone")
        #expect(first?.status == "tracking")
        #expect(first?.location == "ATIANFU-BELT-1")
    }
}
