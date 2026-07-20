//
//  LocationsFeature.swift
//  LocationsFeature
//
//  The stellar-locations catalog reducer. The list is driven entirely by
//  observed SQLite queries in the views (census `Star` + hydrated `StarSystem`
//  blobs + `LocationFootprint`), so this reducer holds only intent: the current
//  selection, sort/filter, and the on-demand hydration of a system's detail when
//  it's selected.
//
//  Census population (the ~5,770-system survey) is owned by the Stars view; this
//  feature reads that shared table. Selecting an explored system fetches its
//  detail via `LocationsClient` and persists the `StarSystem` blob; selecting a
//  body additionally fetches and merges that body's scanned detail. A system with
//  no replicant present returns `.noReplicantInSystem` and is left as a census
//  leaf (falling back to any cached blob).
//

import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import SQLiteData
import UniverseModels

@Reducer
public struct LocationsFeature {
    @ObservableState
    public struct State: Equatable {
        /// The built disclosure forest, observed straight from SQLite in state via
        /// a single `@Fetch` request that runs every query (census stars, hydrated
        /// system blobs, holdings footprints, the probe's position) *and* assembles
        /// the tree off the main actor. It re-runs automatically when any of those
        /// tables change, and the reducer reloads it when the search/sort/filter
        /// selections change — so the list always matches state with no view-side
        /// query and no empty-state flash. `@ObservationStateIgnored` because
        /// `@Fetch` drives its own observation.
        @ObservationStateIgnored
        @Fetch(LocationForest(search: "", sort: .distance, filter: .all)) public var forest = LocationForest.Value()
        /// The hydrated system blobs, observed so the inspector resolves the
        /// selected system synchronously (no view-local `@FetchOne` that resets to
        /// nil — and reverts to "Uncharted" — when a hydration write re-emits).
        @ObservationStateIgnored
        @FetchAll(SystemDetail.all) public var systemDetails: [SystemDetail]
        /// The roster, for the probe's current star (marks the "current system").
        @ObservationStateIgnored
        @FetchAll(Replicant.all) public var roster: [Replicant]
        /// The live device roster, so the inspector can resolve the active
        /// replicant's host vessel and gate the Travel / Scan System actions on its
        /// features (`surge`, `system_scan`).
        @ObservationStateIgnored
        @FetchAll(Device.all) public var devices: [Device]

        /// Selected node designation (system or body).
        public var selection: String?
        /// Expanded node designations (systems and bodies). Drives the flattened
        /// row list — a node's children are only emitted when its id is here. Kept
        /// in state so expansion survives tab switches, like sort/filter.
        public var expanded: Set<String>

        /// Sort / filter selections. Kept in state so they survive tab switches and
        /// drive the `@Fetch` request via `forestRequest`; changes flow through
        /// `BindingReducer`, which the reducer uses to reload the forest.
        public var sort: LocationSort
        public var filter: LocationFilter
        public var searchText: String
        /// Systems currently being hydrated — guards duplicate fetches.
        public var hydrating: Set<String>
        /// True while a full scan of the current system is in flight.
        public var isScanning: Bool
        /// A pending `travel` itinerary for the active replicant's host vessel,
        /// shown as a dry-run confirmation sheet before the command is dispatched —
        /// the same flow the star map dossier's Travel button drives. Non-nil ⇒
        /// presented.
        public var travelPreview: TravelPreview?
        public var errorMessage: String?
        /// The active replicant, used to scan its current system.
        @Shared(.appStorage(Account.activeReplicantCodeKey)) public var activeReplicantCode: String?

        public init(
            selection: String? = nil,
            sort: LocationSort = .distance,
            filter: LocationFilter = .all
        ) {
            self.selection = selection
            self.sort = sort
            self.filter = filter
            self.searchText = ""
            self.expanded = []
            self.hydrating = []
            self.isScanning = false
            self.travelPreview = nil
            self.errorMessage = nil
        }

        /// The forest query for the current selections — reloaded whenever search /
        /// sort / filter change.
        var forestRequest: LocationForest {
            LocationForest(search: searchText, sort: sort, filter: filter)
        }

