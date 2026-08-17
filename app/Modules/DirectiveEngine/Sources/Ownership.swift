//
//  Ownership.swift
//  Replicould — DirectiveEngine
//
//  The one lease derivation: which in-force directive holds which device, and why.
//

import Foundation
import GameModels

/// Every device an in-force directive owns, with the join that put it there.
/// `devices` must be the UNFILTERED fleet, since a held device is usually
/// stowed. Over-reserves by design — stranding a fleet is the worse error.
public struct Ownership: Sendable, Equatable {
    /// How a directive reached a device: the four seeds off its own columns,
    /// then the three edges the closure walks.
    public enum Via: String, Sendable, Equatable {
        case deviceCode, controllerCode, freighterCode, fleetTag, stow, attach, adoption
    }

    /// One directive's claim on one device. `theatreDepot` is the holding row's
    /// own depot — what lets `reserved(in:)` place a scoped-tag lease.
    public struct Holder: Sendable, Equatable {
        public let directiveID: String
        public let via: Via
        public let theatreDepot: String?

        public init(directiveID: String, via: Via, theatreDepot: String?) {
            self.directiveID = directiveID
            self.via = via
            self.theatreDepot = theatreDepot
        }
    }

    /// Device code → its holders, lowest directive id first.
    private let holdersByCode: [String: [Holder]]
    /// Directive id → the depot its SCOPED tag lease binds to, lowercased.
    /// Absent means the lease binds account-wide.
    private let leaseDepots: [String: String]

    /// All held device codes — today's `Brain.reservedDevices`.
    public let reserved: Set<String>
    /// Rows whose `fleetTag` is unscoped and therefore reserve account-wide.
    public let accountWideLeases: [Directive]

    private init(
        holdersByCode: [String: [Holder]],
        leaseDepots: [String: String],
        accountWideLeases: [Directive]
    ) {
        self.holdersByCode = holdersByCode
        self.leaseDepots = leaseDepots
        self.accountWideLeases = accountWideLeases
        self.reserved = Set(holdersByCode.keys)
    }

    /// Every device held by a directive in `DirectiveStatus.openCases`, with why.
    /// Seeded per row from its carrier, controller, freighter and fleet tag, then
    /// closed to a fixpoint over stow (both directions), adoption and attach.
    public static func resolve(
        directives: [Directive], devices: [String: Device], theatres: [Theatre]
    ) -> Ownership {
        let owning = directives
            .filter { DirectiveStatus.openCases.contains($0.status) }
            .sorted { $0.id < $1.id }
        guard !owning.isEmpty else {
            return Ownership(holdersByCode: [:], leaseDepots: [:], accountWideLeases: [])
        }

        let drags = dragEdges(in: devices)
        // Sorted once, not per row: the walk order decides which edge claims a
        // code two seeds can both reach, so it must not vary run to run.
        let fleet = devices.values.sorted { $0.deviceCode < $1.deviceCode }
        let depots = Set(theatres.map { $0.depot.lowercased() })
        var holdersByCode: [String: [Holder]] = [:]
        var leaseDepots: [String: String] = [:]
        var accountWide: [Directive] = []

        for directive in owning {
            if let tag = directive.fleetTag.flatMap(FleetTag.init(parsing:)) {
                if !tag.isScoped {
                    accountWide.append(directive)
                } else if let depot = leaseDepot(of: directive, tag: tag, depots: depots) {
                    leaseDepots[directive.id] = depot
                }
            }
            for (code, via) in held(by: directive, fleet: fleet, drags: drags) {
                holdersByCode[code, default: []].append(
                    Holder(directiveID: directive.id, via: via, theatreDepot: directive.theatreDepot)
                )
            }
        }

        return Ownership(
            holdersByCode: holdersByCode, leaseDepots: leaseDepots, accountWideLeases: accountWide
        )
    }

    /// Which directive holds `deviceCode`, lowest id first when several do, so
    /// the answer is reproducible tick to tick.
    public func holder(of deviceCode: String) -> Holder? { holdersByCode[deviceCode]?.first }

