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
}
