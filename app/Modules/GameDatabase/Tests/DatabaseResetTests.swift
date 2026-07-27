//
//  DatabaseResetTests.swift
//  GameDatabaseTests
//

import Foundation
import Testing

@testable import GameDatabase

@Suite struct DatabaseResetTests {
    /// A fresh suite of defaults per test, so nothing leaks between them.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func noTriggersMeansNoReset() {
        let defaults = makeDefaults("rc.reset.none")
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]) == false)
    }

    @Test func environmentVariableRequestsReset() {
        let defaults = makeDefaults("rc.reset.env")
        let environment = [DatabaseReset.environmentKey: "1"]
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: environment))
    }

    @Test func flagRequestsResetAndIsClearedImmediately() {
        let defaults = makeDefaults("rc.reset.flag")
        DatabaseReset.requestOnNextLaunch(defaults: defaults)

        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]))
        // Cleared BEFORE the erase runs, so a crash mid-erase cannot produce a
        // reset loop that wipes the database on every launch.
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]) == false)
    }

    @Test func isPendingDoesNotConsumeTheFlag() {
        let defaults = makeDefaults("rc.reset.peek")
        DatabaseReset.requestOnNextLaunch(defaults: defaults)

        // Asking twice must report the same answer both times — a peek, not a
        // consume — so the caller can poll it in a wait loop.
        #expect(DatabaseReset.isPending(defaults: defaults, environment: [:]))
        #expect(DatabaseReset.isPending(defaults: defaults, environment: [:]))

        // The flag is still there for the real consumer to burn.
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]))
        #expect(DatabaseReset.isPending(defaults: defaults, environment: [:]) == false)
    }
}
