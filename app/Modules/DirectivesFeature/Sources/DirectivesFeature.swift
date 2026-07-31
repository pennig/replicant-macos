//
//  DirectivesFeature.swift
//  Replicould — Directives feature
//
//  The unified Directives surface: built-in AMI directives (derived from the
//  fleet, server-executed) beside custom multi-step missions (the Directive
//  table, app-executed). Both queries live in state per the house standard, so
//  the views stay pure renderers and the list never flashes empty.
//
//  The feature's writes are the built-in half's Reconfigure (via the shared
//  composer) and Clear, launching a new mission, and resolving a stalled one.
//  It never advances a mission itself — that is `DirectiveEngine`'s job, and
//  the list simply observes the rows the engine writes.
//

import ComposableArchitecture
import DirectiveComposerFeature
import DirectiveEngine
import Foundation
import GameModels
import GameServices
import OSLog
import SQLiteData
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Directives")

@Reducer
public struct DirectivesFeature {
    @ObservableState
    public struct State: Equatable {
        /// The fleet — the source of every built-in row. `currentDirective` is
        /// read out of the device's JSON tail, not a column, so the filter runs
        /// in Swift (see `DirectiveRow.merge`) rather than in SQL.
        @ObservationStateIgnored
        @FetchAll(Device.order { $0.deviceCode }, animation: .default)
        public var devices: [Device]

        /// Custom missions, newest first.
        @ObservationStateIgnored
        @FetchAll(Directive.order { $0.createdAt.desc() }, animation: .default)
        public var directives: [Directive]

        /// The selected row's timeline — a mission's steps, or a built-in
        /// directive's completion history. Reloaded on selection change (see
        /// `selectionChanged`), since the query is keyed by what's selected.
        @ObservationStateIgnored
        @Fetch(DirectiveTimeline(directiveID: nil, deviceCode: nil))
        public var timeline = DirectiveTimeline.Value()

        /// The selected row's namespaced id (see `DirectiveRow.id`).
        public var selectedRowID: String?
        /// A failed or rejected command, shown as a banner over the list.
        public var errorMessage: String?
        /// The `set_directive` editor, presented from a built-in row's detail
        /// pane. Feature-tier sheet ⇒ `@Presents` + `.ifLet`.
        @Presents public var composer: DirectiveComposer.State?
        /// The new-mission launcher. Also feature-tier.
        @Presents public var newDirective: NewDirectiveFeature.State?
        /// The new-Salvage-Run launcher. Its own presentation, not folded into
        /// `newDirective`, because it has its own reducer with its own
        /// eligibility rule (`SalvageRun`'s fleet queries, not `SurveyRun`'s).
        @Presents public var newSalvageRun: NewSalvageRunFeature.State?
        /// The new-Haul-Run launcher. Also its own presentation — there is no
        /// picker to fold into `newDirective`, only a report-and-launch dialog.
        @Presents public var newHaulRun: NewHaulRunFeature.State?

        public init(selectedRowID: String? = nil) {
            self.selectedRowID = selectedRowID
        }

        /// The merged list.
        public var rows: [DirectiveRow] {
            DirectiveRow.merge(devices: devices, directives: directives)
        }

        /// The selected row, or nil when nothing (or something stale) is selected.
        public var selectedRow: DirectiveRow? {
            guard let selectedRowID else { return nil }
            return rows.first { $0.id == selectedRowID }
        }

        /// The full `Device` behind the selected row — the composer needs it,
        /// and the detail pane reads its status.
        public var selectedDevice: Device? {
            guard let code = selectedRow?.deviceCode else { return nil }
            return devices.first { $0.deviceCode == code }
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// Open the composer on the selected built-in row.
        case reconfigureTapped
        /// Clear the selected built-in row's directive.
        case clearTapped
        /// Confirmed clear for a specific controller.
        case clearConfirmed(deviceCode: String)
        case commandFinished(CommandOutcome)
        case dismissError
        /// Open the new-mission launcher.
        case newDirectiveTapped
        /// Open the new-Salvage-Run launcher.
        case newSalvageRunTapped
        /// Open the new-Haul-Run launcher.
        case newHaulRunTapped
        /// Stall resolution on the selected custom mission (design spec §8).
        case retryTapped
        case skipTargetTapped
        case cancelRunTapped
        case pauseTapped
        case resumeTapped
        case composer(PresentationAction<DirectiveComposer.Action>)
        case newDirective(PresentationAction<NewDirectiveFeature.Action>)
        case newSalvageRun(PresentationAction<NewSalvageRunFeature.Action>)
        case newHaulRun(PresentationAction<NewHaulRunFeature.Action>)
    }

    public init() {}

    @Dependency(\.commandClient) var commandClient
    @Dependency(\.directiveResolution) var directiveResolution

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.selectedRowID):
                return selectionChanged(&state)

            case .binding:
                return .none

            case .reconfigureTapped:
                guard case let .builtIn(builtIn) = state.selectedRow else { return .none }
                // Engine-owned: a mission set this directive and one of its
                // steps is waiting on it. Editing it here would stall that
                // mission. Guarded in the reducer, not only by the view's
                // `.disabled`, so no future keyboard or menu path slips past.
                guard builtIn.drivenBy == nil else {
                    logger.notice("reconfigure refused on \(builtIn.deviceCode, privacy: .public): driven by directive \(builtIn.drivenBy?.directiveID ?? "-", privacy: .public)")
                    return .none
                }
                guard let device = state.selectedDevice else { return .none }
                logger.info("directive composer \(device.deviceCode, privacy: .public) presented")
                state.composer = DirectiveComposer.State(device: device, fleet: state.devices)
                return .none

