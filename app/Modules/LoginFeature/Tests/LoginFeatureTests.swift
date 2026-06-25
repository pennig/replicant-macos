//
//  LoginFeatureTests.swift
//  Replicould — Login feature
//
//  Drives the reducer through the shared `gameClient` dependency, stubbed with a
//  canned `ClientTransport`, so the signup and key-validation round-trips are
//  exercised end-to-end (status code → reducer outcome) alongside the input
//  guards and alert / mode plumbing.
//

import API
import ComposableArchitecture
import DependencyClients
import Foundation
import HTTPTypes
import OpenAPIRuntime
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

    /// 201 clears the spinner and advances to the verify step.
    @Test func signupSuccessAdvancesToConfirmation() async {
        let store = TestStore(
            initialState: LoginFeature.State(mode: .signup, name: "Roy", email: "roy@tyrell.example")
        ) {
            LoginFeature()
        } withDependencies: {
            $0.gameClient = stubGameClient { _ in jsonResponse(201) }
        }

        await store.send(.signupButtonTapped) { $0.isSaving = true }
        await store.receive(\.signupResponse) {
            $0.isSaving = false
            $0.mode = .confirmation
        }
    }

    /// 409 surfaces the server's error message in an alert.
    @Test func signupConflictShowsAlert() async {
        let store = TestStore(
            initialState: LoginFeature.State(mode: .signup, name: "Roy", email: "taken@tyrell.example")
        ) {
            LoginFeature()
        } withDependencies: {
            $0.gameClient = stubGameClient { _ in jsonResponse(409, #"{"error":"Email taken"}"#) }
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

    /// A 200 from /me means the key is good: it stays in the Keychain and the
    /// parent is told the session is authenticated.
    @Test func validKeySavesAndLogsIn() async {
        let saves = LockIsolated<[String]>([])
        let deletes = LockIsolated<[String]>([])
        let store = TestStore(initialState: LoginFeature.State(mode: .login, apiKey: "rk_live_abc")) {
            LoginFeature()
        } withDependencies: {
            $0.gameClient = stubGameClient { _ in jsonResponse(200) }
            $0.keychain.save = { value, _ in saves.withValue { $0.append(value) } }
            $0.keychain.delete = { account in deletes.withValue { $0.append(account) } }
        }

        await store.send(.submitKeyTapped) { $0.isSaving = true }
        await store.receive(\.delegate.loggedIn, "rk_live_abc")

        #expect(saves.value == ["rk_live_abc"])
        #expect(deletes.value.isEmpty)
    }

    /// A non-200 from /me rejects the key, rolling back the Keychain write.
    @Test func invalidKeyIsRejectedAndRolledBack() async {
        let saves = LockIsolated<[String]>([])
        let deletes = LockIsolated<[String]>([])
        let store = TestStore(initialState: LoginFeature.State(mode: .login, apiKey: "bad")) {
            LoginFeature()
        } withDependencies: {
            $0.gameClient = stubGameClient { _ in jsonResponse(401) }
            $0.keychain.save = { value, _ in saves.withValue { $0.append(value) } }
            $0.keychain.delete = { account in deletes.withValue { $0.append(account) } }
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

        #expect(saves.value == ["bad"])
        #expect(deletes.value == [KeychainClient.apiKeyAccount])
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

// MARK: - Stubbed game client

/// Vends a `GameClient` whose generated `Client` is backed by a canned transport.
private func stubGameClient(
    _ respond: @escaping @Sendable (HTTPRequest) -> (HTTPResponse, HTTPBody?)
) -> GameClient {
    GameClient(make: {
        Client(serverURL: URL(string: "https://stub.invalid")!, transport: StubTransport(respond: respond))
    })
}

/// A `ClientTransport` that returns a fixed response, ignoring the request.
private struct StubTransport: ClientTransport {
    let respond: @Sendable (HTTPRequest) -> (HTTPResponse, HTTPBody?)
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        respond(request)
    }
}

/// A JSON response with the given status code and body.
private func jsonResponse(_ status: Int, _ body: String = "{}") -> (HTTPResponse, HTTPBody?) {
    (
        HTTPResponse(status: .init(code: status), headerFields: [.contentType: "application/json"]),
        HTTPBody(Array(body.utf8))
    )
}
