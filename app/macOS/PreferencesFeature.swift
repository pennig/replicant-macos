//
//  PreferencesFeature.swift
//  Replicant
//
//  The Preferences (⌘,) surface: lets the user respect the system appearance or
//  override to Light/Dark. The chosen appearance applies to every window except
//  the first-launch screen, which is always dark.
//

import AppKit
import ComposableArchitecture
import SwiftUI

@Reducer
struct PreferencesFeature {
    @ObservableState
    struct State: Equatable {
        // Persisted in user defaults and shared across every scene. Binding it
        // through `BindingReducer` writes straight back to the shared store.
        @Shared(.appStorage("appearance")) var appearance: Appearance = .system
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
    }

    var body: some Reducer<State, Action> {
        BindingReducer()
    }
}

/// The appearance the app windows adopt — except the first-launch window, which
/// is always dark.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The color scheme a window adopts; `nil` follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The AppKit appearance to force application-wide; `nil` follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension View {
    /// Drives the appearance preference at the AppKit level by setting
    /// `NSApp.appearance`. Unlike `preferredColorScheme` — which only flows a
    /// color scheme through a window's SwiftUI content — this updates every
    /// window's chrome (traffic lights, title) and every `NavigationSplitView`
    /// column uniformly and immediately. The first-launch window still pins
    /// itself dark via its own per-window `preferredColorScheme`, which
    /// overrides the app-level appearance for that one window.
    func applyAppAppearance(_ appearance: Appearance) -> some View {
        onChange(of: appearance, initial: true) { _, appearance in
            NSApp.appearance = appearance.nsAppearance
        }
    }
}

struct PreferencesView: View {
    @Bindable var store: StoreOf<PreferencesFeature>

    var body: some View {
        Form {
            Picker("Appearance", selection: Binding(store.state.$appearance)) {
                ForEach(Appearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .pickerStyle(.inline)
        }
        .frame(width: 360)
        .navigationTitle("Preferences")
    }
}
