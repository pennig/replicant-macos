//
//  DevicesFeature.swift
//  Replicould — Devices feature
//
//  The first real consumer of the action layer. The fleet itself is observed
//  straight from the `Device`/`Operation` SQLite tables (via `@FetchAll` in the
//  views) and kept live by `GameSync`; the reducer owns only intent — the cold
//  load (first run / explicit refresh) and command dispatch. Firing a command
//  goes through `CommandClient`, so the optimistic op appears instantly and the
//  reconciler drives it to completion — the reducer never inspects responses.
//

import ComposableArchitecture
import DependencyClients
import Foundation
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould.feature", category: "Devices")

@Reducer
public struct DevicesFeature {
    @ObservableState
    public struct State: Equatable {
        /// The inspected device (drives the detail pane).
        public var selectedDeviceCode: String?
        public var isLoading: Bool
        /// Cold-load failure, shown as a banner over the list.
        public var errorMessage: String?
        /// A rejected/failed command, shown as an alert in the inspector where the
        /// user fired it.
        public var commandError: String?
        /// A pending `travel` itinerary, shown as a confirmation sheet before the
        /// command is actually dispatched. Non-nil ⇒ the sheet is presented.
        public var travelPreview: TravelPreview?

        public init(selectedDeviceCode: String? = nil) {
            self.selectedDeviceCode = selectedDeviceCode
            self.isLoading = false
            self.errorMessage = nil
            self.commandError = nil
            self.travelPreview = nil
        }
    }

    /// The in-flight or loaded dry-run travel preview backing the confirmation
    /// sheet: which device is going where, and the current phase of the request.
    public struct TravelPreview: Equatable, Identifiable {
        public let deviceCode: String
        public let destination: String
        public var phase: Phase

        public var id: String { "\(deviceCode)→\(destination)" }

        public enum Phase: Equatable {
            case loading
            case loaded(TravelPlan)
            case failed(String)
        }

        public init(deviceCode: String, destination: String, phase: Phase = .loading) {
            self.deviceCode = deviceCode
            self.destination = destination
            self.phase = phase
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task
        case refreshButtonTapped
        case load
        case loadSucceeded
        case loadFailed(String)
        case dismissError
        /// Confirmed from the inspector's command grid.
        case commandConfirmed(kind: OperationKind, deviceCode: String, params: CommandParams)
        case commandFinished(CommandOutcome)
        case dismissCommandError
        /// Travel command preview flow: request a dry-run plan, receive it, then
        /// either confirm (dispatch for real) or dismiss the sheet.
        case travelPreviewRequested(deviceCode: String, destination: String)
        case travelPreviewResponse(TravelPreviewOutcome)
        case travelPreviewConfirmed
        case travelPreviewDismissed
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.devicesClient) var devicesClient
    @Dependency(\.commandClient) var commandClient

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                // First run only: cold-load if the fleet table is empty. After
                // that the relay keeps it warm, so navigating here doesn't spend
                // reads — the user can still force a refresh.
                let database = self.database
                return .run { send in
                    let count = try await database.read { db in try Device.fetchCount(db) }
                    if count == 0 { await send(.load) }
                } catch: { _, _ in }

            case .refreshButtonTapped:
                return .send(.load)

            case .load:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                let devicesClient = self.devicesClient
                logger.info("cold-load starting")
                return .run { send in
                    let devices = try await devicesClient.fetchAll()
                    // Reconcile (not raw upsert) so the event-time guard holds and
                    // local provenance is preserved, exactly like a relay read.
                    let reconciler = Reconciler()
                    for device in devices { await reconciler.ingest(device) }
                    // The walk is the authoritative full fleet, so anything local
                    // and no longer listed (traded away, destroyed) is gone —
                    // prune it rather than leaving an orphan row in the list.
                    await reconciler.pruneDevices(presentCodes: devices.map(\.deviceCode))
                    logger.info("cold-load reconciled \(devices.count) devices")
                    await send(.loadSucceeded)
                } catch: { error, send in
                    logger.error("cold-load failed: \(error.localizedDescription, privacy: .public)")
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

            case let .commandConfirmed(kind, deviceCode, params):
                let commandClient = self.commandClient
                logger.info("command \(kind.rawValue, privacy: .public) → \(deviceCode, privacy: .public) confirmed")
                return .run { send in
                    await send(.commandFinished(commandClient.dispatch(kind, deviceCode, params)))
                }

            case let .commandFinished(outcome):
                // The accepted op surfaces via table observation; only a failure
                // needs an explicit nudge so the user isn't left guessing.
                if let message = outcome.failureMessage {
                    logger.warning("command failed: \(message, privacy: .public)")
                    state.commandError = message
                }
                return .none

            case .dismissCommandError:
                state.commandError = nil
                return .none

            case let .travelPreviewRequested(deviceCode, destination):
                state.travelPreview = TravelPreview(deviceCode: deviceCode, destination: destination)
                let commandClient = self.commandClient
                logger.info("travel preview \(deviceCode, privacy: .public) → \(destination, privacy: .public) requested")
                return .run { send in
                    await send(.travelPreviewResponse(commandClient.previewTravel(deviceCode, destination)))
                }

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
                return .send(.commandConfirmed(
                    kind: .travel,
                    deviceCode: preview.deviceCode,
                    params: CommandParams(destination: preview.destination)
                ))

            case .travelPreviewDismissed:
                state.travelPreview = nil
                return .none
            }
        }
    }
}
