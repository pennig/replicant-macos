//
//  ReplicantsFeature.swift
//  Replicould — Replicants feature
//
//  The galaxy-wide replicant directory: the account's own replicants alongside
//  every other player and NPC the account knows about. The list is observed
//  straight from the `KnownReplicant` SQLite table (via `@FetchAll` in the
//  views), so search filters reactively through SQL and scan sightings flow in
//  live; the reducer owns only intent — the cold load / refresh (seed roster +
//  walk the directory) and the on-demand details fetch for the inspected
//  replicant.
//

import AccountManager
import ComposableArchitecture
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould.feature", category: "Replicants")

/// A named group of directory rows (Yours / Players / NPCs), derived in state and
/// rendered as a `List` section.
public struct ReplicantSection: Identifiable, Equatable {
    public let id: String
    public let replicants: [KnownReplicant]
}

extension Array where Element == KnownReplicant {
    /// Case-insensitive sort by display name, falling back to the code so unnamed
    /// entries still order predictably.
    func sortedByName() -> [KnownReplicant] {
        sorted {
            let lhs = $0.name.isEmpty ? $0.replicantCode : $0.name
            let rhs = $1.name.isEmpty ? $1.replicantCode : $1.name
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }
}

@Reducer
public struct ReplicantsFeature {
    @ObservableState
    public struct State: Equatable {
        /// The whole known-replicant directory, ordered — observed straight from
        /// SQLite as a *static* query, so it resolves synchronously (no async
        /// reload, no empty-state flash) and stays live as scans/details land.
        /// `@ObservationStateIgnored` because `@FetchAll` drives its own
        /// observation; the view still re-renders on change when it reads it.
        @ObservationStateIgnored
        @FetchAll(KnownReplicant.order { $0.name }) public var directory: [KnownReplicant]
        /// The owned roster, to tag which directory entries are the account's own.
        @ObservationStateIgnored
        @FetchAll(Replicant.all) public var roster: [Replicant]
        /// The local fleet, used to resolve a replicant's host device to its real
        /// type/glyph in the inspector.
        @ObservationStateIgnored
        @FetchAll(Device.all) public var devices: [Device]

        /// The inspected replicant (drives the detail pane).
        public var selectedReplicantCode: String?
        /// The list's search query. The filtered/grouped result is derived
        /// synchronously from `directory` + this in `sections`, so what's shown
        /// always matches state exactly.
        public var searchText: String
        public var isLoading: Bool
        /// Cold-load failure, shown as a banner over the list.
        public var errorMessage: String?
        /// The replicant whose details are currently being fetched, so the
        /// inspector can show a spinner while the richer record loads.
        public var loadingDetailCode: String?

        /// A presented sheet — the profile editor or the replicate confirmation.
        /// Both act only on the account's own replicants.
        @Presents public var destination: ReplicantsDestination.State?

        public init(selectedReplicantCode: String? = nil) {
            self.selectedReplicantCode = selectedReplicantCode
            self.searchText = ""
            self.isLoading = false
            self.errorMessage = nil
            self.loadingDetailCode = nil
        }

        /// The inspected replicant, resolved synchronously from the observed
        /// directory. Derived (not a separate fetch) so it can't reset to nil when
        /// the store re-emits after a details write — the flash-then-empty the
        /// inspector otherwise showed. Nil only when nothing is selected or the
        /// selected code genuinely isn't known.
        public var selectedReplicant: KnownReplicant? {
            guard let code = selectedReplicantCode else { return nil }
            return directory.first { $0.replicantCode == code }
        }

        /// The selected replicant's host device, resolved from the local fleet —
        /// nil until we hold that device (the reducer fetches it on demand). Also a
        /// synchronous derivation, for the same reason as `selectedReplicant`.
        public var selectedHostDevice: Device? {
            guard let hostCode = selectedReplicant?.hostedDeviceCode else { return nil }
            return devices.first { $0.deviceCode == hostCode }
        }

        /// The codes of the account's own replicants — the "Yours" set. Drives
        /// which replicants expose the edit / replicate actions.
        public var ownedCodes: Set<String> { Set(roster.map(\.replicantCode)) }

        /// Whether the currently-inspected replicant is one of the account's own.
        public var isSelectedOwned: Bool {
            guard let code = selectedReplicantCode else { return false }
            return ownedCodes.contains(code)
        }

        /// The directory grouped into the account's own replicants, other players,
        /// and NPCs — filtered by `searchText` and sorted case-insensitively. A
        /// pure, synchronous function of the fetched rows and the search text, so
        /// the list is always consistent with state (never a stale or empty flash).
        public var sections: [ReplicantSection] {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            let matches = query.isEmpty ? directory : directory.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.replicantCode.localizedCaseInsensitiveContains(query)
            }
            let own = Set(roster.map(\.replicantCode))
            var yours: [KnownReplicant] = []
            var players: [KnownReplicant] = []
            var npcs: [KnownReplicant] = []
            for replicant in matches {
                if own.contains(replicant.replicantCode) { yours.append(replicant) }
                else if replicant.isNPC { npcs.append(replicant) }
                else { players.append(replicant) }
            }
            return [
                ReplicantSection(id: "Yours", replicants: yours.sortedByName()),
                ReplicantSection(id: "Players", replicants: players.sortedByName()),
                ReplicantSection(id: "NPCs", replicants: npcs.sortedByName()),
            ].filter { !$0.replicants.isEmpty }
        }

