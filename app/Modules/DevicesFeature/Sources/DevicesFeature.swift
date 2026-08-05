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
import DirectiveComposerFeature
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData
import UniverseModels

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Devices")

@Reducer
public struct DevicesFeature {
    @ObservableState
    public struct State: Equatable {
        /// The fleet, ordered by type — observed straight from SQLite in state so
        /// the list view is a pure renderer. `@ObservationStateIgnored` because
        /// `@FetchAll` drives its own observation.
        @ObservationStateIgnored
        @FetchAll(Device.order { $0.deviceType }) public var devices: [Device]

        /// Directives currently flagged for the operator — the third Needs
        /// Attention predicate. Filtered in SQL (`DirectiveStatus` is
        /// `QueryBindable`) so the layout never re-checks status.
        @ObservationStateIgnored
        @FetchAll(Directive.where { $0.status.eq(DirectiveStatus.needsAttention) })
        public var attentionDirectives: [Directive]

        /// The list's search query. Driven by `.searchable` through the
        /// `BindingReducer()` — no bespoke action.
        public var searchText = ""

        /// Codes of the hosts the operator has opened. Empty ⇒ every host
        /// collapsed, which is the default and needs no seeding.
        public var expandedHosts: Set<String> = []

        /// IDs of the sections the operator has closed. Empty ⇒ every section
        /// open. The two disclosure sets are asymmetric on purpose: each
        /// defaults to the desired state at an empty set.
        public var collapsedGroups: Set<String> = []

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
        /// A pending `collect_resources` (Load Cargo) picker: the transport's hold
        /// space and the location's live stockpile, resolved before the sheet's
        /// per-resource quantity controls render. Non-nil ⇒ the sheet is presented.
        public var cargoLoad: CargoLoadPreview?
        /// The diversion defense state for the selected device, when it's
        /// `diverting`. A diverting device carries no activity block of its own, so
        /// its active-task readout is fetched from the object it's attached to (see
        /// `.diversionRequested`) rather than derived from the device row.
        public var diversion: DiversionSnapshot?
        /// The `set_directive` composer, presented as a sheet. A *feature*
        /// sheet (its own reducer), so it uses the `@Presents` tier of the
        /// presentation dialect rather than the plain-value item bindings the
        /// preview sheets use. Non-nil ⇒ the sheet is presented.
        @Presents public var directiveComposer: DirectiveComposer.State?