        /// The probe's current star (the roster's first replicant), to mark the
        /// inspected system as the current one.
        public var currentStar: String? { roster.first?.currentStar }

        /// The session's active replicant, preferring the stored selection and
        /// falling back to the sole replicant on the roster — mirroring the star
        /// map's host resolution so the inspector's Travel / Scan actions target the
        /// same vessel.
        public var activeReplicant: Replicant? {
            roster.first { $0.replicantCode == activeReplicantCode }
                ?? (roster.count == 1 ? roster.first : nil)
        }

        /// The active replicant's host device (its vessel), resolved from the live
        /// roster via `hostedDeviceCode`. Nil when there's no active replicant or the
        /// host isn't on the roster.
        public var activeHostDevice: Device? {
            guard let code = activeReplicant?.hostedDeviceCode else { return nil }
            return devices.first { $0.deviceCode == code }
        }

        /// The active replicant's current-location *system*, used to gate the Scan
        /// System action (which scans the whole current system).
        public var activeCurrentStar: String? { activeReplicant?.currentStar }

        /// The active replicant's exact current location (e.g. `SOL-3`), used to gate
        /// the Travel action — offered for any location that isn't precisely where
        /// the host already sits, so intra-system hops are travellable too.
        public var activeCurrentLocation: String? { activeReplicant?.currentLocation }

        /// Whether the host vessel can plot interstellar travel — carries the
        /// `surge` feature. Gates the inspector's Travel button, matching the star
        /// map dossier.
        public var canSurge: Bool { activeHostDevice?.features.contains("surge") == true }

        /// Whether the host vessel can scan its current system — carries the
        /// `system_scan` feature. Gates the inspector's Scan System button.
        public var canScanSystem: Bool { activeHostDevice?.features.contains("system_scan") == true }

        /// The system designation for the current selection (a system or one of its
        /// bodies).
        public var selectedSystemID: String? {
            selection.map { String($0.split(separator: "-").first ?? "") }
        }

        /// The hydrated system for the current selection, decoded from its blob —
        /// derived synchronously so the inspector never blanks on a re-emit. Nil
        /// until the system is hydrated.
        public var selectedSystem: StarSystem? {
            guard
                let id = selectedSystemID,
                let row = systemDetails.first(where: { $0.designation == id })
            else { return nil }
            return try? row.system()
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case toggleExpansion(String)
        case hydrate(system: String, body: String?)
        case hydrated(String)
        case hydrateFailed(system: String, message: String)
        case scanRequested
        case scanFinished
        case scanFailed(String)
        // Travel command preview flow, driven from the inspector's Travel button:
        // request a dry-run plan for the active replicant's host vessel, receive it,
        // then either confirm (dispatch for real) or dismiss the sheet. Mirrors the
        // star map dossier's flow.
        case travelRequested(deviceCode: String, destination: String)
        case travelPreviewResponse(TravelPreviewOutcome)
        case travelPreviewConfirmed
        case travelPreviewDismissed
        case loadFailed(String)
        case dismissError
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.locationsClient) var locationsClient
    @Dependency(\.commandClient) var commandClient
    @Dependency(\.date.now) var now

    public init() {}

    /// Cancels an in-flight travel dry-run so a prior location's late response
    /// can't land on the current preview.
    private enum CancelID { case travelPreview }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.selection):
                guard let id = state.selection else { return .none }
                let system = String(id.split(separator: "-").first ?? "")
                guard !system.isEmpty, !state.hydrating.contains(system) else { return .none }
                state.hydrating.insert(system)
                return .send(.hydrate(system: system, body: id == system ? nil : id))

            case .binding(\.searchText), .binding(\.sort), .binding(\.filter):
                // Reload the forest for the new selections. `.load` keeps the prior
                // tree until the new one is built (off-main), so the list updates in
                // place with no empty flash.
                return .run { [fetch = state.$forest, request = state.forestRequest] _ in
                    _ = try? await fetch.load(request)
                }

            case .binding:
                return .none

