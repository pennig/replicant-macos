//
//  PrintQueueFeature.swift
//  Replicould — Print Queue feature
//
//  The fleet's fabrication view: every device that can print and is either
//  printing or holding queued jobs. Like the Devices feature, the list itself is
//  observed straight from the `Device` SQLite table (via `@FetchAll` in the
//  views, filtered to `isPrintingOrQueued`) and kept live by `GameSync`; the
//  reducer owns only intent — the cold load / explicit refresh and command
//  dispatch (enqueue a new print, dequeue a queued job, clear the queue). Firing
//  a command goes through `CommandClient` so the UI keeps observing tables rather
//  than inspecting responses.
//

import ComposableArchitecture
import DependencyClients
import Foundation
import GameModels
import OSLog
import SQLiteData
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould.feature", category: "PrintQueue")

@Reducer
public struct PrintQueueFeature {
    @ObservableState
    public struct State: Equatable {
        /// The whole fleet, ordered — observed straight from SQLite in state.
        /// `@ObservationStateIgnored` because `@FetchAll` drives its own
        /// observation; the printer list is derived from it in `printers`.
        @ObservationStateIgnored
        @FetchAll(Device.order { $0.deviceType }) public var fleet: [Device]

        /// The inspected printer (drives the detail pane).
        public var selectedDeviceCode: String?
        public var isLoading: Bool
        /// Cold-load failure, shown as a banner over the list.
        public var errorMessage: String?
        /// A rejected/failed command, shown as an alert in the inspector where the
        /// user fired it.
        public var commandError: String?
        /// A pending `enqueue_print` confirmation: the chosen blueprint's resource
        /// cost checked against the current location's live inventory. Non-nil ⇒
        /// the sheet is presented.
        public var printPreview: PrintPreview?

        public init(selectedDeviceCode: String? = nil) {
            self.selectedDeviceCode = selectedDeviceCode
            self.isLoading = false
            self.errorMessage = nil
            self.commandError = nil
            self.printPreview = nil
        }

        /// The printers to list: those actively printing or with queued jobs. A
        /// synchronous derivation of the fetched fleet (the `isPrintingOrQueued`
        /// gate reads the device's JSON detail, so it can't be a SQL predicate).
        public var printers: [Device] {
            fleet.filter(\.isPrintingOrQueued)
        }

        /// The inspected printer, resolved synchronously from the observed fleet.
        /// Derived (not a separate `@FetchOne`) so the inspector doesn't revert to
        /// its empty state when a command writes the device row and the store
        /// re-emits. Reads the full fleet (not just `printers`) so it persists even
        /// if the device momentarily leaves the printing set.
        public var selectedDevice: Device? {
            guard let code = selectedDeviceCode else { return nil }
            return fleet.first { $0.deviceCode == code }
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
        /// Confirmed from the inspector — enqueue a new print, dequeue a queued
        /// job, or clear the queue.
        case commandConfirmed(kind: OperationKind, deviceCode: String, params: CommandParams)
        case commandFinished(CommandOutcome)
        case dismissCommandError
        /// Print command preview flow: refresh the location inventory and check
        /// the blueprint's cost against it, then either confirm (enqueue for real)
        /// or dismiss the sheet.
        case printPreviewRequested(
            deviceCode: String,
            deviceType: String,
            location: String?,
            locationName: String?,
            required: [PrintResourceLine]
        )
        case printPreviewResponse(PrintPreview.Phase)
        case printPreviewConfirmed
        case printPreviewDismissed
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.devicesClient) var devicesClient
    @Dependency(\.commandClient) var commandClient
    @Dependency(\.locationsClient) var locationsClient

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                // First run only: cold-load the fleet if the table is empty. After
                // that the relay keeps it warm, so navigating here spends no reads.
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
                // The device's fresh print/queue state surfaces via table
                // observation; only a failure needs an explicit nudge.
                if let message = outcome.failureMessage {
                    logger.warning("command failed: \(message, privacy: .public)")
                    state.commandError = message
                }
                return .none

            case .dismissCommandError:
                state.commandError = nil
                return .none

            case let .printPreviewRequested(deviceCode, deviceType, location, locationName, required):
                state.printPreview = PrintPreview(deviceCode: deviceCode, deviceType: deviceType)
                let locationsClient = self.locationsClient
                logger.info("print preview \(deviceCode, privacy: .public) ⚒ \(deviceType, privacy: .public) requested")
                return .run { send in
                    let requirements = await locationsClient.printRequirements(
                        deviceType: deviceType,
                        location: location,
                        locationName: locationName,
                        required: required
                    )
                    await send(.printPreviewResponse(.loaded(requirements)))
                }

            case let .printPreviewResponse(phase):
                guard state.printPreview != nil else { return .none }
                state.printPreview?.phase = phase
                return .none

            case .printPreviewConfirmed:
                guard let preview = state.printPreview else { return .none }
                state.printPreview = nil
                return .send(.commandConfirmed(
                    kind: .print,
                    deviceCode: preview.deviceCode,
                    params: CommandParams(deviceType: preview.deviceType)
                ))

            case .printPreviewDismissed:
                state.printPreview = nil
                return .none
            }
        }
    }
}
