//
//  ReplicationEligibilityTests.swift
//  Replicould — GameServices tests
//
//  Covers the pure `ReplicationEligibility.resolve` checklist/target logic: a
//  fully-eligible fleet plus each way a requirement can fall short.
//

import Foundation
import GameModels
import Testing

@Suite("ReplicationEligibility.resolve")
struct ReplicationEligibilityTests {
    /// Build a minimal `Device` for the resolver — only the fields it reads matter.
    private func device(
        code: String,
        type: String,
        location: String? = nil,
        stowedIn: String? = nil,
        features: [String] = [],
        commands: [String] = [],
        status: String = "idle",
        inControlRange: Bool? = nil
    ) -> Device {
        let epoch = Date(timeIntervalSince1970: 0)
        return Device(
            deviceCode: code,
            deviceType: type,
            replicantCode: "R1",
            status: status,
            location: location,
            locationName: nil,
            operationalCapacity: 1,
            queueSize: 0,
            stowedInDeviceCode: stowedIn,
            controllerDeviceCode: nil,
            attachedToDeviceCode: nil,
            createdAt: epoch,
            availableCommands: commands,
            features: features,
            tags: [],
            detail: inControlRange.map { .object(["in_control_range": .bool($0)]) } ?? .object([:]),
            updatedAt: epoch,
            firstSeenAt: epoch
        )
    }

    /// A host vessel at SOL-3 with a `replicate`-capable `replicant_matrix` stowed
    /// inside it, plus an empty matrix stowed in a cradle-equipped vessel at the
    /// same location → fully eligible. `hostDeviceCode` is the vessel ("HOST1"),
    /// not the matrix; the stowed matrix carries no location of its own.
    private func eligibleFleet() -> [Device] {
        [
            device(code: "HOST1", type: "heaven_vessel", location: "SOL-3", features: ["cradle"]),
            device(code: "MATRIX1", type: "replicant_matrix", stowedIn: "HOST1", commands: ["replicate"]),
            device(code: "VESSEL1", type: "transport_vessel", location: "SOL-3", features: ["cradle"]),
            device(code: "EMPTY1", type: "empty_replicant_matrix", stowedIn: "VESSEL1"),
        ]
    }

    @Test("Fully eligible fleet can replicate")
    func fullyEligible() {
        let result = ReplicationEligibility.resolve(hostDeviceCode: "HOST1", devices: eligibleFleet())
        #expect(result.canReplicate)
        #expect(result.sourceMatrixCode == "MATRIX1")
        #expect(result.targets.map(\.deviceCode) == ["EMPTY1"])
        let allMet = result.requirements.allSatisfy(\.isMet)
        #expect(allMet)
    }

    @Test("No empty matrix leaves the fleet ineligible")
    func noEmptyMatrix() {
        var fleet = eligibleFleet()
        fleet.removeAll { $0.deviceType == "empty_replicant_matrix" }
        let result = ReplicationEligibility.resolve(hostDeviceCode: "HOST1", devices: fleet)
        #expect(!result.canReplicate)
        #expect(result.targets.isEmpty)
        #expect(result.requirements.first { $0.id == "empty" }?.isMet == false)
    }

    @Test("Empty matrix not stowed in a cradle is not a valid target")
    func notInCradle() {
        var fleet = eligibleFleet()
        // Strip the cradle feature from the carrier.
        fleet = fleet.map { dev in
            guard dev.deviceCode == "VESSEL1" else { return dev }
            return device(code: "VESSEL1", type: "transport_vessel", location: "SOL-3", features: [])
        }
        let result = ReplicationEligibility.resolve(hostDeviceCode: "HOST1", devices: fleet)
        #expect(!result.canReplicate)
        #expect(result.targets.isEmpty)
        #expect(result.requirements.first { $0.id == "cradle" }?.isMet == false)
    }

    @Test("Cradle at a different location fails the co-location requirement")
    func cradleWrongLocation() {
        var fleet = eligibleFleet()
        fleet = fleet.map { dev in
            guard dev.deviceCode == "VESSEL1" else { return dev }
            return device(code: "VESSEL1", type: "transport_vessel", location: "SOL-4", features: ["cradle"])
        }
        let result = ReplicationEligibility.resolve(hostDeviceCode: "HOST1", devices: fleet)
        #expect(!result.canReplicate)
        #expect(result.targets.isEmpty)
        // The empty is stowed in a cradle, so that line is met…
        #expect(result.requirements.first { $0.id == "cradle" }?.isMet == true)
        // …but the cradle isn't co-located with the matrix.
        #expect(result.requirements.first { $0.id == "colocated" }?.isMet == false)
    }

