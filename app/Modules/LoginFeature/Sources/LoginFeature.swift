//
//  LoginFeature.swift
//  Replicant
//
//  The first-launch / sign-in screen. The user pastes an API key, which is
//  written to the Keychain; on success the feature signals its parent (via a
//  delegate action) that the session is now authenticated.
//

import ComposableArchitecture
import DependencyClients
import SwiftUI
import UI

@Reducer
public struct LoginFeature {
    @ObservableState
    public struct State: Equatable {
        var apiKey: String
        var isSaving: Bool
        var revealKey: Bool
        
        public init(apiKey: String = "", isSaving: Bool = false, revealKey: Bool = false) {
            self.apiKey = apiKey
            self.isSaving = isSaving
            self.revealKey = revealKey
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case delegate(Delegate)
        case loginButtonTapped

        public enum Delegate {
            case loggedIn(apiKey: String)
        }
    }

    public init() {}
    
    @Dependency(\.keychain) var keychain

    public var body: some Reducer<State, Action> {
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

public struct LoginView: View {
    @Bindable var store: StoreOf<LoginFeature>
    
    public init(store: StoreOf<LoginFeature>) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Image(systemName: "circle.hexagongrid.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("Replicould")
                        .font(.largeTitle.bold())
                    HStack(spacing: 0) {
                        Text("A fun interface for the API-based game,")
                            .foregroundStyle(.secondary)
                        Button("replicant.space") {
                            
                        }.buttonStyle(RCButtonStyle(.text))
                    }
                }

                VStack(alignment: .leading, spacing: Space.l) {
                    RCField(
                        "API Key",
                        text: $store.apiKey,
                        placeholder: "e.g. xsPaUKCPJx…",
                        hint: "paste the key from your account",
                        mono: true,
                        secure: true
                    )
                    
                    Button {
                        store.send(.loginButtonTapped)
                    } label: {
                        if store.isSaving {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            HStack(spacing: Space.xs) {
                                Text("Log in")
                                Image(systemName: "arrow.right")
                            }
                        }
                    }
                    .buttonStyle(RCButtonStyle(.primary, fullWidth: true))
                }
                .frame(maxWidth: 360)
            }
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
