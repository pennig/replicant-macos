//
//  PrintQueueFeatureTests.swift
//  Replicould — Print Queue feature
//
//  The reducer owns only intent — cold load / refresh and command dispatch
//  (enqueue / dequeue / clear). These pin that a dispatched command routes
//  through `CommandClient` and that a rejection surfaces where the user fired it,
//  while an accepted command stays quiet (the tables it mutates are observed).
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import GameServices
import SQLiteData
import Testing
@testable import PrintQueueFeature

/// A stand-in error whose `localizedDescription` is a known string.
private struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Suite struct PrintQueueFeatureTests {

    /// A rejected command surfaces its message as the inspector command error.
    @Test func rejectedCommandSurfacesError() async throws {
        let database = try GameDatabase.bootstrap()
        let captured = LockIsolated<(OperationKind, String, CommandParams)?>(nil)
        let store = TestStore(initialState: PrintQueueFeature.State()) {
            PrintQueueFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { kind, code, params in
                captured.setValue((kind, code, params))
                return .rejected("Printer is busy")
            }
        }

        await store.send(.commandConfirmed(kind: .dequeuePrint, deviceCode: "965AC2C3", params: CommandParams(index: 1)))
        await store.receive(\.commandFinished) {
            $0.commandError = "Printer is busy"
        }

        let sent = captured.value
        #expect(sent?.0 == .dequeuePrint)
        #expect(sent?.1 == "965AC2C3")
        #expect(sent?.2.index == 1)
    }

    /// An accepted command mutates the observed tables, not feature state — no
    /// error is set.
    @Test func acceptedCommandStaysQuiet() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: PrintQueueFeature.State()) {
            PrintQueueFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.commandClient.dispatch = { _, _, _ in .accepted(operationID: nil) }
        }

        await store.send(.commandConfirmed(kind: .print, deviceCode: "965AC2C3", params: CommandParams(deviceType: "ftl_beacon")))
        await store.receive(\.commandFinished)
        #expect(store.state.commandError == nil)
    }

    /// Dismissing the command error clears it.
    @Test func dismissCommandErrorClears() async throws {
        let database = try GameDatabase.bootstrap()
        let store = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            var initial = PrintQueueFeature.State()
            initial.commandError = "boom"
            return TestStore(initialState: initial) { PrintQueueFeature() }
        }
        await store.send(.dismissCommandError) { $0.commandError = nil }
    }

    /// A cold-load failure surfaces a banner and clears the loading flag.
    @Test func loadFailureSurfacesError() async throws {
        let database = try GameDatabase.bootstrap()
        let store = TestStore(initialState: PrintQueueFeature.State()) {
            PrintQueueFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.devicesClient.fetchAll = { throw StubError(message: "offline") }
        }

        await store.send(.load) { $0.isLoading = true }
        await store.receive(\.loadFailed) {
            $0.isLoading = false
            $0.errorMessage = "offline"
        }
    }

    /// Dismissing the load error clears it.
    @Test func dismissErrorClears() async throws {
        let database = try GameDatabase.bootstrap()
        let store = withDependencies {
            $0.defaultDatabase = database
        } operation: {
            var initial = PrintQueueFeature.State()
            initial.errorMessage = "boom"
            return TestStore(initialState: initial) { PrintQueueFeature() }
        }
        await store.send(.dismissError) { $0.errorMessage = nil }
    }
}