    @Test("An empty matrix in the source's own host vessel is not a valid target")
    func emptyInSourceVessel() {
        // The only empty matrix is stowed in HOST1 — the source matrix's own
        // host vessel — so it can't be a replication target even though HOST1
        // has the cradle feature and is trivially co-located.
        var fleet = eligibleFleet()
        fleet.removeAll { $0.deviceCode == "VESSEL1" || $0.deviceCode == "EMPTY1" }
        fleet.append(device(code: "EMPTY1", type: "empty_replicant_matrix", stowedIn: "HOST1"))
        let result = ReplicationEligibility.resolve(hostDeviceCode: "HOST1", devices: fleet)
        #expect(!result.canReplicate)
        #expect(result.targets.isEmpty)
        #expect(result.requirements.first { $0.id == "cradle" }?.isMet == false)
    }

    @Test("A host that can't issue replicate yields no source matrix")
    func matrixCannotReplicate() {
        var fleet = eligibleFleet()
        fleet = fleet.map { dev in
            guard dev.deviceCode == "MATRIX1" else { return dev }
            return device(code: "MATRIX1", type: "replicant_matrix", stowedIn: "HOST1", commands: [])
        }
        let result = ReplicationEligibility.resolve(hostDeviceCode: "HOST1", devices: fleet)
        #expect(!result.canReplicate)
        #expect(result.sourceMatrixCode == nil)
        #expect(result.requirements.first { $0.id == "matrix" }?.isMet == false)
    }

    // MARK: - Matrix hint accuracy
    //
    // The matrix line fails for several structurally different reasons, and the
    // hint has to name the one that actually applies. It used to hard-code
    // "bring it into control range or wait for its current task to finish" for
    // every unavailable-command case, which sent the player chasing conditions
    // that were already satisfied (the live `pennig-scan` report: an in-range,
    // idle matrix that simply lacks the `matrix` feature).

    /// The matrix the resolver should pick, with the fields under test.
    private func fleet(
        matrixFeatures: [String],
        matrixStatus: String = "stowed",
        matrixInControlRange: Bool? = nil
    ) -> [Device] {
        var fleet = eligibleFleet()
        fleet = fleet.map { dev in
            guard dev.deviceCode == "MATRIX1" else { return dev }
            return device(
                code: "MATRIX1",
                type: "replicant_matrix",
                stowedIn: "HOST1",
                features: matrixFeatures,
                commands: [],
                status: matrixStatus,
                inControlRange: matrixInControlRange
            )
        }
        return fleet
    }

    private func matrixHint(_ fleet: [Device]) -> String? {
        ReplicationEligibility.resolve(hostDeviceCode: "HOST1", devices: fleet)
            .requirements.first { $0.id == "matrix" }?.hint
    }

    @Test("An out-of-range matrix is reported as out of range")
    func hintNamesControlRange() {
        let hint = matrixHint(fleet(matrixFeatures: ["stow", "matrix"], matrixInControlRange: false))
        #expect(hint?.contains("control range") == true)
    }

    @Test("A busy matrix is reported as busy, not out of range")
    func hintNamesBusy() {
        let hint = matrixHint(fleet(
            matrixFeatures: ["stow", "matrix"], matrixStatus: "printing (ftl_relay)", matrixInControlRange: true
        ))
        #expect(hint?.contains("printing") == true)
        #expect(hint?.contains("control range") == false)
    }

    /// The live `pennig-scan` case: in range, idle, but the backend withholds
    /// `replicate` because the matrix carries no `matrix` feature. The hint must
    /// say so rather than blaming control range or a current task.
    @Test("A matrix lacking the `matrix` feature is reported as an unusable source")
    func hintNamesMissingMatrixFeature() {
        let hint = matrixHint(fleet(matrixFeatures: ["stow"], matrixInControlRange: true))
        #expect(hint?.contains("control range") == false)
        #expect(hint?.contains("current task") == false)
        #expect(hint?.contains("replication source") == true)
    }

    @Test("A replicant with no matrix at all keeps the hosting hint")
    func hintNamesMissingMatrix() {
        var fleet = eligibleFleet()
        fleet.removeAll { $0.deviceType == "replicant_matrix" }
        #expect(matrixHint(fleet)?.contains("hosted in a replicant matrix") == true)
    }
}
