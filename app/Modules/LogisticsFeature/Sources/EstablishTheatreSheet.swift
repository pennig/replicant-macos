//
//  EstablishTheatreSheet.swift
//  Replicould — Logistics feature
//
//  The operator's half of "brain proposes, operator establishes": pick a
//  depot location and write a `TheatrePin`. Establishing writes the pin and
//  nothing else — recognition does the rest on the engine's next tick.
//

import ComposableArchitecture
import Foundation
import GameModels
import SwiftUI
import UI

@Reducer
public struct EstablishTheatreSheet {
    /// A `system_hub` print's baseline cost — rises with hubs already owned,
    /// and it is the largest single spend in the game, so it is stated here.
    public static let systemHubCostUnits = 6_800
    public static let systemHubCostHours = 16

    @ObservableState
    public struct State: Equatable {
        /// Read-only context only — a bare system is never a legal depot, so
        /// it is never written into `location` for the operator to accept unread.
        public var suggestedSystem: String?
        public var location = ""
        public var isSaving = false
        public var errorMessage: String?

        public init(suggestedSystem: String? = nil) {
            self.suggestedSystem = suggestedSystem
        }

        /// Blank refuses, and so does the bare candidate system re-typed
        /// verbatim — no device ever reports itself at a bare system code.
        public var canEstablish: Bool {
            let trimmed = location.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !isSaving else { return false }
            if let suggestedSystem { return trimmed.uppercased() != suggestedSystem.uppercased() }
            return true
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case confirmTapped
        case pinWritten(String)
        case saveFailed(String)
        case cancelTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case established(String)
        }
    }

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date) var date
    @Dependency(\.dismiss) var dismiss

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .confirmTapped:
                guard state.canEstablish else { return .none }
                state.isSaving = true
                state.errorMessage = nil
                let location = state.location.trimmingCharacters(in: .whitespaces)
                let database = self.database
                let date = self.date
                return .run { send in
                    do {
                        try await database.write { db in
                            try TheatrePin.insert { TheatrePin(location: location, createdAt: date.now) }.execute(db)
                        }
                        await send(.pinWritten(location))
                    } catch {
                        await send(.saveFailed(error.localizedDescription))
                    }
                }

            case let .pinWritten(location):
                state.isSaving = false
                let dismiss = self.dismiss
                return .run { send in
                    await send(.delegate(.established(location)))
                    await dismiss()
                }

            case let .saveFailed(message):
                state.isSaving = false
                state.errorMessage = message
                return .none

            case .cancelTapped:
                let dismiss = self.dismiss
                return .run { _ in await dismiss() }

            case .delegate:
                return .none
            }
        }
    }
}

struct EstablishTheatreSheetView: View {
    @Bindable var store: StoreOf<EstablishTheatreSheet>

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            RCField("Depot location", text: $store.location, placeholder: placeholderExample, mono: true)
            Text("A theatre's depot is a specific location within the system — a bare system designation can never resolve.")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            costCard
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.rcBody)
                    .foregroundStyle(.rcError)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(Space.xl)
        .frame(minWidth: 460, minHeight: 400)
        .background(Color.rcWindowBackground)
    }

    private var placeholderExample: String {
        store.suggestedSystem.map { "e.g. \($0)-BELT-1" } ?? "e.g. OMEROPE-BELT-1"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Establish a Theatre").font(.rcTitle).foregroundStyle(.rcTextPrimary)
            if let system = store.suggestedSystem {
                HStack(spacing: 4) {
                    Text("Candidate system").font(.rcCaption).foregroundStyle(.rcTextTertiary)
                    Text(system).font(.rcBodyEmphMono).foregroundStyle(.rcTextPrimary)
                }
            }
            Text("Pins the depot. Recognition — a print-capable device, stock, and mesh — completes it on the next tick.")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var costCard: some View {
        RCReadoutCard("If you print a system_hub here") {
            Text(
                "\(EstablishTheatreSheet.systemHubCostUnits.formatted(.number.locale(Locale(identifier: "en_US")))) units · ~\(EstablishTheatreSheet.systemHubCostHours) h"
            )
            .font(.rcBodyEmph)
            .foregroundStyle(.rcTextPrimary)
            Text("The largest single spend in the game — its cost rises with every hub already owned.")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.m) {
            Spacer(minLength: 0)
            Button("Cancel") { store.send(.cancelTapped) }
                .buttonStyle(RCButtonStyle(.secondary))
            Button {
                store.send(.confirmTapped)
            } label: {
                if store.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Establish")
                }
            }
            .buttonStyle(RCButtonStyle(.primary))
            .disabled(!store.canEstablish)
        }
    }
}
