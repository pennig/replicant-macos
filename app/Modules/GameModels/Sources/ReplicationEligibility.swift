//
//  ReplicationEligibility.swift
//  Replicould — shared replication pre-flight model
//
//  The pre-flight check backing the "Replicate" confirmation in the Replicants
//  inspector. A replicant self-replicates by issuing the `replicate` device
//  command on its `replicant_matrix` host (docs:
//  https://replicant.space/docs/api/replicants/replicate/). The server enforces
//  three hard preconditions, so the UI lists them and only enables the action
//  when they're all met:
//
//    1. The target is an `empty_replicant_matrix` device.
//    2. The target is stowed in a device that has the `cradle` feature.
//    3. The cradle device is at the same location as the source matrix.
//
//  Plus the implicit source-side condition: the replicant's host vessel must
//  contain a `replicant_matrix` (stowed inside it) that currently lists
//  `replicate` among its `available_commands`. `hosted_device_code` names the
//  vessel, not the matrix — the matrix is a distinct stowed device.
//
//  Kept a plain, SwiftUI-free value type (not a static on a View) so it resolves
//  from already-persisted `Device` fields and is straightforward to unit-test.
//  Mirrors the `PrintRequirements` shape (`isMet` per line + a whole-check gate).
//

import Foundation

/// One requirement line in the replicate confirmation: a human label, whether
/// it's satisfied, and — when it isn't — a short hint on how to satisfy it.
public struct ReplicationRequirement: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var isMet: Bool
    /// Shown beneath the line only when `isMet` is false.
    public var hint: String

    public init(id: String, label: String, isMet: Bool, hint: String) {
        self.id = id
        self.label = label
        self.isMet = isMet
        self.hint = hint
    }
}

/// A valid replication target: an `empty_replicant_matrix` stowed in a
/// `cradle`-feature carrier that sits at the source matrix's location.
public struct ReplicationTarget: Equatable, Sendable, Identifiable {
    /// The empty matrix device code — passed as the command's `target`.
    public var deviceCode: String
    /// The carrier the empty matrix is stowed in (has the `cradle` feature).
    public var cradleDeviceCode: String
    public var location: String?
    public var locationName: String?

    public var id: String { deviceCode }

    public init(deviceCode: String, cradleDeviceCode: String, location: String?, locationName: String?) {
        self.deviceCode = deviceCode
        self.cradleDeviceCode = cradleDeviceCode
        self.location = location
        self.locationName = locationName
    }
}

/// The resolved replication readiness for one replicant: which device would issue
/// the command, the requirement checklist, and every valid target found.
public struct ReplicationEligibility: Equatable, Sendable {
    /// The device that would issue `replicate` — the replicant's `replicant_matrix`
    /// host, when it advertises the command. Nil when there's no usable matrix.
    public var sourceMatrixCode: String?
    public var requirements: [ReplicationRequirement]
    public var targets: [ReplicationTarget]

    public init(
        sourceMatrixCode: String?,
        requirements: [ReplicationRequirement],
        targets: [ReplicationTarget]
    ) {
        self.sourceMatrixCode = sourceMatrixCode
        self.requirements = requirements
        self.targets = targets
    }

    /// Whether a replication can actually be dispatched right now: a usable matrix,
    /// at least one valid target, and every requirement satisfied.
    public var canReplicate: Bool {
        sourceMatrixCode != nil && !targets.isEmpty && requirements.allSatisfy(\.isMet)
    }

    /// Resolve readiness from the replicant's host device code and the account's
    /// local fleet. Everything is derived from already-persisted `Device` fields
    /// (`deviceType`, `availableCommands`, `features`, `location`,
    /// `stowedInDeviceCode`), so no network read is required to render the checklist.
    public static func resolve(hostDeviceCode: String?, devices: [Device]) -> ReplicationEligibility {
        let byCode = Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { first, _ in first })

