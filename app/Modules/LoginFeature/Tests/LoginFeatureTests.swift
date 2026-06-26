//
//  LoginFeatureTests.swift
//  Replicould — Login feature
//
//  `LoginFeature` is now pure UI flow: it delegates all account business logic to
//  `@Dependency(\.accountManager)`. These tests stub the manager to drive the
//  signup and key-validation outcomes, and verify the input guards, mode
//  transitions, alerts, and the `loggedIn` delegate. (The real persistence
//  round-trip lives in `AccountManagerTests`.)
//

import AccountManager
import ComposableArchitecture
import Foundation
import Testing
@testable import LoginFeature

@MainActor
@Suite struct LoginFeatureTests {

    // MARK: Input guards

    /// Tapping "Begin" with empty name/email is a no-op (no request, no spinner).
    @Test func signupWithEmptyFieldsDoesNothing() async {
        let store = TestStore(initialState: LoginFeature.State(mode: .signup)) {
            LoginFeature()
        }
        await store.send(.signupButtonTapped)
    }

    /// Submitting an empty key is a no-op.
    @Test func submitWithEmptyKeyDoesNothing() async {
        let store = TestStore(initialState: LoginFeature.State(mode: .login)) {
            LoginFeature()
        }
        await store.send(.submitKeyTapped)
    }

    // MARK: Signup round-trip

    /// A successful signup clears the spinner and advances to the verify step.
    @Test func signupSuccessAdvancesToConfirmation() async {
        let store = TestStore(
            initialState: LoginFeature.State(mode: .signup, name: "Roy", email: "roy@tyrell.example")
        ) {
            LoginFeature()
        } withDependencies: {
            $0.accountManager.signUp = { _, _, _ in }
        }

        await store.send(.signupButtonTapped) { $0.isSaving = true }
        await store.receive(\.signupResponse) {
            $0.isSaving = false
            $0.mode = .confirmation
        }
    }

    /// A signup failure surfaces the manager's error message in an alert.
    @Test func signupConflictShowsAlert() async {
        let store = TestStore(
            initialState: LoginFeature.State(mode: .signup, name: "Roy", email: "taken@tyrell.example")
        ) {
            LoginFeature()
        } withDependencies: {
            $0.accountManager.signUp = { _, _, _ in throw AccountManager.SignupError("Email taken") }
        }

        await store.send(.signupButtonTapped) { $0.isSaving = true }
        await store.receive(\.signupResponse) {
            $0.isSaving = false
            $0.alert = AlertState<LoginFeature.Action.Alert> {
                TextState("Couldn’t create account")
            } message: {
                TextState("Email taken")
            }
        }
    }

    // MARK: Key validation round-trip

    /// A successful sign-in tells the parent the session is authenticated.
    @Test func validKeyLogsIn() async {
        let store = TestStore(initialState: LoginFeature.State(mode: .login, apiKey: "rk_live_abc")) {
            LoginFeature()
        } withDependencies: {
            $0.accountManager.logIn = { _ in }
        }

        await store.send(.submitKeyTapped) { $0.isSaving = true }
        await store.receive(\.delegate.loggedIn, "rk_live_abc")
    }

    /// A rejected key surfaces the "rejected" message in an alert.
    @Test func rejectedKeyShowsAlert() async {
        let store = TestStore(initialState: LoginFeature.State(mode: .login, apiKey: "bad")) {
            LoginFeature()
        } withDependencies: {
            $0.accountManager.logIn = { _ in throw AccountManager.LoginError.rejected }
        }

        await store.send(.submitKeyTapped) { $0.isSaving = true }
        await store.receive(\.keyRejected) {
            $0.isSaving = false
            $0.alert = AlertState<LoginFeature.Action.Alert> {
                TextState("Sign-in failed")
            } message: {
                TextState("That key was rejected. Double-check it and try again.")
            }
        }
    }

    /// A failed verification surfaces the "couldn’t verify" message.
    @Test func verificationFailureShowsAlert() async {
        let store = TestStore(initialState: LoginFeature.State(mode: .login, apiKey: "rk_live_abc")) {
            LoginFeature()
        } withDependencies: {
            $0.accountManager.logIn = { _ in throw AccountManager.LoginError.verificationFailed }
        }

        await store.send(.submitKeyTapped) { $0.isSaving = true }
        await store.receive(\.keyRejected) {
            $0.isSaving = false
            $0.alert = AlertState<LoginFeature.Action.Alert> {
                TextState("Sign-in failed")
            } message: {
                TextState("Couldn’t verify the key. Check your connection and try again.")
            }
        }
    }

    // MARK: Plumbing

    /// The footer toggles between modes via the binding.
    @Test func footerTogglesMode() async {
        let store = TestStore(initialState: LoginFeature.State(mode: .signup)) {
            LoginFeature()
        }
        await store.send(.binding(.set(\.mode, .login))) { $0.mode = .login }
        await store.send(.binding(.set(\.mode, .signup))) { $0.mode = .signup }
    }

    /// Dismissing the alert clears it.
    @Test func dismissingAlertClearsIt() async {
        var state = LoginFeature.State(mode: .signup)
        state.alert = AlertState<LoginFeature.Action.Alert> { TextState("Couldn’t create account") }
        let store = TestStore(initialState: state) { LoginFeature() }

        await store.send(.alert(.dismiss)) { $0.alert = nil }
    }
}
