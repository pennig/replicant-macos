//
//  NewFetchRunFeature.swift
//  Replicould — Directives feature
//
//  The Fetch Run launcher: pick a device, pick where it should end up, go. The
//  plate is resolved rather than picked — there is one right answer (nearest
//  free `fetch`-tagged plate) and no reason to make the operator find it.
//
//  Eligibility is computed through `FetchRun`'s OWN queries and `Ownership`,
//  the one lease derivation, so this dialog cannot offer a device the engine
//  would immediately stall on or that the brain already holds.
//

import ComposableArchitecture
import DirectiveEngine
import Foundation
import GameModels
import OSLog
import SQLiteData
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Directives")

@Reducer
public struct NewFetchRunFeature {
    @ObservableState
    public struct State: Equatable {
        @ObservationStateIgnored
        @FetchAll(Device.order { $0.deviceCode }, animation: .default)
        public var devices: [Device]

        /// Every directive, so `Ownership` sees the same leases the brain does.
        /// It filters to the open statuses itself.
        @ObservationStateIgnored
        @FetchAll(Directive.all, animation: .default)
        public var directives: [Directive]

        /// The census, for ranking plates by distance from the pickup.
        @ObservationStateIgnored
        @FetchAll(Star.order { $0.designation }, animation: .default)
        public var stars: [Star]

        public var payloadCode: String?
        public var destination: String?

        public init(payloadCode: String? = nil) {
            self.payloadCode = payloadCode
        }

        /// Every device an in-force directive holds — the same set the brain
        /// refuses to allocate from.
        public var reserved: Set<String> {
            Ownership.resolve(
                directives: directives,
                devices: Dictionary(devices.map { ($0.deviceCode, $0) }, uniquingKeysWith: { _, last in last }),
                theatres: []
            ).reserved
        }

        /// Devices a plate could actually collect. A stowed device has no
        /// `location` and no plate can reach it — that is what the first filter
        /// is for, not an accident of the query.
        public static func eligiblePayloads(in devices: [Device], reserved: Set<String>) -> [Device] {
            devices
                .filter { $0.location != nil }
                .filter { !reserved.contains($0.deviceCode) }
                .filter { $0.deviceType != FetchRun.plateDeviceType }
                .sorted { $0.deviceCode < $1.deviceCode }
        }

        public var eligiblePayloads: [Device] {
            Self.eligiblePayloads(in: devices, reserved: reserved)
        }

        public var payload: Device? {
            payloadCode.flatMap { code in devices.first { $0.deviceCode == code } }
        }

        public var starPositions: [String: Position] {
            Dictionary(stars.map { ($0.designation, $0.position) }, uniquingKeysWith: { first, _ in first })
        }

        /// The hull this launch would fly, resolved by `FetchRun`'s own rule so
        /// the picker and preflight cannot disagree about what is eligible.
        public var resolvedPlate: Device? {
            guard let pickup = payload?.location else { return nil }
            return FetchRun.plate(
                for: pickup, in: devices, reserved: reserved, positions: starPositions
            )
        }

        /// Somewhere to send it: every location the fleet stands at, plus the
        /// payload's own excluded — a fetch to where it already is does nothing.
        public var destinations: [String] {
            let here = payload?.location
            return Set(devices.compactMap(\.location)).filter { $0 != here }.sorted()
        }

        /// A destination the payload already occupies is not a fetch.
        public static func canLaunch(payload: Device?, destination: String?, plate: Device?) -> Bool {
            guard let payload, let destination, plate != nil else { return false }
            return payload.location != destination
        }

        public var canLaunch: Bool {
            Self.canLaunch(payload: payload, destination: destination, plate: resolvedPlate)
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case launchTapped
        case cancelTapped
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            case created(Directive)
        }
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date
    @Dependency(\.dismiss) var dismiss
    @Dependency(\.uuid) var uuid

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .launchTapped:
                guard state.canLaunch,
                      let payload = state.payload,
                      let pickup = payload.location,
                      let destination = state.destination,
                      let plate = state.resolvedPlate
                else { return .none }
                logger.info("launching fetch run: \(payload.deviceCode, privacy: .public) on \(plate.deviceCode, privacy: .public)")
                // Bound to locals: referencing the property wrappers inside the
                // @Sendable closure would capture the non-Sendable reducer.
                let database = self.database
                let dismiss = self.dismiss
                let id = uuid().uuidString
                let now = date.now
                let pickupSystem = SiteAssay.system(of: pickup)
                let plateOrigin = plate.location.map { SiteAssay.system(of: $0) }
                return .run { send in
                    // The pickup's theatre, for list grouping. Where the PLATE
                    // parks is resolved fresh at `homing` from the destination.
                    let theatre = await LauncherTheatre.resolve(
                        forSystem: pickupSystem, database: database, now: now
                    )
                    let directive = Directive.launch(
                        .init(
                            kind: .fetchRun,
                            deviceCode: plate.deviceCode,
                            theatre: theatre,
                            targets: [pickup, destination],
                            originDesignation: plateOrigin,
                            payloadCode: payload.deviceCode
                        ),
                        id: id, now: now
                    )
                    try? await database.write { db in
                        try Directive.insert { directive }.execute(db)
                    }
                    await send(.delegate(.created(directive)))
                    await dismiss()
                }

            case .cancelTapped:
                let dismissNow = self.dismiss
                return .run { _ in await dismissNow() }

            case .delegate:
                return .none
            }
        }
    }
}
