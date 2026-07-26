//
//  DirectivesFeature.swift
//  Replicould — Directives feature
//
//  The unified Directives surface: built-in AMI directives (derived from the
//  fleet, server-executed) beside custom multi-step missions (the Directive
//  table, app-executed). Both queries live in state per the house standard, so
//  the views stay pure renderers and the list never flashes empty.
//
//  There is no engine yet — Stage 3 adds it. Today the custom half of the list
//  is simply empty, and the feature's only writes are the built-in half's
//  Reconfigure (via the shared composer) and Clear.
//

import ComposableArchitecture
import DirectiveComposerFeature
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

        /// The selected row's namespaced id (see `DirectiveRow.id`).
        public var selectedRowID: String?
        /// A failed or rejected command, shown as a banner over the list.
        public var errorMessage: String?
        /// The `set_directive` editor, presented from a built-in row's detail
        /// pane. Feature-tier sheet ⇒ `@Presents` + `.ifLet`.
        @Presents public var composer: DirectiveComposer.State?
        /// The new-mission launcher. Also feature-tier.
        @Presents public var newDirective: NewDirectiveFeature.State?

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
        case composer(PresentationAction<DirectiveComposer.Action>)
        case newDirective(PresentationAction<NewDirectiveFeature.Action>)
    }

    public init() {}

    @Dependency(\.commandClient) var commandClient

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
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

            case let .newDirective(.presented(.delegate(.created(directive)))):
                // Select the run that was just launched, so the detail pane is
                // showing its timeline as the engine starts working it.
                state.selectedRowID = "custom:\(directive.id)"
                return .none

            case .newDirective:
                return .none
            }
        }
        .ifLet(\.$composer, action: \.composer) {
            DirectiveComposer()
        }
        .ifLet(\.$newDirective, action: \.newDirective) {
            NewDirectiveFeature()
        }
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
