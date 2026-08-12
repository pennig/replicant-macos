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
    /// The reserved `selectedRowID` meaning "show the brain, not a run".
    ///
    /// Safe as a sentinel because every real row id is namespaced —
    /// `DirectiveRow.id` is `builtin:<code>` or `custom:<id>` — so this can
    /// never collide with one, and `selectedRow` resolves it to nil without
    /// needing to know about it.
    public static let brainSelectionID = "brain"

    @ObservableState
    public struct State: Equatable {
        /// The fleet — the source of every built-in row. `currentDirective` is
        /// read out of the device's JSON tail, not a column, so the filter runs
        /// in Swift (see `DirectiveRow.merge`) rather than in SQL.
        @ObservationStateIgnored
        @FetchAll(Device.order { $0.deviceCode }, animation: .default)
        public var devices: [Device]

        /// Custom missions the operator has not cleared, newest first. A
        /// cleared run keeps its row and its timeline; it just leaves the list.
        @ObservationStateIgnored
        @FetchAll(
            Directive.where { $0.deletedAt.is(nil) }.order { $0.createdAt.desc() },
            animation: .default
        )
        public var directives: [Directive]

        /// The selected row's timeline — a mission's steps, or a built-in
        /// directive's completion history. Reloaded on selection change (see
        /// `selectionChanged`), since the query is keyed by what's selected.
        @ObservationStateIgnored
        @Fetch(DirectiveTimeline(directiveID: nil, deviceCode: nil))
        public var timeline = DirectiveTimeline.Value()

        /// The automation brain's latest tick, published by
        /// `DirectiveEngineCore.tickBrain()` (see `BrainReport`). Nil before
        /// the first tick of a session — the engine starts with the sync
        /// engine on login, so on a cold launch there is genuinely nothing to
        /// explain yet, and an empty card would be a worse answer than none.
        ///
        /// In-memory shared state, not a query: the why-view is DERIVED, and
        /// the brain design forbids giving it a table.
        @Shared(.brainReport) public var brainReport: BrainReport?

        /// The selected row's namespaced id (see `DirectiveRow.id`).
        public var selectedRowID: String?
        /// Restricts `rows` to one theatre's depot; nil shows every theatre.
        /// An unassigned row is never hidden — see `visibleRows`.
        public var theatreFilter: String?
        /// Ranked new-theatre-site proposals, loaded once when the brain pane
        /// opens (`brainTapped`) — never on the render path, since
        /// `TheatreSiteRanking.rank` walks the whole star catalogue.
        public var theatreCandidates: [TheatreSiteRanking.Candidate] = []
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
        /// The Print Mine Fleet launcher — a confirm dialog rather than its own
        /// reducer, since there is no form: nothing to pick, only a fixed print.
        @Presents public var printMineFleetDialog: ConfirmationDialogState<Action.PrintMineFleet>?

        public init(selectedRowID: String? = nil) {
            self.selectedRowID = selectedRowID
        }

        /// The merged list, restricted to `theatreFilter`.
        public var rows: [DirectiveRow] {
            visibleRows(DirectiveRow.merge(devices: devices, directives: directives))
        }

        /// `rows` filtered to the selected theatre. An unassigned row (no
        /// `theatreDepot`) is kept under every filter — it is the row an
        /// operator must not lose track of after a migration.
        public func visibleRows(_ rows: [DirectiveRow]) -> [DirectiveRow] {
            guard let theatreFilter else { return rows }
            return rows.filter { $0.theatreDepot == nil || $0.theatreDepot == theatreFilter }
        }

        /// Recognised theatre depots, for the filter picker.
        public var theatreOptions: [String] {
            (brainReport?.theatres.map(\.depot) ?? []).sorted()
        }

        /// The brain's why-view, derived from the latest tick. Computed here
        /// rather than stored so it can never fall out of step with the
        /// report it explains.
        public var brainWhy: BrainWhy? {
            brainReport.map(BrainWhy.from(report:))
        }

        /// The selected row, or nil when nothing (or something stale) is selected.
        public var selectedRow: DirectiveRow? {
            guard let selectedRowID else { return nil }
            return rows.first { $0.id == selectedRowID }
        }

        /// Whether the detail pane is showing the brain rather than a run.
        ///
        /// Rides the SAME `selectedRowID` as the rows, on a reserved id no row
        /// can produce (`DirectiveRow.id` is always `builtin:`/`custom:`
        /// prefixed). One selection means the two can never both be showing:
        /// picking a run in the list writes its id here and the brain drops out
        /// on its own, with no second piece of state to keep in step.
        public var isBrainSelected: Bool { selectedRowID == DirectivesFeature.brainSelectionID }

        /// How many finished runs will be cleared (marked for deletion). Drives
        /// the menu item's label and gates whether it is offered. Rows persist
        /// a month before removal.
        public var finishedCount: Int {
            directives.count { DirectiveResolutionClient.finishedStatuses.contains($0.status) }
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
        /// Open the Print Mine Fleet confirm dialog (or the already-running one).
        case printMineFleetTapped
        case printMineFleetDialog(PresentationAction<PrintMineFleet>)
        /// The confirm effect's insert succeeded.
        case printMineFleetLaunched(Directive)
        /// The confirm effect found no eligible print host.
        case printMineFleetHostMissing
        /// Stall resolution on the selected custom mission (design spec §8).
        case retryTapped
        case skipTargetTapped
        case cancelRunTapped
        case pauseTapped
        case resumeTapped
        /// Clear every finished (`.completed`/`.cancelled`) run from the list.
        case clearFinishedTapped
        /// Show the brain's full report in the detail pane.
        case brainTapped
        /// A fresh theatre-site ranking finished loading.
        case theatreCandidatesLoaded([TheatreSiteRanking.Candidate])
        case composer(PresentationAction<DirectiveComposer.Action>)
        case newDirective(PresentationAction<NewDirectiveFeature.Action>)
        case newSalvageRun(PresentationAction<NewSalvageRunFeature.Action>)
        case newHaulRun(PresentationAction<NewHaulRunFeature.Action>)

        @CasePathable
        public enum PrintMineFleet: Equatable, Sendable {
            case confirm
        }
    }

    public init() {}

    @Dependency(\.commandClient) var commandClient
    @Dependency(\.directiveResolution) var directiveResolution
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date
    @Dependency(\.uuid) var uuid

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
                    logger.notice("reconfigure refused on \(builtIn.deviceCode, privacy: .public): \(builtIn.drivenBy?.logDescription ?? "-", privacy: .public)")
                    return .none
                }
                guard let device = state.selectedDevice else { return .none }
                logger.info("directive composer \(device.deviceCode, privacy: .public) presented")
                state.composer = DirectiveComposer.State(device: device, fleet: state.devices)
                return .none

            case .clearTapped:
                guard case let .builtIn(builtIn) = state.selectedRow else { return .none }
                guard builtIn.drivenBy == nil else {
                    logger.notice("clear refused on \(builtIn.deviceCode, privacy: .public): \(builtIn.drivenBy?.logDescription ?? "-", privacy: .public)")
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

            case .printMineFleetTapped:
                let alreadyRunning = state.directives.contains {
                    $0.kind == .mineFleetPrint && DirectiveStatus.openCases.contains($0.status)
                }
                state.printMineFleetDialog = alreadyRunning
                    ? Self.alreadyPrintingDialog : Self.confirmPrintDialog
                return .none

            case .printMineFleetDialog(.presented(.confirm)):
                let database = self.database
                let uuid = self.uuid
                let date = self.date
                return .run { send in
                    let devices = (try? await database.read { db in try Device.all.fetchAll(db) }) ?? []
                    guard let host = devices
                        .filter({
                            $0.isPrintHub && $0.deviceType != "heaven_vessel"
                                && $0.deviceType != "racing_vessel" && $0.location != nil
                        })
                        .min(by: { $0.deviceCode < $1.deviceCode })
                    else {
                        await send(.printMineFleetHostMissing)
                        return
                    }
                    let directive = Directive(
                        id: uuid().uuidString, kind: .mineFleetPrint, status: .running,
                        deviceCode: host.deviceCode, controllerCode: nil, roamCentre: nil,
                        fleetTag: MineRecipe.fleetTag, sourceRelayCode: nil,
                        targets: [], targetIndex: 0,
                        step: MineFleetPrint().firstStep, stepStartedAt: date.now,
                        returnToOrigin: false, originDesignation: nil,
                        attentionReason: nil, createdAt: date.now, updatedAt: date.now
                    )
                    try? await database.write { db in try Directive.insert { directive }.execute(db) }
                    logger.info("printing mine fleet \(directive.id, privacy: .public) at \(host.deviceCode, privacy: .public)")
                    await send(.printMineFleetLaunched(directive))
                }

            case .printMineFleetDialog:
                return .none

            case .printMineFleetLaunched:
                return .none

            case .printMineFleetHostMissing:
                state.printMineFleetDialog = Self.noHostDialog
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

            case .brainTapped:
                state.selectedRowID = Self.brainSelectionID
                // Deliberately NOT `selectionChanged`: the brain has no
                // timeline, and re-running the query for it would clear the
                // one belonging to whatever run was selected a moment ago —
                // work the next real selection would only have to redo.
                return loadTheatreCandidates()

            case let .theatreCandidatesLoaded(candidates):
                state.theatreCandidates = candidates
                return .none

            case .clearFinishedTapped:
                // Drop a selection to a finishing run before the write: directives
                // is a live query, so rows vanish the moment it commits.
                if case let .custom(directive, _) = state.selectedRow,
                   DirectiveResolutionClient.finishedStatuses.contains(directive.status) {
                    state.selectedRowID = nil
                }
                let resolution = self.directiveResolution
                return .run { _ in
                    let cleared = await resolution.clearFinished()
                    logger.info("cleared \(cleared) finished run(s)")
                }

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
        .ifLet(\.$printMineFleetDialog, action: \.printMineFleetDialog)
    }

    private static let confirmPrintDialog = ConfirmationDialogState<Action.PrintMineFleet> {
        TextState("Print a mine fleet?")
    } actions: {
        ButtonState(action: .confirm) { TextState("Print") }
        ButtonState(role: .cancel) { TextState("Cancel") }
    } message: {
        TextState(
            "Eleven devices, 3,455 units from hub stock, plus a surge carrier if none is idle. The brain sites and delivers it when complete."
        )
    }

    private static let alreadyPrintingDialog = ConfirmationDialogState<Action.PrintMineFleet> {
        TextState("Already printing a mine fleet")
    } actions: {
        ButtonState(role: .cancel) { TextState("OK") }
    } message: {
        TextState("A mine fleet print is already running.")
    }

    private static let noHostDialog = ConfirmationDialogState<Action.PrintMineFleet> {
        TextState("No autofactory found at the hub.")
    } actions: {
        ButtonState(role: .cancel) { TextState("OK") }
    }

    /// One `WorldView` read plus the CPU-bound rank, run only from this
    /// effect — never a view's `body` or `onChange` — since
    /// `TheatreSiteRanking.rank` walks the whole star catalogue.
    private func loadTheatreCandidates() -> Effect<Action> {
        let database = self.database
        let date = self.date
        return .run { send in
            let view = try await database.read { db in try WorldView.read(from: db, now: date.now) }
            await send(.theatreCandidatesLoaded(TheatreSiteRanking.rank(view: view)))
        } catch: { error, _ in
            logger.error("theatre candidate load failed: \(error.localizedDescription, privacy: .public)")
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