            case .clearTapped:
                guard case let .builtIn(builtIn) = state.selectedRow else { return .none }
                guard builtIn.drivenBy == nil else {
                    logger.notice("clear refused on \(builtIn.deviceCode, privacy: .public): driven by directive \(builtIn.drivenBy?.directiveID ?? "-", privacy: .public)")
                    return .none
                }
                return .send(.clearConfirmed(deviceCode: builtIn.deviceCode))

            case let .clearConfirmed(code):
                return dispatch(.clearDirective, code, CommandParams())

            case let .composer(.presented(.delegate(.confirmed(directive, configuration)))):
                guard let code = state.composer?.deviceCode else { return .none }
                return dispatch(
                    .setDirective,
                    code,
                    CommandParams(directive: directive, configuration: configuration)
                )

            case .composer:
                return .none

            case let .commandFinished(outcome):
                switch outcome {
                case .accepted:
                    state.errorMessage = nil
                case let .rejected(message), let .failed(message):
                    logger.notice("directive command failed: \(message, privacy: .public)")
                    state.errorMessage = message
                }
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none

            case .newDirectiveTapped:
                state.newDirective = NewDirectiveFeature.State()
                return .none

            case .newSalvageRunTapped:
                state.newSalvageRun = NewSalvageRunFeature.State()
                return .none

            case .newHaulRunTapped:
                state.newHaulRun = NewHaulRunFeature.State()
                return .none

            case .retryTapped:
                return resolve(state) { await $0.retry($1) }

            case .skipTargetTapped:
                return resolve(state) { await $0.skipTarget($1) }

            case .cancelRunTapped:
                return resolve(state) { await $0.cancel($1) }

            case .pauseTapped:
                return resolve(state) { await $0.pause($1) }

            case .resumeTapped:
                return resolve(state) { await $0.resume($1) }

            case let .newDirective(.presented(.delegate(.created(directive)))):
                // Select the run that was just launched, so the detail pane is
                // showing its timeline as the engine starts working it. Set the
                // selection BEFORE building the request, or it resolves against
                // the previous one.
                state.selectedRowID = "custom:\(directive.id)"
                return selectionChanged(&state)

            case .newDirective:
                return .none

            case let .newSalvageRun(.presented(.delegate(.created(directive)))):
                // Same handoff as `newDirective` above — the two launchers are
                // separate presentations, but a freshly launched run gets
                // selected either way.
                state.selectedRowID = "custom:\(directive.id)"
                return selectionChanged(&state)

            case .newSalvageRun:
                return .none

            case let .newHaulRun(.presented(.delegate(.created(directive)))):
                // Same handoff as the other launchers — a freshly launched run
                // gets selected.
                state.selectedRowID = "custom:\(directive.id)"
                return selectionChanged(&state)

            case .newHaulRun:
                return .none
            }
        }
        .ifLet(\.$composer, action: \.composer) {
            DirectiveComposer()
        }
        .ifLet(\.$newDirective, action: \.newDirective) {
            NewDirectiveFeature()
        }
        .ifLet(\.$newSalvageRun, action: \.newSalvageRun) {
            NewSalvageRunFeature()
        }
        .ifLet(\.$newHaulRun, action: \.newHaulRun) {
            NewHaulRunFeature()
        }
    }

    /// Re-run the timeline query for whatever is selected now. Called from BOTH
    /// selection paths — the binding and the launcher's programmatic select —
    /// because missing the second is the easy bug (`BobnetFeature` carries the
    /// same helper for the same reason).
    private func selectionChanged(_ state: inout State) -> Effect<Action> {
        let request = DirectiveTimeline.request(for: state.selectedRow)
        return .run { [fetch = state.$timeline] _ in
            _ = try? await fetch.load(request)
        }
    }

    /// Run a resolution verb against the selected CUSTOM row. Guarded on row
    /// kind for the same reason the built-in verbs are: a built-in row's
    /// `deviceCode` is a controller, not a directive id, so an unguarded handler
    /// would resolve nothing — or the wrong thing.
    private func resolve(
        _ state: State,
        _ verb: @escaping @Sendable (DirectiveResolutionClient, String) async -> Void
    ) -> Effect<Action> {
        guard case let .custom(directive, _) = state.selectedRow else { return .none }
        // Bound to a local: referencing the property wrapper inside the
        // @Sendable closure would capture the non-Sendable reducer.
        let resolution = self.directiveResolution
        let id = directive.id
        return .run { _ in await verb(resolution, id) }
    }

    /// Dispatch a command. `CommandClient.dispatch` already issues the
    /// authoritative `.high` confirm-read for `.immediate`-class commands
    /// (`set_directive`/`clear_directive` both are) and deliberately skips it
    /// on the rejected path — so there is no explicit refresh here: the
    /// accepted op surfaces via table observation, matching
    /// `DevicesFeature.commandConfirmed`.
    private func dispatch(
        _ kind: OperationKind,
        _ deviceCode: String,
        _ params: CommandParams
    ) -> Effect<Action> {
        let commandClient = self.commandClient
        return .run { send in
            await send(.commandFinished(commandClient.dispatch(kind, deviceCode, params)))
        }
    }
}
