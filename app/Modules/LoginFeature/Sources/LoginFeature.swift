//
//  LoginFeature.swift
//  Replicant
//
//  The first-launch screen. Three modes share one reducer:
//   • login        — paste an existing API key
//   • signup       — name/email/timezone → create an account (server emails a
//                     verification link; the key is shown on that page)
//   • confirmation — paste the key from the verification page
//
//  This reducer is pure UI flow: it owns the form fields, the saving spinner, and
//  the alerts. All account *business logic* — validating/signing in a key,
//  signing up, persisting the profile + roster — lives in `@Dependency(\.account
//  Manager)`. On a successful sign-in it just signals the parent (delegate) that
//  the session is authenticated.
//

import AccountManager
import ComposableArchitecture
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
        case signupResponse(Result<Void, AccountManager.SignupError>)
        case submitKeyTapped
        case keyRejected(message: String)

        @CasePathable
        public enum Delegate {
            case loggedIn(apiKey: String)
        }
        public enum Alert: Equatable {}
    }

    public init() {}

    @Dependency(\.accountManager) var accountManager

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
                let accountManager = self.accountManager
                state.isSaving = true
                return .run { send in
                    do {
                        try await accountManager.signUp(name, email, timeZone)
                        await send(.signupResponse(.success(())))
                    } catch let error as AccountManager.SignupError {
                        await send(.signupResponse(.failure(error)))
                    } catch {
                        await send(.signupResponse(.failure(
                            .init("Something went wrong creating your account. Please try again.")
                        )))
                    }
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
                let accountManager = self.accountManager
                state.isSaving = true
                return .run { send in
                    do {
                        try await accountManager.logIn(apiKey)
                        await send(.delegate(.loggedIn(apiKey: apiKey)))
                    } catch let error as AccountManager.LoginError {
                        let message = switch error {
                        case .rejected:
                            "That key was rejected. Double-check it and try again."
                        case .verificationFailed:
                            "Couldn’t verify the key. Check your connection and try again."
                        }
                        await send(.keyRejected(message: message))
                    } catch {
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
