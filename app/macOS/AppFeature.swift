//
//  AppFeature.swift
//  Replicant
//
//  The root of the app. It owns the whole session lifecycle: it decides whether
//  to show the first-launch (login) screen or the signed-in main experience
//  (restored synchronously from the Keychain at launch), and tears the session
//  down on logout.
//

import AppKit
import ComposableArchitecture
import SwiftUI

/// The two mutually-exclusive top-level states of the app: the user is either
/// signed out (first-launch screen) or signed in (main experience). Modeling
/// this as an enum makes the "both nil / both set" states unrepresentable.
@Reducer
enum AppState {
    case loggedOut(LoginFeature)
    case loggedIn(MainFeature)
}

@Reducer
struct AppFeature {
    @ObservableState
    struct State {
        var appState: AppState.State
        var preferences = PreferencesFeature.State()

        var isLoggedOut: Bool {
            if case .loggedOut = appState { true } else { false }
        }

        /// Decide the initial session synchronously by consulting the Keychain,
        /// so the very first frame is already correct (no logged-out flash).
        init() {
            @Dependency(KeychainClient.self) var keychain
            if let apiKey = keychain.load(KeychainClient.apiKeyAccount) {
                appState = .loggedIn(MainFeature.State(account: .mock, apiKey: apiKey))
            } else {
                appState = .loggedOut(LoginFeature.State())
            }
        }
    }

    enum Action {
        case appState(AppState.Action)
        case preferences(PreferencesFeature.Action)
    }

    @Dependency(KeychainClient.self) var keychain

    var body: some Reducer<State, Action> {
        Scope(state: \.preferences, action: \.preferences) {
            PreferencesFeature()
        }
        Scope(state: \.appState, action: \.appState) {
            AppState.body
        }
        Reduce { state, action in
            switch action {
            case let .appState(.loggedOut(.delegate(.loggedIn(apiKey)))):
                state.appState = .loggedIn(MainFeature.State(account: .mock, apiKey: apiKey))
                return .none

            case .appState(.loggedIn(.delegate(.loggedOut))):
                state.appState = .loggedOut(LoginFeature.State())
                let keychain = self.keychain
                return .run { _ in
                    try? keychain.delete(KeychainClient.apiKeyAccount)
                }

            case .appState, .preferences:
                return .none
            }
        }
    }
}

// MARK: - Root view

struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        Group {
            switch store.scope(state: \.appState, action: \.appState).case {
            case let .loggedOut(loginStore):
                LoginView(store: loginStore)
            case let .loggedIn(mainStore):
                MainView(store: mainStore)
            }
        }
        // Drive the whole app's appearance from the persisted preference, with
        // the first-launch (logged-out) screen pinned to dark. Setting the
        // application's appearance keeps every window and split-view column
        // consistent — unlike per-view `preferredColorScheme`, which competes
        // across windows for the single app-level appearance.
        .onChange(
            of: AppearanceSelection(isLoggedOut: store.isLoggedOut, appearance: store.preferences.appearance),
            initial: true
        ) { _, selection in
            NSApp.appearance = selection.resolved
        }
    }
}

/// The resolved app-wide appearance: the first-launch screen is always dark;
/// otherwise the user's persisted preference wins.
private struct AppearanceSelection: Equatable {
    var isLoggedOut: Bool
    var appearance: Appearance

    var resolved: NSAppearance? {
        isLoggedOut ? NSAppearance(named: .darkAqua) : appearance.nsAppearance
    }
}
