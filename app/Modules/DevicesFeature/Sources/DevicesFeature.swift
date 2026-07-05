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
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould.feature", category: "Devices")

@Reducer
public struct DevicesFeature {
    @ObservableState
    public struct State: Equatable {
        /// The fleet, ordered by type — observed straight from SQLite in state so
        /// the list view is a pure renderer. `@ObservationStateIgnored` because
        /// `@FetchAll` drives its own observation.
        @ObservationStateIgnored
        @FetchAll(Device.order { $0.deviceType }) public var devices: [Device]

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
        /// A pending `enqueue_print` confirmation: the chosen blueprint's resource
        /// cost checked against the current location's live inventory. Non-nil ⇒
        /// the sheet is presented.
        public var printPreview: PrintPreview?
        /// The diversion defense state for the selected device, when it's
        /// `diverting`. A diverting device carries no activity block of its own, so
        /// its active-task readout is fetched from the object it's attached to (see
        /// `.diversionRequested`) rather than derived from the device row.
        public var diversion: DiversionSnapshot?

        public init(selectedDeviceCode: String? = nil) {
            self.selectedDeviceCode = selectedDeviceCode
            self.isLoading = false
            self.errorMessage = nil
            self.commandError = nil
            self.travelPreview = nil
            self.printPreview = nil
            self.diversion = nil
        }

        /// The inspected device, resolved synchronously from the observed fleet.
        /// Derived (not a separate `@FetchOne`) so the inspector can't revert to
        /// "No Device Selected" when the store re-emits after a command writes the
        /// device row. Nil only when nothing is selected or the code is unknown.
        public var selectedDevice: Device? {
            guard let code = selectedDeviceCode else { return nil }
            return devices.first { $0.deviceCode == code }
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
        /// The inspector is viewing a device whose activity refreshes in place
        /// (mining cycles, a diversion's slow progress). Non-nil starts a
        /// while-viewing refresh loop for that device; nil (deselect / settled)
        /// stops it. See `refreshDelay(for:now:)` for the cadence.
        case viewingChanged(deviceCode: String?)
        /// A refreshed diversion snapshot for the viewed device (nil clears it).
        case diversionResponse(DiversionSnapshot?)
        /// The inspector opened the `gather_salvage` directive for a controller in
        /// `system`; hydrate that controller's operating `body` into the local
        /// locations catalog so the salvage-site dropdown can offer its sites.
        case salvageSitesRequested(system: String, body: String)
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.devicesClient) var devicesClient
    @Dependency(\.deviceRefresher) var deviceRefresher
    @Dependency(\.commandClient) var commandClient
    @Dependency(\.locationsClient) var locationsClient
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date

    /// Cancels the while-viewing refresh loop when the inspected device changes.
    private enum CancelID { case refresh }

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
                // Ignore a late response if the user already dismissed the sheet.
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

            case let .viewingChanged(deviceCode):
                // Any prior device's overlay is stale the moment the selection
                // changes; clear it before the new loop repopulates it.
                state.diversion = nil
                guard let deviceCode else { return .cancel(id: CancelID.refresh) }
                let deviceRefresher = self.deviceRefresher
                let devicesClient = self.devicesClient
                let clock = self.clock
                let date = self.date
                return .run { send in
                    // Refresh the viewed device in place through the shared
                    // coordinator, so this deliberate poll coalesces with any
                    // relay-/deadline-driven read instead of firing a duplicate
                    // (the coordinator reconciles the snapshot into the tables the
                    // inspector observes). `.high` bypasses the coordinator's TTL —
                    // this loop *is* the intended poller — while still joining an
                    // in-flight read. A diverting propulsor also refreshes the
                    // object's defense readout. The cadence tracks the mining cycle
                    // (or a slow tick for a diversion); a settled device ends the loop.
                    while !Task.isCancelled {
                        guard let device = await deviceRefresher.refresh(deviceCode, .high) else {
                            // Suppressed / failed read — back off and retry rather
                            // than abandoning the loop.
                            try await clock.sleep(for: .seconds(15))
                            continue
                        }
                        if device.statusBase == "diverting", let location = device.location {
                            await send(.diversionResponse(try? await devicesClient.diversion(location)))
                        }
                        guard let delay = Self.refreshDelay(for: device, now: date.now) else { return }
                        try await clock.sleep(for: delay)
                    }
                }
                .cancellable(id: CancelID.refresh, cancelInFlight: true)

            case let .diversionResponse(snapshot):
                state.diversion = snapshot
                return .none

            case let .salvageSitesRequested(system, body):
                // Fill the local catalog for this controller's system in the
                // background; the SystemDetail write flows back to the picker's
                // @FetchAll. Best-effort — an unreadable system just leaves the
                // dropdown empty with its "scan the system" hint.
                let locationsClient = self.locationsClient
                return .run { _ in
                    try? await locationsClient.hydrateBody(systemDesignation: system, bodyDesignation: body)
                }
            }
        }
    }

    /// How long to wait before the next while-viewing refresh, or nil to stop the
    /// loop (the device settled / isn't a refreshable activity). A mining drone is
    /// re-read just after each cycle boundary so its yield tally reflects the
    /// completed cycle; a diverting propulsor ticks on a slow fixed interval since
    /// its deflection creeps.
    static func refreshDelay(for device: Device, now: Date) -> Duration? {
        switch device.statusBase {
        case "mining":
            guard let mining = device.miningSnapshot,
                  let started = mining.startedAt,
                  let cycle = mining.cycleTimeSeconds, cycle > 0
            else { return .seconds(20) }  // mining without cycle timing: modest poll
            let elapsed = now.timeIntervalSince(started)
            let wrapped = elapsed.truncatingRemainder(dividingBy: cycle)
            let intoCycle = wrapped < 0 ? wrapped + cycle : wrapped
            // Land a beat past the boundary so the read sees the finished cycle.
            return .seconds(cycle - intoCycle + 1.5)
        case "diverting":
            return .seconds(30)
        default:
            return nil
        }
    }
}