            case let .toggleExpansion(id):
                if state.expanded.contains(id) {
                    state.expanded.remove(id)
                } else {
                    state.expanded.insert(id)
                }
                return .none

            case .task:
                // Load the forest for the current selections (in case they differ
                // from the @Fetch's seed) and refresh the footprint overlay in the
                // background. The @Fetch re-runs itself when the tables change, so
                // the footprint write flows back without an explicit reload.
                let database = self.database
                let locationsClient = self.locationsClient
                let now = self.now
                return .merge(
                    .run { [fetch = state.$forest, request = state.forestRequest] _ in
                        _ = try? await fetch.load(request)
                    },
                    .run { _ in
                        let footprint = try await locationsClient.footprint()
                        let rows = footprint.map { LocationFootprint(location: $0.key, counts: $0.value, fetchedAt: now) }
                        try await database.write { db in
                            try LocationFootprint.upsert { rows }.execute(db)
                        }
                    } catch: { error, send in
                        await send(.loadFailed(error.localizedDescription))
                    }
                )

            case let .hydrate(system, body):
                let database = self.database
                let locationsClient = self.locationsClient
                let now = self.now
                return .run { [fetch = state.$forest, request = state.forestRequest] send in
                    // Start from any persisted detail, plus the census explored flag.
                    let (cached, censusExplored) = try await database.read { db in
                        let detail = try SystemDetail.where { $0.designation.eq(system) }.fetchOne(db)
                        let explored = try Star.where { $0.designation.eq(system) }.fetchOne(db)?.explored ?? false
                        return (detail, explored)
                    }
                    var assembled = try cached?.system()
                    // Refresh the star-level system detail on selection whenever the
                    // system appears explored — the census says so, or we already
                    // hold detail for it (a blob implies we once had access). Fetched
                    // best-effort and merged, mirroring the body fetch below: a
                    // since-departed system 403s ("no replicant in system") and falls
                    // back to the cached blob, and `mergingSystemDetail` keeps richer
                    // per-body detail (and scanned-only shops/structures) intact.
                    if censusExplored || assembled != nil {
                        if let fresh = try? await locationsClient.system(system) {
                            assembled = assembled.map { $0.mergingSystemDetail(fresh) } ?? fresh
                        }
                    }
                    // Nothing cached and nothing fetched (uncharted / no access) —
                    // leave it as a census leaf.
                    guard var assembled else {
                        await send(.hydrated(system))
                        return
                    }
                    // If a specific body was selected, fetch and merge its scan
                    // (this updates just that body, preserving its siblings).
                    if let body, body != system {
                        if let detail = try? await locationsClient.body(body) {
                            assembled = assembled.applying(detail)
                        }
                    }
                    let row = try SystemDetail(system: assembled, hydratedAt: now)
                    try await database.write { db in
                        try SystemDetail.upsert { row }.execute(db)
                    }
                    // Reload the forest explicitly (as `.task` does) rather than
                    // waiting on `@Fetch`'s implicit DB observation: the catalog list
                    // is an AppKit-hosted table that only repaints when the forest
                    // value is current at re-render time, so the freshly-hydrated
                    // body's badges appear immediately instead of on the next
                    // selection change.
                    _ = try? await fetch.load(request)
                    await send(.hydrated(system))
                } catch: { error, send in
                    // "No replicant in system" (403) is expected, not an error to
                    // surface. The star-level fetch above swallows it via `try?`, so
                    // this is a defensive fallback should any path surface it directly.
                    if let locErr = error as? LocationsError, locErr == .noReplicantInSystem {
                        await send(.hydrated(system))
                    } else {
                        await send(.hydrateFailed(system: system, message: error.localizedDescription))
                    }
                }

            case let .hydrated(id):
                state.hydrating.remove(id)
                return .none

            case let .hydrateFailed(system, message):
                state.hydrating.remove(system)
                state.errorMessage = message
                return .none

