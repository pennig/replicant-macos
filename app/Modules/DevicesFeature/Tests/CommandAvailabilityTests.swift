//
//  CommandAvailabilityTests.swift
//  Replicould — Devices feature tests
//
//  Covers `CommandAvailability` — the candidate lists and availability gates the
//  inspector's command grid offers. These rules lived inside `CommandGrid` until
//  the V3.6 T6 extraction, where nothing could reach them; this suite is the
//  reason the extraction was worth doing.
//
//  Scope note: the gates exercised here are the ones expressible from Device's
//  STORED columns. `attach`/`stow`/cargo additionally read computed accessors off
//  the `detail` JSON blob (`attachCapacity`, `stowRemaining`, `cargoItems`), whose
//  decoding is covered in GameModels' own suites — asserting them here would be
//  testing the decoder a second time through a longer path.
//

import CustomDump
import Foundation
import GameModels
import Testing
@testable import DevicesFeature

@Suite("CommandAvailability")
struct CommandAvailabilityTests {

    /// A minimal `Device` — only the stored fields these rules read.
    private func device(
        code: String,
        type: String,
        replicant: String = "R1",
        status: String = "idle",
        location: String? = nil,
        capacity: Double = 100,
        commands: [String] = []
    ) -> Device {
        let epoch = Date(timeIntervalSince1970: 0)
        return Device(
            deviceCode: code,
            deviceType: type,
            replicantCode: replicant,
            status: status,
            location: location,
            locationName: nil,
            operationalCapacity: capacity,
            queueSize: 0,
            stowedInDeviceCode: nil,
            controllerDeviceCode: nil,
            attachedToDeviceCode: nil,
            createdAt: epoch,
            availableCommands: commands,
            features: [],
            tags: [],
            detail: .object([:]),
            updatedAt: epoch,
            firstSeenAt: epoch
        )
    }

    // MARK: retarget — the server rejects it unless the device is mining

    @Test func retargetOnlySurfacesWhileMining() {
        let mining = device(code: "D1", type: "mining_drone",
                            status: "mining (carbon)", commands: ["retarget"])
        #expect(CommandAvailability.commands(device: mining, fleet: [mining],
                                             replicants: [], channels: []) == [.retarget])

        let idle = device(code: "D1", type: "mining_drone",
                          status: "idle", commands: ["retarget"])
        #expect(CommandAvailability.commands(device: idle, fleet: [idle],
                                             replicants: [], channels: []).isEmpty)
    }

    // MARK: adopt — type-matched, and never already-controlled

    @Test func adoptOffersOnlyTheControllersOwnWorkerType() {
        let controller = device(code: "C1", type: "ami_mining_controller", commands: ["adopt"])
        let drone = device(code: "D1", type: "mining_drone", location: "SOL-3")
        let wrongType = device(code: "D2", type: "survey_drone", location: "SOL-3")

        let candidates = CommandAvailability.adoptCandidates(
            device: controller, fleet: [drone, wrongType])
        expectNoDifference(candidates.map(\.id), ["D1"])
    }

    @Test func aNonControllerAdoptsNothing() {
        let plain = device(code: "V1", type: "heaven_vessel", commands: ["adopt"])
        let drone = device(code: "D1", type: "mining_drone")
        #expect(CommandAvailability.adoptCandidates(device: plain, fleet: [drone]).isEmpty)
        // …and with no candidates the verb is withheld entirely, rather than
        // opening an empty picker.
        #expect(CommandAvailability.commands(device: plain, fleet: [drone],
                                             replicants: [], channels: []).isEmpty)
    }

    // MARK: repair — meaningful candidates only

    @Test func repairExcludesTheBotItselfAndFullyHealthyDevices() {
        let bot = device(code: "B1", type: "service_bot", capacity: 62, commands: ["repair"])
        let hurt = device(code: "D1", type: "mining_drone", capacity: 62)
        let healthy = device(code: "D2", type: "mining_drone", capacity: 100)

        let candidates = CommandAvailability.repairCandidates(
            device: bot, fleet: [bot, hurt, healthy])
        expectNoDifference(candidates, [DeviceOption(id: "D1", subtitle: "Mining Drone · 62%")])
    }

    // MARK: replicate — needs an empty matrix at the SAME location

    @Test func replicateRequiresAnEmptyMatrixCoLocated() {
        let matrix = device(code: "M1", type: "replicant_matrix",
                            location: "SOL-3", commands: ["replicate"])
        let hereEmpty = device(code: "E1", type: "empty_replicant_matrix", location: "SOL-3")
        let elsewhere = device(code: "E2", type: "empty_replicant_matrix", location: "SOL-4")

        expectNoDifference(
            CommandAvailability.replicateTargets(device: matrix, fleet: [hereEmpty, elsewhere])
                .map(\.id),
            ["E1"])

        // No co-located matrix ⇒ Replicate is hidden, not shown-and-broken.
        #expect(CommandAvailability.commands(device: matrix, fleet: [elsewhere],
                                             replicants: [], channels: []).isEmpty)
    }

    @Test func aDeviceWithNoLocationHasNoReplicateTargets() {
        let matrix = device(code: "M1", type: "replicant_matrix", location: nil)
        let empty = device(code: "E1", type: "empty_replicant_matrix", location: "SOL-3")
        #expect(CommandAvailability.replicateTargets(device: matrix, fleet: [empty]).isEmpty)
    }

    // MARK: change_owner — never the device's current owner

    @Test func ownerCandidatesExcludeTheCurrentOwner() {
        let epoch = Date(timeIntervalSince1970: 0)
        func replicant(_ code: String, _ name: String) -> Replicant {
            Replicant(replicantCode: code, name: name, createdAt: epoch)
        }
        let owned = device(code: "D1", type: "mining_drone", replicant: "R1")
        let candidates = CommandAvailability.ownerCandidates(
            device: owned, replicants: [replicant("R1", "Self"), replicant("R2", "Other")])
        expectNoDifference(candidates, [DeviceOption(id: "R2", subtitle: "Other")])
    }

    // MARK: message — withheld until BobNet has synced channels

    @Test func messageIsWithheldWithNoKnownChannels() {
        let hub = device(code: "H1", type: "heaven_vessel", commands: ["message"])
        #expect(CommandAvailability.commands(device: hub, fleet: [hub],
                                             replicants: [], channels: []).isEmpty)
        #expect(CommandAvailability.commands(device: hub, fleet: [hub],
                                             replicants: [], channels: ["general"])
                == [.message(channels: ["general"])])
    }

    // MARK: unparameterized verbs pass through untouched

    @Test func simpleVerbsAreNotGated() {
        let d = device(code: "D1", type: "mining_drone",
                       location: "SOL-3", commands: ["deactivate"])
        let offered = CommandAvailability.commands(device: d, fleet: [d],
                                                   replicants: [], channels: [])
        #expect(offered == [.simple("deactivate")])
    }
}