        public init(selectedDeviceCode: String? = nil) {
            self.selectedDeviceCode = selectedDeviceCode
            self.isLoading = false
            self.errorMessage = nil
            self.commandError = nil
            self.travelPreview = nil
            self.printPreview = nil
            self.cargoLoad = nil
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

        /// The organised list. `State` derives it, the view renders it — the
        /// established "list query in state, view is a pure renderer" standard.
        /// Recomputed on access, so a view body should bind it to a `let` once
        /// rather than reading `store.sections` several times.
        public var sections: [DeviceListSection] {
            DeviceListLayout.sections(
                fleet: devices,
                attentionDirectives: attentionDirectives,
                searchText: searchText,
                expandedHosts: expandedHosts,
                collapsedGroups: collapsedGroups
            )
        }

        /// Arrow-key navigation order. A collapsed host contributes no entries,
        /// so hidden rows are absent by construction rather than by a second
        /// rule that could drift out of step with the renderer.
        public var orderedIDs: [String] {
            sections.flatMap(\.entries).map(\.id)
        }

        /// Devices matching the active query across the *whole* fleet — the "N"
        /// in the "N of M devices" subtitle. Not the visible row count, which
        /// also includes the non-matching ancestors a match reveals.
        public var matchCount: Int {
            let query = DeviceListLayout.Query(searchText)
            guard !query.isEmpty else { return devices.count }
            return devices.filter { DeviceListLayout.matches($0, query: query) }.count
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
        /// The disclosure gestures. Named for the gesture rather than the logic,
        /// because the logic is `DeviceListLayout`'s.
        case groupDisclosureToggled(String)
        case hostDisclosureToggled(String)
        /// Confirmed from the inspector's command grid.
        case commandConfirmed(kind: OperationKind, deviceCode: String, params: CommandParams)
        case commandFinished(CommandOutcome)
        case dismissCommandError
        /// The inspector's "Review Route…" button. A thin intent: ends field
        /// editing and yields a runloop tick before `travelPreviewRequested` sets
        /// the state that presents the sheet (see the reducer for why).
        case travelConfirmed(deviceCode: String, destination: String)
        /// Travel command preview flow: request a dry-run plan, receive it, then
        /// either confirm (dispatch for real) or dismiss the sheet.
        case travelPreviewRequested(deviceCode: String, destination: String)
        case travelPreviewResponse(TravelPreviewOutcome)
        case travelPreviewConfirmed
        case travelPreviewDismissed
        /// The inspector's "Review Print…" button. Thin intent mirroring
        /// `travelConfirmed`: ends editing and yields before `printPreviewRequested`.
        case printConfirmed(
            deviceCode: String,
            deviceType: String,
            location: String?,
            locationName: String?,
            required: [PrintResourceLine]
        )
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
        /// The grid's Load Cargo button. A thin intent mirroring `travelConfirmed`:
        /// clears any stale presentation state, ends field editing, and yields a
        /// runloop tick before `cargoLoadRequested` presents the picker.
        case cargoLoadTapped(deviceCode: String, location: String?, locationName: String?, capacityRemaining: Int)
        /// Load-cargo flow: open the picker (fetching the location's stockpile),
        /// receive the resolved stockpile, then either confirm (dispatch
        /// `collect_resources` with the chosen per-resource amounts) or dismiss.
        case cargoLoadRequested(deviceCode: String, location: String?, locationName: String?, capacityRemaining: Int)
        case cargoLoadResponse(CargoLoadPreview.Phase)
        case cargoLoadConfirmed(resources: [String: Int])
        case cargoLoadDismissed
        /// The inspector's Replicate confirm: spawn a new replicant from this
        /// matrix into `target`. Routes through `ReplicantsClient` (201 → new
        /// replicant), not `CommandClient`; on success the fleet and roster
        /// re-ingest so the consumed matrix and rehosted device reconcile.
        case replicateConfirmed(deviceCode: String, target: String, name: String?)
        /// The inspector's Directive command. A thin intent mirroring
        /// `travelConfirmed`: ends field editing and yields a runloop tick
        /// before the composer sheet presents (see `.travelConfirmed` for why).
        case directiveComposeTapped
        /// Present the composer, seeded from the currently-inspected device.
        case directiveComposerPresented
        case directiveComposer(PresentationAction<DirectiveComposer.Action>)
        /// The inspector is viewing a device whose activity refreshes in place
        /// (mining cycles, a diversion's slow progress). Non-nil starts a
        /// while-viewing refresh loop for that device; nil (deselect / settled)
        /// stops it. See `refreshDelay(for:now:)` for the cadence.
        case viewingChanged(deviceCode: String?)
        /// The inspector is presenting this device (nil = the detail pane went
        /// away or the scene backgrounded). Feeds the staleness tracker's
        /// visible set and spends any mark the device accrued while hidden.
        /// Independent of `viewingChanged`: EVERY inspected device is visible,
        /// not just the ones running a refreshable activity.
        case inspectorVisibilityChanged(deviceCode: String?)
        /// A refreshed diversion snapshot for the viewed device (nil clears it).
        case diversionResponse(DiversionSnapshot?)
        /// The inspector edited the selected device's tags (added or removed one).
        /// `tags` is the full new set — the PATCH replaces all tags at once, and
        /// the fresh device row reconciles back into the observed tables on success.
        case tagsEdited(deviceCode: String, tags: [String])
        /// A rejected/failed tag update, surfaced in the inspector's command alert.
        case tagUpdateFailed(String)
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.devicesClient) var devicesClient
    @Dependency(\.deviceRefresher) var deviceRefresher
    @Dependency(\.deviceStaleness) var deviceStaleness
    @Dependency(\.commandClient) var commandClient
    @Dependency(\.replicantsClient) var replicantsClient
    @Dependency(\.locationsClient) var locationsClient
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    @Dependency(\.endEditing) var endEditing

    /// `refresh` cancels the while-viewing refresh loop when the inspected device
    /// changes; `travelPreview` cancels an in-flight dry-run so a prior device's
    /// late response can't land on the current preview.
    private enum CancelID { case refresh, travelPreview, printPreview, cargoLoad }

    /// Clear every modal the inspector could be presenting, cancelling their
    /// in-flight effects. Called at the head of each present flow: a grid tap is
    /// impossible while a real sheet/alert is on screen, so any non-nil
    /// presentation state here is provably stale — a presentation AppKit dropped
    /// (`_beginWindowBlockingModalSessionForSheet:` refuses while another
    /// window-blocking session is still tearing down; see EndEditingClient).
    /// Left in place, stale state pins the item binding non-nil and no sheet can
    /// ever present again — the dismiss actions that would clear it only fire
    /// from a *visible* sheet. Clearing here lets the new presentation pass
    /// through nil (the flow's runloop yield gives SwiftUI the tick to
    /// reconcile), so a retry always shakes the stuck sheet loose. Logged
    /// loudly: each occurrence is a dropped presentation we otherwise can't see.
    private static func clearStalePresentations(_ state: inout State) -> Effect<Action> {
        var stale: [String] = []
        if state.travelPreview != nil { stale.append("travel") }
        if state.printPreview != nil { stale.append("print") }
        if state.cargoLoad != nil { stale.append("cargo") }
        if state.directiveComposer != nil { stale.append("directive") }
        if state.commandError != nil { stale.append("alert") }
        guard !stale.isEmpty else { return .none }
        logger.warning("cleared stale presentation state (\(stale.joined(separator: "+"), privacy: .public)) — an earlier sheet presentation was dropped")
        state.travelPreview = nil
        state.printPreview = nil
        state.cargoLoad = nil
        state.directiveComposer = nil
        state.commandError = nil
        return .merge(
            .cancel(id: CancelID.travelPreview),
            .cancel(id: CancelID.printPreview),
            .cancel(id: CancelID.cargoLoad)
        )
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case let .groupDisclosureToggled(sectionID):
                if state.collapsedGroups.contains(sectionID) {
                    state.collapsedGroups.remove(sectionID)
                } else {
                    state.collapsedGroups.insert(sectionID)
                }
                return .none

            case let .hostDisclosureToggled(deviceCode):
                if state.expandedHosts.contains(deviceCode) {
                    state.expandedHosts.remove(deviceCode)
                } else {
                    state.expandedHosts.insert(deviceCode)
                }
                return .none

            case let .inspectorVisibilityChanged(deviceCode):
                // The inspected device is the staleness tracker's "visible" set:
                // its marks drain promptly, and inspecting a device spends any
                // mark it accumulated while hidden (V3.5) — the on-demand repair
                // for rows the mark-mostly event route no longer reads eagerly.
                // Driven by the detail view (selection changes, disappearance,
                // scene phase) — deliberately NOT by `viewingChanged`, whose
                // refresh-loop key is nil for every settled device and would
                // flap the visible set while the device is still on screen.
                let deviceStaleness = self.deviceStaleness
                return .run { _ in
                    await deviceStaleness.setVisible(deviceCode.map { [$0] } ?? [])
                    if let deviceCode {
                        await deviceStaleness.refreshIfStale(deviceCode)
                    }
                }

            case .task:
                // First run only: cold-load if the fleet table is empty. After
                // that the event stream keeps it warm, so navigating here doesn't spend
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
                    // local provenance is preserved, exactly like a stream-driven read.
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

            case let .travelConfirmed(deviceCode, destination):
                // Clear anything stale (see `clearStalePresentations`), end field
                // editing, and yield a runloop tick before the sheet is presented.
                // Setting `travelPreview` (in `.travelPreviewRequested`) is what
                // presents the sheet, and presenting while the destination
                // field's text-completion popover is still on screen crashes
                // AppKit's sheet presentation. All side effects live behind
                // dependencies (`endEditing`, `clock`) so this is testable — the
                // view just sends the intent.
                let reset = Self.clearStalePresentations(&state)
                let endEditing = self.endEditing
                let clock = self.clock
                return .merge(reset, .run { send in
                    await endEditing()
                    try await clock.sleep(for: .zero)
                    await send(.travelPreviewRequested(deviceCode: deviceCode, destination: destination))
                })

            case let .travelPreviewRequested(deviceCode, destination):
                state.travelPreview = TravelPreview(deviceCode: deviceCode, destination: destination)
                let commandClient = self.commandClient
                logger.info("travel preview \(deviceCode, privacy: .public) → \(destination, privacy: .public) requested")
                return .run { send in
                    await send(.travelPreviewResponse(commandClient.previewTravel(deviceCode, destination)))
                }
                // Requesting a new preview cancels any prior device's in-flight
                // dry-run, so a late response can't overwrite this one's phase.
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
                return .send(.commandConfirmed(
                    kind: .travel,
                    deviceCode: preview.deviceCode,
                    params: CommandParams(destination: preview.destination)
                ))

            case .travelPreviewDismissed:
                state.travelPreview = nil
                return .cancel(id: CancelID.travelPreview)

            case let .printConfirmed(deviceCode, deviceType, location, locationName, required):
                // Mirror of `.travelConfirmed`: clear stale state, end editing,
                // and yield before the print preview sheet presents.
                let reset = Self.clearStalePresentations(&state)
                let endEditing = self.endEditing
                let clock = self.clock
                return .merge(reset, .run { send in
                    await endEditing()
                    try await clock.sleep(for: .zero)
                    await send(.printPreviewRequested(
                        deviceCode: deviceCode,
                        deviceType: deviceType,
                        location: location,
                        locationName: locationName,
                        required: required
                    ))
                })

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
                // A new preview cancels any prior in-flight lookup so a late
                // response can't overwrite this one's phase.
                .cancellable(id: CancelID.printPreview, cancelInFlight: true)

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
                return .cancel(id: CancelID.printPreview)

            case let .cargoLoadTapped(deviceCode, location, locationName, capacityRemaining):
                // Same guard as `.travelConfirmed`: clear stale state, end
                // editing, and yield a runloop tick before the picker presents.
                let reset = Self.clearStalePresentations(&state)
                let endEditing = self.endEditing
                let clock = self.clock
                return .merge(reset, .run { send in
                    await endEditing()
                    try await clock.sleep(for: .zero)
                    await send(.cargoLoadRequested(
                        deviceCode: deviceCode,
                        location: location,
                        locationName: locationName,
                        capacityRemaining: capacityRemaining
                    ))
                })

            case let .cargoLoadRequested(deviceCode, location, locationName, capacityRemaining):
                state.cargoLoad = CargoLoadPreview(
                    deviceCode: deviceCode,
                    locationName: locationName,
                    capacityRemaining: capacityRemaining
                )
                logger.info("cargo load \(deviceCode, privacy: .public) requested")
                let locationsClient = self.locationsClient
                return .run { send in
                    guard let location, !location.isEmpty else {
                        await send(.cargoLoadResponse(.failed("This device isn’t at a location, so there’s no stockpile to load from.")))
                        return
                    }
                    do {
                        let items = try await locationsClient.inventory(at: location)
                        // Only resources actually on hand are loadable; sort by a
                        // stable canonical order so the picker rows don't shuffle.
                        let order = DeviceCommand.miningResources
                        let stock = items
                            .compactMap { item -> CargoStock? in
                                let units = Int(item.quantity)
                                guard units > 0 else { return nil }
                                return CargoStock(resourceType: item.resourceType.lowercased(), available: units)
                            }
                            .sorted { lhs, rhs in
                                let l = order.firstIndex(of: lhs.resourceType) ?? order.count
                                let r = order.firstIndex(of: rhs.resourceType) ?? order.count
                                return l == r ? lhs.resourceType < rhs.resourceType : l < r
                            }
                        await send(.cargoLoadResponse(.loaded(stock)))
                    } catch {
                        await send(.cargoLoadResponse(.failed(Self.stockpileErrorMessage(error))))
                    }
                }
                // A new request cancels a prior device's in-flight stockpile read so
                // a late response can't land on this picker's phase.
                .cancellable(id: CancelID.cargoLoad, cancelInFlight: true)

            case let .cargoLoadResponse(phase):
                // Ignore a late response if the user already dismissed the sheet.
                guard state.cargoLoad != nil else { return .none }
                state.cargoLoad?.phase = phase
                return .none

            case let .cargoLoadConfirmed(resources):
                guard let preview = state.cargoLoad else { return .none }
                state.cargoLoad = nil
                return .send(.commandConfirmed(
                    kind: .collectResources,
                    deviceCode: preview.deviceCode,
                    params: CommandParams(resources: resources)
                ))

            case .cargoLoadDismissed:
                state.cargoLoad = nil
                return .cancel(id: CancelID.cargoLoad)

            case let .replicateConfirmed(deviceCode, target, name):
                let replicantsClient = self.replicantsClient
                let devicesClient = self.devicesClient
                logger.info("replicate \(deviceCode, privacy: .public) → \(target, privacy: .public) confirmed")
                return .run { send in
                    let outcome = await replicantsClient.replicate(deviceCode, target, name)
                    if let message = outcome.failureMessage {
                        await send(.commandFinished(.rejected(message)))
                        return
                    }
                    // Success: the source matrix is consumed and its device
                    // rehosted — re-ingest the fleet and refresh the roster so
                    // the inspector reflects the new topology.
                    if let devices = try? await devicesClient.fetchAll() {
                        let reconciler = Reconciler()
                        for device in devices { await reconciler.ingest(device) }
                        await reconciler.pruneDevices(presentCodes: devices.map(\.deviceCode))
                    } else {
                        logger.warning("post-replication fleet re-ingest failed; awaiting stream echo")
                    }
                    if (try? await replicantsClient.refresh()) == nil {
                        logger.warning("post-replication roster refresh failed; awaiting stream echo")
                    }
                }

            case .directiveComposeTapped:
                // Same dance as `.travelConfirmed`: clear stale state, end field
                // editing, and yield a runloop tick before the sheet-presenting
                // state is set — a sheet presented while a text field's
                // completion popover is up crashes AppKit's sheet presentation.
                let reset = Self.clearStalePresentations(&state)
                let endEditing = self.endEditing
                let clock = self.clock
                return .merge(reset, .run { send in
                    await endEditing()
                    try await clock.sleep(for: .zero)
                    await send(.directiveComposerPresented)
                })

            case .directiveComposerPresented:
                guard let device = state.selectedDevice else { return .none }
                logger.info("directive composer \(device.deviceCode, privacy: .public) presented")
                state.directiveComposer = DirectiveComposer.State(device: device, fleet: state.devices)
                return .none

            case let .directiveComposer(.presented(.delegate(.confirmed(directive, configuration)))):
                guard let deviceCode = state.directiveComposer?.deviceCode else { return .none }
                return .send(.commandConfirmed(
                    kind: .setDirective,
                    deviceCode: deviceCode,
                    params: CommandParams(directive: directive, configuration: configuration)
                ))

            case .directiveComposer:
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
                    // stream-/deadline-driven read instead of firing a duplicate
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

            case let .tagsEdited(deviceCode, tags):
                let devicesClient = self.devicesClient
                let deviceRefresher = self.deviceRefresher
                logger.info("tags edit → \(deviceCode, privacy: .public): \(tags.count, privacy: .public) tag(s)")
                return .run { _ in
                    // Replace the set server-side, then confirm-read through the
                    // coordinator (B4) so the inspector's chips reflect confirmed
                    // state and the PATCH's SSE echo is TTL-suppressed. A failed
                    // confirm-read after a successful PATCH is deliberately NOT
                    // surfaced as an error (the tags did change); the echo or the
                    // next poll catches the row up.
                    try await devicesClient.updateTags(deviceCode, tags)
                    _ = await deviceRefresher.refresh(deviceCode, .high)
                } catch: { error, send in
                    let message = (error as? DevicesClient.TagUpdateError)?.message ?? error.localizedDescription
                    await send(.tagUpdateFailed(message))
                }

            case let .tagUpdateFailed(message):
                logger.warning("tag update failed: \(message, privacy: .public)")
                state.commandError = message
                return .none
            }
        }
        .ifLet(\.$directiveComposer, action: \.directiveComposer) {
            DirectiveComposer()
        }
    }

    /// A user-facing message for a failed location-stockpile read behind the Load
    /// Cargo picker. A presence-gated location (no replicant in system) gets a
    /// pointed hint; anything else is reported generically.
    static func stockpileErrorMessage(_ error: Error) -> String {
        switch error {
        case LocationsError.noReplicantInSystem:
            return "No replicant is in this system, so its stockpile isn’t visible from here."
        case LocationsError.notFound:
            return "This location has no readable stockpile."
        default:
            return "Couldn’t read this location’s stockpile."
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
        case "repairing":
            // Repair's bar self-interpolates from its ETA; the poll just keeps the
            // server progress/target current and catches completion (when the bot
            // settles, the loop stops). A modest fixed tick.
            return .seconds(15)
        default:
            return nil
        }
    }
}
