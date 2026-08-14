import Foundation
import GameModels
import Testing
@testable import DirectiveEngine

@Suite("Brain device reservation")
struct BrainAttachReservationTests {
    private func device(
        _ code: String, attachedTo: String? = nil, stowedIn: String? = nil
    ) -> Device {
        Device(
            deviceCode: code, deviceType: "surge_carrier", replicantCode: "R1", status: "idle",
            location: "HUB-1", locationName: nil, operationalCapacity: 100, queueSize: 0,
            stowedInDeviceCode: stowedIn, controllerDeviceCode: nil, attachedToDeviceCode: attachedTo,
            createdAt: .distantPast, availableCommands: [], features: [], tags: [],
            detail: .object([:]), updatedAt: .distantPast, firstSeenAt: .distantPast
        )
    }

    private func directive(on code: String) -> Directive {
        Directive(
            id: "d1", kind: .eventRun, status: .running, deviceCode: code,
            controllerCode: nil, roamCentre: nil, fleetTag: nil, sourceRelayCode: nil,
            targets: [], targetIndex: 0, step: "preflight", stepStartedAt: .distantPast,
            returnToOrigin: true, originDesignation: nil, attentionReason: nil,
            createdAt: .distantPast, updatedAt: .distantPast
        )
    }

    @Test("a device attached to a leased carrier is reserved")
    func downward() {
        let devices = [
            "CARRIER": device("CARRIER"),
            "COURIER": device("COURIER", attachedTo: "CARRIER"),
            "BEACON": device("BEACON", attachedTo: "CARRIER"),
            "LOOSE": device("LOOSE"),
        ]
        let reserved = Brain.reservedDevices(
            directives: [directive(on: "CARRIER")], devices: devices
        )
        #expect(reserved == ["CARRIER", "COURIER", "BEACON"])
    }

    @Test("leasing an attached device reserves the hull carrying it")
    func upward() {
        let devices = [
            "CARRIER": device("CARRIER"),
            "COURIER": device("COURIER", attachedTo: "CARRIER"),
        ]
        let reserved = Brain.reservedDevices(
            directives: [directive(on: "COURIER")], devices: devices
        )
        #expect(reserved == ["COURIER", "CARRIER"])
    }

    @Test("an attach edge naming a device the fleet lacks reserves nothing extra")
    func dangling() {
        let devices = ["COURIER": device("COURIER", attachedTo: "GHOST")]
        let reserved = Brain.reservedDevices(
            directives: [directive(on: "COURIER")], devices: devices
        )
        #expect(reserved == ["COURIER"])
    }
}
