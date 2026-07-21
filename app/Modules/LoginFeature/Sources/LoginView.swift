//
//  LoginView.swift
//  Replicant — first-launch / sign-in screen.
//
//  A faithful SwiftUI port of "First Launch - Bloom.html": the Bloom mark as a
//  live logo (ReplicouldLogoView), a continuously radiating hex→circle ring
//  field (RingField), a seeded starfield + violet deep-space backdrop
//  (CosmicBackdrop), and the Log in / Create account / verify forms — driven by
//  LoginFeature.
//

import ComposableArchitecture
import SwiftUI
import UI

// MARK: - Logo-center reporting (so rings emanate from the mark)

private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }

// MARK: - Root view

public struct LoginView: View {
    @Bindable var store: StoreOf<LoginFeature>
    @State private var logoCenter: CGPoint = .zero

    public init(store: StoreOf<LoginFeature>) {
        self.store = store
    }

    // All IANA time zone identifiers known to the system (always includes the current
    // zone), grouped by region — the prefix before the first "/".
    private let zoneGroups: [(region: String, identifiers: [String])] = {
        Dictionary(grouping: TimeZone.knownTimeZoneIdentifiers) { id in
            id.split(separator: "/").first.map(String.init) ?? id
        }
        .map { (region: $0.key, identifiers: $0.value.sorted()) }
        .sorted { $0.region < $1.region }
    }()