    /// Every claim on `deviceCode`, for a caller that needs a particular `via`
    /// rather than whichever row got there first.
    public func holders(of deviceCode: String) -> [Holder] { holdersByCode[deviceCode] ?? [] }

    /// Held codes that bind INSIDE `theatre`: a scoped-tag lease binds only its
    /// own theatre; every other join binds everywhere, because a physical
    /// device is in one place.
    public func reserved(in theatre: Theatre) -> Set<String> {
        let depot = theatre.depot.lowercased()
        return Set(
            holdersByCode
                .filter { _, holders in holders.contains { binds($0, in: depot) } }
                .keys
        )
    }

    private func binds(_ holder: Holder, in depot: String) -> Bool {
        guard holder.via == .fleetTag, let lease = leaseDepots[holder.directiveID] else { return true }
        return lease == depot
    }
}

// MARK: - Derivation

extension Ownership {
    /// The depot a scoped lease binds to: the row's own stamp, else the tag's
    /// designation when that names a recognised theatre (a `.mine` ferry's belt
    /// names none, so its row stamp is the only handle).
    private static func leaseDepot(
        of directive: Directive, tag: FleetTag, depots: Set<String>
    ) -> String? {
        if let stamped = directive.theatreDepot { return stamped.lowercased() }
        guard let designation = tag.scope?.designation, depots.contains(designation) else { return nil }
        return designation
    }

    /// `code → everything reserving `code` also reserves`. Every edge TARGET
    /// must be a device the fleet holds — a dangling reference names nothing
    /// allocatable, and admitting it puts phantom codes in the set.
    private static func dragEdges(in devices: [String: Device]) -> [String: [(code: String, via: Via)]] {
        var drags: [String: [(code: String, via: Via)]] = [:]
        func link(_ from: String, _ to: String, _ via: Via) {
            guard devices[to] != nil else { return }
            drags[from, default: []].append((to, via))
        }
        for device in devices.values {
            if let hull = device.stowedInDeviceCode {
                link(hull, device.deviceCode, .stow)   // downward: the cargo aboard it
                link(device.deviceCode, hull, .stow)   // upward: the hull it rides in
            }
            if let controller = device.controllerDeviceCode {
                link(controller, device.deviceCode, .adoption)
            }
            for adopted in device.controlledDeviceCodes {
                link(device.deviceCode, adopted, .adoption)
            }
            if let hull = device.attachedToDeviceCode {
                link(hull, device.deviceCode, .attach)   // downward: the load on its grid
                link(device.deviceCode, hull, .attach)   // upward: the hull carrying it
            }
        }
        return drags.mapValues { edges in
            edges.sorted { $0.code == $1.code ? $0.via.rawValue < $1.via.rawValue : $0.code < $1.code }
        }
    }

    /// One row's whole hold: its four seeds, then the closure over `drags`. Two
    /// seeds may claim one code (a ferry row names one device twice); the walk
    /// re-enters no code, so a corrupt stow cycle closes rather than looping.
    private static func held(
        by directive: Directive,
        fleet: [Device],
        drags: [String: [(code: String, via: Via)]]
    ) -> [(code: String, via: Via)] {
        var claims: [(code: String, via: Via)] = []
        var seen: Set<String> = []
        var queue: [String] = []
        func claim(_ code: String, _ join: Via) {
            claims.append((code, join))
            guard seen.insert(code).inserted else { return }
            queue.append(code)
        }
        claim(directive.deviceCode, .deviceCode)
        if let controller = directive.controllerCode { claim(controller, .controllerCode) }
        // Seeded, never dragged: an event convoy's freighter flies its own
        // leg, so no stow or attach edge reaches it from the carrier.
        if let freighter = directive.freighterCode { claim(freighter, .freighterCode) }
        if let tag = directive.fleetTag.flatMap(FleetTag.init(parsing:)) {
            for device in fleet where device.carries(tag, policy: .exact) {
                claim(device.deviceCode, .fleetTag)
            }
        }

        var index = 0
        while index < queue.count {
            let code = queue[index]
            index += 1
            for edge in drags[code] ?? [] where !seen.contains(edge.code) {
                claim(edge.code, edge.via)
            }
        }
        return claims
    }
}
