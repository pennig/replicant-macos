//
//  LoginFeature.swift
//  Replicant
//
//  The first-launch screen. Three modes share one reducer:
//   • login        — paste an existing API key
//   • signup       — name/email/timezone → POST /v1/accounts (server emails a
//                     verification link; the key is shown on that page)
//   • confirmation — paste the key from the verification page
//
//  "Log in" / "Continue" validate the pasted key against GET /v1/accounts/me
//  before signaling the parent (delegate) that the session is authenticated.
//  Because `gameClient()` authenticates with the *stored* key, validation writes
//  the pasted key to the Keychain first, then deletes it again if it's rejected.
//
//  All backend calls go through the shared `@Dependency(\.gameClient)` (the base
//  `ReplicantSpace` client) — these endpoints carry no domain model worth
//  wrapping, and routing through the dependency keeps the reducer testable.
//

import API
import ComposableArchitecture
import DependencyClients
import Foundation

@Reducer
public struct LoginFeature {
    public enum Mode: Equatable, Sendable { case login, signup, confirmation }

    @ObservableState
    public struct State: Equatable {
        var mode: Mode
        var apiKey: String
        var name: String
        var email: String
        var timeZone: String
        var isSaving: Bool
        @Presents var alert: AlertState<Action.Alert>?

        public init(
            mode: Mode = .signup,
            apiKey: String = "",
            name: String = "",
            email: String = "",
            timeZone: String = TimeZone.current.identifier,
            isSaving: Bool = false
        ) {
            self.mode = mode
            self.apiKey = apiKey
            self.name = name
            self.email = email
            self.timeZone = timeZone
            self.isSaving = isSaving
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case delegate(Delegate)
        case alert(PresentationAction<Alert>)
        case signupButtonTapped
        case signupResponse(Result<Void, SignupError>)
        case submitKeyTapped
        case keyRejected(message: String)

        @CasePathable
        public enum Delegate {
            case loggedIn(apiKey: String)
        }
        public enum Alert: Equatable {}
    }

    /// A signup failure carrying a user-facing message (so `Action` stays Equatable).
    public struct SignupError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    public init() {}

    @Dependency(\.keychain) var keychain
    @Dependency(\.gameClient) var gameClient

    public var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding, .delegate, .alert:
                return .none

            // MARK: Signup

            case .signupButtonTapped:
                let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let email = state.email.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !email.isEmpty else { return .none }
                let timeZone = state.timeZone
                let gameClient = self.gameClient
                state.isSaving = true
                return .run { send in
                    await send(.signupResponse(
                        await register(gameClient(), name: name, email: email, timeZone: timeZone)
                    ))
                }

            case .signupResponse(.success):
                state.isSaving = false
                state.mode = .confirmation
                return .none

            case let .signupResponse(.failure(error)):
                state.isSaving = false
                state.alert = AlertState {
                    TextState("Couldn’t create account")
                } message: {
                    TextState(error.message)
                }
                return .none

            // MARK: Login / confirmation (paste a key)

            case .submitKeyTapped:
                let apiKey = state.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !apiKey.isEmpty else { return .none }
                let keychain = self.keychain
                let gameClient = self.gameClient
                state.isSaving = true
                return .run { send in
                    do {
                        // Store first so `gameClient()` authenticates with this key…
                        try keychain.save(apiKey, KeychainClient.apiKeyAccount)
                        guard case .ok = try await gameClient().getV1AccountsMe() else {
                            try? keychain.delete(KeychainClient.apiKeyAccount)   // …roll back a bad key
                            await send(.keyRejected(message: "That key was rejected. Double-check it and try again."))
                            return
                        }
                        await send(.delegate(.loggedIn(apiKey: apiKey)))
                    } catch {
                        try? keychain.delete(KeychainClient.apiKeyAccount)
                        await send(.keyRejected(message: "Couldn’t verify the key. Check your connection and try again."))
                    }
                }

            case let .keyRejected(message):
                state.isSaving = false
                state.alert = AlertState {
                    TextState("Sign-in failed")
                } message: {
                    TextState(message)
                }
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}

/// Create the account. The server replies 201 and emails a verification link;
/// the API key itself is revealed on that page (pasted back in `.confirmation`).
private func register(
    _ client: Client,
    name: String,
    email: String,
    timeZone: String
) async -> Result<Void, LoginFeature.SignupError> {
    do {
        let output = try await client.postV1Accounts(
            body: .json(.init(email: email, name: name, timezone: timeZone))
        )
        switch output {
        case .created:
            return .success(())
        case let .conflict(response):
            return .failure(.init((try? response.body.json.error) ?? "An account with that email already exists."))
        case let .badRequest(response):
            return .failure(.init((try? response.body.json.error) ?? "Please check your details and try again."))
        default:
            return .failure(.init("Something went wrong creating your account. Please try again."))
        }
    } catch {
        return .failure(.init("Something went wrong creating your account. Please try again."))
    }
}