    public var body: some View {
        GeometryReader { _ in
            ZStack {
                CosmicBackground()
                RingField(origin: logoCenter == .zero ? CGPoint(x: 380, y: 136) : logoCenter)
                Starfield()
                Veil()
                content
            }
            .coordinateSpace(name: "screen")
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(P.winBot)
        .alert($store.scope(state: \.alert, action: \.alert))
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            // brand
            VStack(spacing: Space.s) {
                ReplicouldLogoView(size: 116)
                    .onGeometryChange(for: CGPoint.self) { proxy in
                        proxy.frame(in: .named("screen")).center
                    } action: { center in
                        withAnimation(.easeOut(duration: 0.15)) { logoCenter = center }
                    }
                VStack(spacing: 2) {
                    Text("Repli\(Text("could").italic())")
                        .font(.system(size: 26, weight: .bold)) // brand wordmark — deliberate one-off, not a text style
                        .foregroundStyle(.rcTextPrimary)
                    HStack(spacing: 0) {
                        Text("A fun interface for the API-based game,")
                        .foregroundStyle(.secondary)
                        Button("replicant.space") {

                        }.buttonStyle(RCButtonStyle(.text))
                    }
                }
            }
            .padding(.bottom, Space.xl)

            if store.mode != .confirmation {
                modeFooter.padding(.bottom, Space.xl)
            }

            Group {
                switch store.mode {
                case .login:        loginForm
                case .signup:       signupForm
                case .confirmation: confirmationForm
                }
            }
            .frame(maxWidth: 400)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 56) // deliberate: login form gutter, no token
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: store.mode)
    }

    @ViewBuilder private var modeFooter: some View {
        if store.mode == .login {
            footer(prompt: "No account yet? ", action: "Create one", trailing: " to get started.") { store.mode = .signup }
        } else {
            footer(prompt: "Already have a key? ", action: "Log in instead", trailing: ".") { store.mode = .login }
        }
    }

    private var loginForm: some View {
        VStack(spacing: Space.m) {
            RCField("API Key", text: $store.apiKey, placeholder: "xsPaUKCPJxa…",
                    hint: "paste the key from your account", mono: true, secure: true)
            submit("Log in") { store.send(.submitKeyTapped) }
        }
        .transition(.opacity)
    }

    private var signupForm: some View {
        VStack(spacing: Space.m) {
            RCField("Name", text: $store.name, placeholder: "What should we call you?")
            RCField("Email", text: $store.email, placeholder: "you@example.com")
            VStack(alignment: .leading, spacing: Space.xs + 2) {
                Text("Time zone".uppercased())
                    .font(.rcFieldLabel).kerning(0.5)
                    .foregroundStyle(.rcTextTertiary)
                timeZoneField
            }
            submit("Begin") { store.send(.signupButtonTapped) }
        }
        .transition(.opacity)
    }

    /// Post-signup: the server emailed a verification link; the key is shown on
    /// that page, so the user pastes it here just like the login screen.
    private var confirmationForm: some View {
        VStack(spacing: Space.m) {
            VStack(spacing: 6) {
                Text("Check your email")
                    .font(.rcHeadline)
                    .foregroundStyle(.rcTextPrimary)
                Text(verificationMessage)
                    .font(.rcBody)
                    .foregroundStyle(.rcTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 2)
            RCField("API Key", text: $store.apiKey, placeholder: "xsPaUKCPJxa…",
                    hint: "from the verification page", mono: true, secure: true)
            submit("Continue") { store.send(.submitKeyTapped) }
        }
        .transition(.opacity)
    }

    private var verificationMessage: String {
        let destination = store.email.isEmpty ? "your inbox" : store.email
        return "We sent a verification link to \(destination). Open it, then paste the API key shown on that page below."
    }

    /// Full-width primary CTA — shows a spinner while a request is in flight.
    private func submit(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if store.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: Space.s) {
                        Text(title)
                        Image(systemName: "arrow.right")
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(RCButtonStyle(.primary, fullWidth: true))
        .disabled(store.isSaving)
    }

    /// Grouped time-zone menu with an `RCValueSelect`-style field trigger.
    private var timeZoneField: some View {
        Menu {
            Picker("Time zone", selection: $store.timeZone) {
                ForEach(zoneGroups, id: \.region) { group in
                    Section(group.region) {
                        ForEach(group.identifiers, id: \.self) { id in
                            Text(zoneLabel(id)).tag(id)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: Space.s - 2) {
                Image(systemName: "clock")
                    .font(.system(size: IconSize.m))
                    .foregroundStyle(.rcTextTertiary)
                Text(store.timeZone.replacingOccurrences(of: "_", with: " "))
                    .font(.rcMono)
                    .foregroundStyle(.rcTextPrimary)
                Spacer(minLength: Space.xs)
                Image(systemName: "chevron.down")
                    .font(.system(size: IconSize.s, weight: .semibold))
                    .foregroundStyle(.rcTextSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .padding(.horizontal, Space.m)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(.rcSeparator, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// Display name for a zone within its region section: drops the region prefix
    /// (keeping any sub-region, e.g. "Argentina/Buenos Aires") and de-underscores.
    private func zoneLabel(_ id: String) -> String {
        let rest = id.split(separator: "/").dropFirst()
        let name = rest.isEmpty ? id : rest.joined(separator: "/")
        return name.replacingOccurrences(of: "_", with: " ")
    }

    private func footer(prompt: String, action: String, trailing: String, tap: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Text(prompt).foregroundStyle(.rcTextTertiary)
            Button(action, action: tap)
                .buttonStyle(.plain).foregroundStyle(.rcAccent)
            Text(trailing).foregroundStyle(.rcTextTertiary)
        }
        .font(.rcCaption)
        .padding(.top, 6)
    }
}

#Preview("First launch") {
    LoginView(store: Store(initialState: LoginFeature.State()) { LoginFeature() })
        .frame(width: 760, height: 560)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .windowResizeBehavior(.disabled)
}

#Preview("Signup · error") {
    LoginView(store: Store(initialState: {
        var state = LoginFeature.State(mode: .signup, name: "Roy", email: "roy@tyrell.example")
        state.alert = AlertState {
            TextState("Couldn’t create account")
        } message: {
            TextState("An account with that email already exists.")
        }
        return state
    }()) {
        LoginFeature()
    })
    .frame(width: 760, height: 560)
    .toolbarVisibility(.hidden, for: .windowToolbar)
    .windowResizeBehavior(.disabled)
}
