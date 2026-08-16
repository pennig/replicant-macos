//
//  DeviceAdoptionTests.swift
//  Replicould — Devices feature tests
//
//  Covers `DeviceAdoption` — who a controller has adopted, and who adopted a
//  device. The link is readable from either end and the two ends disagree in
//  normal operation, which is what these cases pin.
//

import CustomDump
import Foundation
import GameModels
import Testing
import Utils
@testable import DevicesFeature

@Suite("DeviceAdoption")
struct DeviceAdoptionTests {

    /// A minimal `Device`. `controlled` seeds the `controlled_devices` tail that
    /// only a single-device read populates.
    private func device(
        code: String,
        type: String,
        status: String = "idle",
        location: String? = nil,
        controlledBy: String? = nil,
        features: [String] = [],
        commands: [String] = [],
        controlled: [(code: String, type: String)] = []
    ) -> Device {
        let epoch = Date(timeIntervalSince1970: 0)
        var detail: [String: JSONValue] = [:]
        if !controlled.isEmpty {
            detail["controlled_devices"] = .array(controlled.map {
                .object([
                    "device_code": .string($0.code),
                    "device_type": .string($0.type),
                    "status": .string("tracking"),
                    "location": .string("SOL-3"),
                ])
            })
        }
        return Device(
            deviceCode: code,
            deviceType: type,
            replicantCode: "R1",
            status: status,
            location: location,
            locationName: nil,
            operationalCapacity: 100,
            queueSize: 0,
            stowedInDeviceCode: nil,
            controllerDeviceCode: controlledBy,
            attachedToDeviceCode: nil,
            createdAt: epoch,
            availableCommands: commands,
            features: features,
            tags: [],
            detail: .object(detail),
            updatedAt: epoch,
            firstSeenAt: epoch
        )
    }

    // MARK: Reading the link from either end

    /// The ordinary state: a fleet sync has wiped the controller's tail, so the
    /// drones' own column is the only surviving record of the adoption.
    @Test func adoptedIsReadableFromTheDroneEndAlone() {
        let controller = device(code: "C1", type: "ami_survey_controller")
        let d1 = device(code: "D1", type: "survey_drone", controlledBy: "C1")
        let d2 = device(code: "D2", type: "survey_drone", controlledBy: "C1")
        let stranger = device(code: "D3", type: "survey_drone", controlledBy: "C2")

        let adopted = DeviceAdoption.adopted(by: controller, fleet: [d1, d2, stranger])
        expectNoDifference(adopted.map(\.deviceCode), ["D1", "D2"])
        expectNoDifference(adopted.map { $0.device?.deviceCode }, ["D1", "D2"])
    }

    /// The other end: a single-device read has populated `controlled_devices`
    /// while the drone rows are still list-synced and carry no controller.
    @Test func adoptedIsReadableFromTheControllerEndAlone() {
        let controller = device(code: "C1", type: "ami_survey_controller",
                                controlled: [("D1", "survey_drone")])
        let d1 = device(code: "D1", type: "survey_drone")

        let adopted = DeviceAdoption.adopted(by: controller, fleet: [d1])
        expectNoDifference(adopted.map(\.deviceCode), ["D1"])
        #expect(adopted.first?.device?.deviceCode == "D1")
    }

    /// Both ends agreeing on a device must yield one row, not two.
    @Test func adoptedUnionsTheTwoEndsWithoutDuplicating() {
        let controller = device(code: "C1", type: "ami_mining_controller",
                                controlled: [("D1", "mining_drone"), ("D2", "mining_drone")])
        let d1 = device(code: "D1", type: "mining_drone", controlledBy: "C1")
        let d3 = device(code: "D3", type: "mining_drone", controlledBy: "C1")

        expectNoDifference(
            DeviceAdoption.adopted(by: controller, fleet: [d1, d3]).map(\.deviceCode),
            ["D1", "D2", "D3"])
    }

    /// A code the fleet hasn't loaded still yields a row, so the count is honest.
    @Test func anUnknownCodeStillYieldsARow() {
        let controller = device(code: "C1", type: "ami_survey_controller",
                                controlled: [("D9", "survey_drone")])
        let adopted = DeviceAdoption.adopted(by: controller, fleet: [])
        expectNoDifference(adopted.map(\.deviceCode), ["D9"])
        #expect(adopted.first?.device == nil)
    }

    @Test func aControllerHoldingNothingAdoptsNothing() {
        let controller = device(code: "C1", type: "ami_survey_controller")
        let loose = device(code: "D1", type: "survey_drone")
        #expect(DeviceAdoption.adopted(by: controller, fleet: [loose]).isEmpty)
    }

    // MARK: The adopter, from the adopted device's side

    @Test func controllerResolvesTheAdopterAgainstTheFleet() {
        let drone = device(code: "D1", type: "survey_drone", controlledBy: "C1")
        let controller = device(code: "C1", type: "ami_survey_controller")

        let link = DeviceAdoption.controller(of: drone, fleet: [controller])
        #expect(link?.deviceCode == "C1")
        #expect(link?.device?.deviceType == "ami_survey_controller")
    }

    @Test func anUnadoptedDeviceHasNoController() {
        let drone = device(code: "D1", type: "survey_drone")
        #expect(DeviceAdoption.controller(of: drone, fleet: []) == nil)
    }

    /// An adopter the fleet hasn't loaded is still reported, by code.
    @Test func anUnknownControllerIsStillReportedByCode() {
        let drone = device(code: "D1", type: "survey_drone", controlledBy: "C9")
        let link = DeviceAdoption.controller(of: drone, fleet: [])
        #expect(link?.deviceCode == "C9")
        #expect(link?.device == nil)
    }

    // MARK: The section's own gate

    @Test func onlyAMIControllersCanAdopt() {
        #expect(DeviceAdoption.canAdopt(device(code: "C1", type: "ami_survey_controller")))
        #expect(DeviceAdoption.canAdopt(device(code: "C2", type: "ami_mining_controller")))
        #expect(DeviceAdoption.canAdopt(device(code: "C3", type: "ami_transport_controller")))
        #expect(!DeviceAdoption.canAdopt(device(code: "V1", type: "heaven_vessel")))
    }

    // MARK: The pickers read the same union

    /// The exclusion list must cover devices adopted via the drone's own column,
    /// or a list-synced controller offers to adopt what it already holds.
    @Test func adoptCandidatesExcludeDevicesAdoptedViaTheDroneColumn() {
        let controller = device(code: "C1", type: "ami_survey_controller", commands: ["adopt"])
        let held = device(code: "D1", type: "survey_drone", controlledBy: "C1",
                          features: ["cruise", "survey"])
        let free = device(code: "D2", type: "survey_drone", features: ["cruise", "survey"])

        expectNoDifference(
            CommandAvailability.adoptCandidates(device: controller, fleet: [held, free]).map(\.id),
            ["D2"])
    }

    /// Release must survive a list sync too — the tail is gone, but the drones
    /// still name their controller, and an empty candidate list hides the verb.
    @Test func releaseCandidatesSurviveAListSync() {
        let controller = device(code: "C1", type: "ami_survey_controller", commands: ["release"])
        let held = device(code: "D1", type: "survey_drone", status: "tracking",
                          location: "SOL-3", controlledBy: "C1", features: ["survey"])

        expectNoDifference(
            CommandAvailability.releaseCandidates(device: controller, fleet: [held]),
            [DeviceOption(id: "D1", subtitle: "Tracking · SOL-3")])
    }
}