        /// Whether the directory table itself is empty (nothing fetched yet) — the
        /// list distinguishes "still loading" from "no matches for the search".
        public var isDirectoryEmpty: Bool { directory.isEmpty }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case refreshButtonTapped
        case load
        case loadSucceeded
        case loadFailed(String)
        case dismissError
        /// The inspector is viewing a replicant; fetch its full details. Nil when
        /// the selection clears.
        case detailsRequested(code: String?)
        case detailsFinished(code: String)
        case detailsFailed(String)
        /// Ensure the replicant's host device is in the local `Device` table so
        /// the inspector can show its real type/glyph — fetching it via
        /// `devices/{code}` when we don't already have it. Nil clears the loop.
        case hostDeviceRequested(code: String?)
        /// Open the profile editor for the inspected (own) replicant.
        case editTapped
        /// Open the replicate confirmation for the inspected (own) replicant.
        case replicateTapped
        /// Reveal a replicant in the inspector (e.g. a freshly-spawned offspring).
        case selectReplicant(String?)
        case destination(PresentationAction<ReplicantsDestination.Action>)
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.replicantsClient) var replicantsClient
    @Dependency(\.devicesClient) var devicesClient
    @Dependency(\.accountManager) var accountManager

    private enum CancelID { case details, hostDevice }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                // First run only: cold-load if the directory is empty. After that
                // the table stays warm (and scans keep sightings fresh), so
                // navigating here spends no reads — the user can still refresh.
                let database = self.database
                return .run { send in
                    let count = try await database.read { db in try KnownReplicant.fetchCount(db) }
                    if count == 0 { await send(.load) }
                } catch: { _, _ in }

            case .refreshButtonTapped:
                return .send(.load)

            case .load:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                let replicantsClient = self.replicantsClient
                logger.info("directory load starting")
                return .run { send in
                    let count = try await replicantsClient.refresh()
                    logger.info("directory load knows \(count) replicants")
                    await send(.loadSucceeded)
                } catch: { error, send in
                    logger.error("directory load failed: \(error.localizedDescription, privacy: .public)")
                    await send(.loadFailed(error.localizedDescription))
                }

            case .loadSucceeded:
                state.isLoading = false
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none

            case let .detailsRequested(code):
                guard let code else {
                    state.loadingDetailCode = nil
                    return .cancel(id: CancelID.details)
                }
                state.loadingDetailCode = code
                let replicantsClient = self.replicantsClient
                return .run { send in
                    try await replicantsClient.loadDetails(code)
                    await send(.detailsFinished(code: code))
                } catch: { error, send in
                    await send(.detailsFailed(error.localizedDescription))
                }
                .cancellable(id: CancelID.details, cancelInFlight: true)

            case let .detailsFinished(code):
                // Only clear the spinner if it still belongs to this fetch.
                if state.loadingDetailCode == code { state.loadingDetailCode = nil }
                return .none

            case let .detailsFailed(message):
                // The row keeps whatever we already knew (directory / scan intel);
                // a failed refresh of the richer record just stops the spinner.
                logger.warning("details load failed: \(message, privacy: .public)")
                state.loadingDetailCode = nil
                return .none

            case let .hostDeviceRequested(code):
                guard let code else { return .cancel(id: CancelID.hostDevice) }
                let database = self.database
                let devicesClient = self.devicesClient
                return .run { _ in
                    // Already in the fleet table? Then the inspector's @FetchOne
                    // already has it — don't spend a read.
                    let known = try await database.read { db in
                        try Device.where { $0.deviceCode.eq(code) }.fetchCount(db) > 0
                    }
                    guard !known else { return }
                    // Otherwise pull the host device and reconcile it in (it may be
                    // another player's device, in which case the read can fail —
                    // that's fine, the row just falls back to the generic host mark).
                    guard let device = try? await devicesClient.read(code) else { return }
                    await Reconciler().ingest(device)
                    logger.info("fetched host device \(code, privacy: .public) for inspector")
                }
                .cancellable(id: CancelID.hostDevice, cancelInFlight: true)

            case .editTapped:
                guard let replicant = state.selectedReplicant, state.isSelectedOwned else { return .none }
                state.destination = .edit(ReplicantEditFeature.State(replicant: replicant))
                return .none

            case .replicateTapped:
                guard let replicant = state.selectedReplicant, state.isSelectedOwned else { return .none }
                // Resolve readiness from the local fleet — a pure function of the
                // devices we already hold, so the checklist renders immediately.
                let eligibility = ReplicationEligibility.resolve(
                    hostDeviceCode: replicant.hostedDeviceCode, devices: state.devices
                )
                state.destination = .replicate(ReplicantReplicateFeature.State(
                    replicantCode: replicant.replicantCode,
                    replicantName: replicant.name.isEmpty ? replicant.replicantCode : replicant.name,
                    eligibility: eligibility
                ))
                return .none

            case let .selectReplicant(code):
                state.selectedReplicantCode = code
                return .none

            // A replication landed: bring in the new replicant (roster + directory)
            // and the rehosted target device, then reveal the offspring.
            case let .destination(.presented(.replicate(.delegate(.replicated(newCode))))):
                let accountManager = self.accountManager
                let devicesClient = self.devicesClient
                let replicantsClient = self.replicantsClient
                logger.info("replication succeeded\(newCode.map { " → \($0)" } ?? "", privacy: .public); refreshing roster + fleet")
                return .run { send in
                    await accountManager.refreshAccount()
                    if let devices = try? await devicesClient.fetchAll() {
                        for device in devices { await Reconciler().ingest(device) }
                    }
                    _ = try? await replicantsClient.refresh()
                    if let newCode { await send(.selectReplicant(newCode)) }
                }

            case .destination:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }
}

/// The sheets the Replicants inspector can present — both scoped to the account's
/// own replicants: the profile editor and the replicate confirmation.
@Reducer
public enum ReplicantsDestination {
    case edit(ReplicantEditFeature)
    case replicate(ReplicantReplicateFeature)
}

extension ReplicantsDestination.State: Equatable {}