        // 1) Source matrix — the `replicant_matrix` stowed *inside* the replicant's
        //    host vessel. `hostDeviceCode` is the vessel (e.g. a heaven_vessel), not
        //    the matrix itself; the matrix is a distinct device with
        //    `stowedInDeviceCode == hostDeviceCode` that carries the `replicate` command.
        let hostVessel = hostDeviceCode.flatMap { byCode[$0] }
        let source = hostDeviceCode.flatMap { host in
            devices.first { $0.deviceType == "replicant_matrix" && $0.stowedInDeviceCode == host }
        }
        let sourceIsMatrix = source != nil
        let canIssueCommand = source?.availableCommands.contains("replicate") ?? false
        let sourceReady = sourceIsMatrix && canIssueCommand
        // A stowed matrix has no location of its own — use the host vessel's location.
        let sourceLocation = hostVessel?.location

        // 2) Candidate empty matrices anywhere in the fleet.
        let empties = devices.filter { $0.deviceType == "empty_replicant_matrix" }
        let hasEmpty = !empties.isEmpty

        // 3) Of those, the ones stowed in a cradle-feature carrier — a *different*
        //    vessel than the source matrix's own host — co-located with the source
        //    matrix are valid targets. The empty matrix can't share the source's
        //    vessel (a replicant replicates itself out into a separate cradle).
        var stowedInCradle = false
        var targets: [ReplicationTarget] = []
        for empty in empties {
            guard
                let carrierCode = empty.stowedInDeviceCode,
                carrierCode != hostDeviceCode,
                let carrier = byCode[carrierCode],
                carrier.features.contains("cradle")
            else { continue }
            stowedInCradle = true
            if let sourceLocation, carrier.location == sourceLocation {
                targets.append(ReplicationTarget(
                    deviceCode: empty.deviceCode,
                    cradleDeviceCode: carrier.deviceCode,
                    location: carrier.location,
                    locationName: carrier.locationName
                ))
            }
        }

        // The matrix line fails for structurally different reasons, so name the one
        // that actually applies. A single hard-coded "bring it into control range or
        // wait for its current task to finish" sent players chasing conditions that
        // were already satisfied — the backend most often withholds `replicate`
        // because the matrix simply isn't a usable source (see `canBeSource`).
        let matrixHint: String
        if let matrix = source {
            if matrix.isOutOfControlRange {
                matrixHint = "This matrix is cut off from its controller — bring it back into control range."
            } else if !matrix.canBeSource {
                matrixHint = """
                    This matrix can't act as a replication source. Only a matrix carrying the \
                    `matrix` feature can replicate — one that was itself created by replicating \
                    into an empty matrix does not.
                    """
            } else if matrix.isBusy {
                matrixHint = "This matrix is \(matrix.statusBase) — wait for its current task to finish."
            } else {
                matrixHint = "The backend isn't offering the replicate command on this matrix right now."
            }
        } else {
            matrixHint = "This replicant must be hosted in a replicant matrix to replicate."
        }

        let requirements = [
            ReplicationRequirement(
                id: "matrix",
                label: "Active replicant matrix",
                isMet: sourceReady,
                hint: matrixHint
            ),
            ReplicationRequirement(
                id: "empty",
                label: "Empty matrix available",
                isMet: hasEmpty,
                hint: "Print an empty_replicant_matrix from an autofactory."
            ),
            ReplicationRequirement(
                id: "cradle",
                label: "Empty matrix stowed in a cradle",
                isMet: stowedInCradle,
                hint: "Stow the empty matrix in a separate cradle-feature device — not the source matrix's own host vessel."
            ),
            ReplicationRequirement(
                id: "colocated",
                label: "Cradle at the matrix's location",
                isMet: !targets.isEmpty,
                hint: "Bring the cradle to the same location as your replicant matrix."
            ),
        ]

        return ReplicationEligibility(
            sourceMatrixCode: sourceReady ? source?.deviceCode : nil,
            requirements: requirements,
            targets: targets
        )
    }
}
