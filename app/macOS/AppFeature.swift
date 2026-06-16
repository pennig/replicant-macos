//
//  AppFeature.swift
//  Replicant
//
//  The root of the app. It owns the whole session lifecycle: it decides whether
//  to show the first-launch (login) screen or the signed-in main experience,
//  restores an existing session from the Keychain on launch, and tears the
//  session down on logout.
//

import ComposableArchitecture
import SwiftUI

/// Identifiers for the auxiliary windows.
enum ReplicantWindow {
    static let account = "account"
}

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        /// Non-nil while signed out — the first-launch screen.
        var login: LoginFeature.State? = LoginFeature.State()
        /// Non-nil while signed in — the main experience.
        var main: MainFeature.State?
        var preferences = PreferencesFeature.State()
    }

    enum Action {
        case login(LoginFeature.Action)
        case main(MainFeature.Action)
        case preferences(PreferencesFeature.Action)
        case onAppear
        case sessionRestored(apiKey: String)
    }

    @Dependency(KeychainClient.self) var keychain

    var body: some Reducer<State, Action> {
        Scope(state: \.preferences, action: \.preferences) {
            PreferencesFeature()
        }
        Reduce { state, action in
            switch action {
            case .onAppear:
                // Restore an existing session if a key is already in the Keychain.
                guard state.main == nil else { return .none }
                let keychain = self.keychain
                return .run { send in
                    if let apiKey = keychain.load(KeychainClient.apiKeyAccount) {
                        await send(.sessionRestored(apiKey: apiKey))
                    }
                }

            case let .sessionRestored(apiKey):
                state.login = nil
                state.main = MainFeature.State(account: .mock, apiKey: apiKey)
                return .none

            case let .login(.delegate(.loggedIn(apiKey))):
                state.login = nil
                state.main = MainFeature.State(account: .mock, apiKey: apiKey)
                return .none

            case .main(.delegate(.loggedOut)):
                state.main = nil
                state.login = LoginFeature.State()
                let keychain = self.keychain
                return .run { _ in
                    try? keychain.delete(KeychainClient.apiKeyAccount)
                }

            case .login, .main, .preferences:
                return .none
            }
        }
        .ifLet(\.login, action: \.login) {
            LoginFeature()
        }
        .ifLet(\.main, action: \.main) {
            MainFeature()
        }
    }
}

// MARK: - Root view

struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        Group {
            if let loginStore = store.scope(state: \.login, action: \.login) {
                // First-launch window — always dark (LoginView forces it).
                LoginView(store: loginStore)
            } else if let mainStore = store.scope(state: \.main, action: \.main) {
                MainView(store: mainStore)
                    .preferredColorScheme(store.preferences.appearance.colorScheme)
            }
        }
        .task { store.send(.onAppear) }
    }
}

// MARK: - Account window root
//
// The Account window shares the root store. It shows account info while signed
// in, and dismisses itself once the session ends (after logout).

struct AccountWindowRoot: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let mainStore = store.scope(state: \.main, action: \.main) {
                AccountView(store: mainStore)
            } else {
                ContentUnavailableView("Not Signed In", systemImage: "person.slash")
            }
        }
        .preferredColorScheme(store.preferences.appearance.colorScheme)
        .frame(minWidth: 380, minHeight: 320)
        .onChange(of: store.main == nil) { _, signedOut in
            if signedOut { dismissWindow(id: ReplicantWindow.account) }
        }
    }
}
