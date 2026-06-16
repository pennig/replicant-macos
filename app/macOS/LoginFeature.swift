//
//  LoginFeature.swift
//  Replicant
//
//  The first-launch / sign-in screen. The user pastes an API key, which is
//  written to the Keychain; on success the feature signals its parent (via a
//  delegate action) that the session is now authenticated.
//

import ComposableArchitecture
import SwiftUI

@Reducer
struct LoginFeature {
    @ObservableState
    struct State: Equatable {
        var apiKey = ""
        var isSaving = false
        var revealKey = false
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case delegate(Delegate)
        case loginButtonTapped

        enum Delegate {
            case loggedIn(apiKey: String)
        }
    }

    @Dependency(\.keychain) var keychain

    var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .delegate:
                return .none

            case .loginButtonTapped:
                let apiKey = state.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !apiKey.isEmpty else { return .none }
                state.isSaving = true
                let keychain = self.keychain
                return .run { send in
                    try keychain.save(apiKey, KeychainClient.apiKeyAccount)
                    await send(.delegate(.loggedIn(apiKey: apiKey)))
                }
            }
        }
    }
}

struct LoginView: View {
    @Bindable var store: StoreOf<LoginFeature>

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Image(systemName: "circle.hexagongrid.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("Replicant")
                        .font(.largeTitle.bold())
                    Text("Paste your API key to sign in.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Group {
                            if store.revealKey {
                                TextField("rk_live_…", text: $store.apiKey)
                            } else {
                                SecureField("rk_live_…", text: $store.apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                        Button(store.revealKey ? "Hide" : "Show") {
                            store.revealKey.toggle()
                        }
                        .buttonStyle(.borderless)
                    }

                    Button {
                        store.send(.loginButtonTapped)
                    } label: {
                        if store.isSaving {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Log in").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.apiKey.trimmingCharacters(in: .whitespaces).isEmpty || store.isSaving)
                }
                .frame(maxWidth: 360)
            }
            .padding(40)
        }
    }
}

#Preview {
    LoginView(
        store: Store(initialState: LoginFeature.State()) {
            LoginFeature()
        }
    )
    .frame(width: 640, height: 520)
}
