//
//  AppFeature.swift
//  Replicant
//
//  The root of the app. It owns the whole session lifecycle: it decides whether
//  to show the first-launch (login) screen or the signed-in main experience
//  (restored synchronously from the Keychain at launch), and tears the session
//  down on logout.
//

import AccountManager
import ComposableArchitecture
import EventLogFeature
import GameModels
import LoginFeature
import RawAPIFeature
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

        init() {
            /// Decide the initial session synchronously by restoring the stored
            /// token, so the very first frame is already correct (no logged-out flash).
            @Dependency(\.accountManager) var accountManager
            if let apiKey = accountManager.restoredAPIKey() {
                appState = .loggedIn(MainFeature.State(apiKey: apiKey))
            } else {
                appState = .loggedOut(LoginFeature.State())
            }
        }
        
        init(appState: AppState.State) {
            self.appState = appState
        }
    }

    enum Action {
        case appState(AppState.Action)
        case preferences(PreferencesFeature.Action)
    }

    @Dependency(\.accountManager) var accountManager

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
                state.appState = .loggedIn(MainFeature.State(apiKey: apiKey))
                return .none

            case .appState(.loggedIn(.delegate(.loggedOut))):
                state.appState = .loggedOut(LoginFeature.State())
                let accountManager = self.accountManager
                return .run { _ in
                    await accountManager.logOut()
                }

            case .appState, .preferences:
                return .none
            }
        }
    }
}

// MARK: - Window roots

/// Root of the first-launch window. Renders the sign-in screen (always dark)
/// and, once authenticated, hands off to the main window before closing itself.
struct LoginWindow: View {
    let store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let loginStore = store.scope(state: \.appState.loggedOut, action: \.appState.loggedOut) {
                LoginView(store: loginStore)
            }
        }
        .preferredColorScheme(.dark)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .windowResizeBehavior(.disabled)
        .onChange(of: store.isLoggedOut, initial: true) { _, isLoggedOut in
            // Authenticated: open the main window, then close the login window.
            // Open-before-dismiss keeps at least one window alive throughout.
            if !isLoggedOut {
                openWindow(id: WindowID.main)
                dismissWindow(id: WindowID.login)
            }
        }
    }
}

/// Root of the Raw API Access window. Scopes into the signed-in session so the
/// composer authenticates with the live API key and shares the in-memory request
/// history. When signed out there's nothing to show — the window can't be opened
/// from the (disabled) Tools menu, but guard anyway so a restored window is empty.
struct RawAPIWindow: View {
    let store: StoreOf<AppFeature>
    @Shared(.appStorage("appearance")) var appearance: Appearance = .system

    var body: some View {
        Group {
            if let mainStore = store.scope(state: \.appState.loggedIn, action: \.appState.loggedIn) {
                RawAPIView(store: mainStore.scope(state: \.rawAPI, action: \.rawAPI))
            } else {
                ContentUnavailableView(
                    "Not Signed In",
                    systemImage: "lock",
                    description: Text("Sign in to use Raw API Access.")
                )
            }
        }
        .applyAppAppearance(appearance)
    }
}

/// Root of the SSE Event Log window. Scopes into the signed-in session so it can
/// observe the persisted event ledger. When signed out there's nothing to show —
/// the window can't be opened from the (disabled) Tools menu, but guard anyway so
/// a restored window is empty.
struct EventLogWindow: View {
    let store: StoreOf<AppFeature>
    @Shared(.appStorage("appearance")) var appearance: Appearance = .system

    var body: some View {
        Group {
            if let mainStore = store.scope(state: \.appState.loggedIn, action: \.appState.loggedIn) {
                EventLogView(store: mainStore.scope(state: \.eventLog, action: \.eventLog))
            } else {
                ContentUnavailableView(
                    "Not Signed In",
                    systemImage: "lock",
                    description: Text("Sign in to view the Event Log.")
                )
            }
        }
        .applyAppAppearance(appearance)
    }
}

/// Root of the signed-in window. Renders the main experience, follows the
/// appearance preference, and on logout hands back to the login window.
struct MainWindow: View {
    let store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Shared(.appStorage("appearance")) var appearance: Appearance = .system

    var body: some View {
        Group {
            if let mainStore = store.scope(state: \.appState.loggedIn, action: \.appState.loggedIn) {
                MainView(store: mainStore)
            } else {
                ContentUnavailableView(
                    "Not Signed In",
                    systemImage: "lock",
                    description: Text("Sign in to use Replicould.")
                )
            }
        }
        .applyAppAppearance(appearance)
        .onChange(of: store.isLoggedOut, initial: true) { _, isLoggedOut in
            // Signed out: reopen the login window, then close the main window.
            if isLoggedOut {
                openWindow(id: WindowID.login)
                // Use `.destructive` so the window dismisses even while the
                // Account sheet (which hosts the Log Out button) is still on
                // screen. The default `.interactive` behavior refuses to close
                // a window that's showing a modal presentation, which would
                // otherwise leave the main window stranded behind the sheet.
                withTransaction(\.dismissBehavior, .destructive) {
                    dismissWindow(id: WindowID.main)
                }
            }
        }
    }
}