            case .scanRequested:
                guard let code = state.activeReplicantCode, !state.isScanning else { return .none }
                state.isScanning = true
                let locationsClient = self.locationsClient
                return .run { send in
                    // Scan the current system — the only source of shops,
                    // megastructures/objects, and the outer system — and overlay
                    // it onto any already-hydrated detail.
                    try await locationsClient.scanAndPersist(replicantCode: code)
                    await send(.scanFinished)
                } catch: { error, send in
                    await send(.scanFailed(error.localizedDescription))
                }

            case .scanFinished:
                state.isScanning = false
                return .none

            case let .scanFailed(message):
                state.isScanning = false
                state.errorMessage = message
                return .none

            case let .travelRequested(deviceCode, destination):
                state.travelPreview = TravelPreview(deviceCode: deviceCode, destination: destination)
                let commandClient = self.commandClient
                return .run { send in
                    await send(.travelPreviewResponse(commandClient.previewTravel(deviceCode, destination)))
                }
                // A new preview cancels any prior in-flight dry-run so a late
                // response can't overwrite this one's phase.
                .cancellable(id: CancelID.travelPreview, cancelInFlight: true)

            case let .travelPreviewResponse(outcome):
                // Ignore a late response if the user already dismissed the sheet.
                guard state.travelPreview != nil else { return .none }
                switch outcome {
                case let .plan(plan):
                    state.travelPreview?.phase = .loaded(plan)
                case let .rejected(message), let .failed(message):
                    state.travelPreview?.phase = .failed(message)
                }
                return .none

            case .travelPreviewConfirmed:
                guard let preview = state.travelPreview else { return .none }
                state.travelPreview = nil
                let commandClient = self.commandClient
                let deviceCode = preview.deviceCode
                let destination = preview.destination
                // Fire-and-forget: the dispatched op surfaces via table observation
                // (GameSync + reconciler drive it to completion), matching the star
                // map and the Devices inspector.
                return .run { _ in
                    _ = await commandClient.dispatch(.travel, deviceCode, CommandParams(destination: destination))
                }

            case .travelPreviewDismissed:
                state.travelPreview = nil
                return .none

            case let .loadFailed(message):
                state.errorMessage = message
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none
            }
        }
    }
}

// MARK: - Forest query

/// The one query behind the catalog list: it reads every table the disclosure
/// tree depends on (census `Star`, hydrated `SystemDetail` blobs, holdings
/// `LocationFootprint`, and the probe's position via the roster) and assembles
/// the filtered, sorted forest — all inside `fetch`, which SQLiteData runs off
/// the main actor. `@Fetch` re-runs it whenever any of those tables change; the
/// reducer reloads it (new instance) when the search/sort/filter change.
public struct LocationForest: FetchKeyRequest {
    public var search: String
    public var sort: LocationSort
    public var filter: LocationFilter

    public struct Value: Equatable, Sendable {
        public var nodes: [LocationNode] = []
        public init(nodes: [LocationNode] = []) { self.nodes = nodes }
    }

    public init(search: String, sort: LocationSort, filter: LocationFilter) {
        self.search = search
        self.sort = sort
        self.filter = filter
    }

    public func fetch(_ db: Database) throws -> Value {
        // Empty search → `contains("")` matches every system.
        let stars = try Star
            .where { $0.designation.contains(search) }
            .order { $0.designation }
            .fetchAll(db)
        let detailRows = try SystemDetail.all.fetchAll(db)
        let footprintRows = try LocationFootprint.all.fetchAll(db)
        // The probe's position (for distance sort) — the first roster replicant's
        // current star, matching the prior behavior.
        let currentStar = try Replicant.all.fetchAll(db).first?.currentStar
        let myStar = try currentStar.flatMap { code in
            try Star.where { $0.designation.eq(code) }.fetchOne(db)
        }

        let details = Dictionary(
            detailRows.compactMap { row in (try? row.system()).map { (row.designation, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let footprints = Dictionary(
            footprintRows.map { ($0.location, $0.counts) },
            uniquingKeysWith: { first, _ in first }
        )

        return Value(nodes: LocationTree.forest(
            stars: stars,
            details: details,
            footprints: footprints,
            myPosition: myStar?.position,
            filter: filter,
            sort: sort
        ))
    }
}
