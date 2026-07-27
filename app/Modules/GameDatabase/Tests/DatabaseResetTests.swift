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
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]) == nil)
    }

    @Test func environmentVariableRequestsReset() {
        let defaults = makeDefaults("rc.reset.env")
        let environment = [DatabaseReset.environmentKey: "1"]
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: environment) == .environmentVariable)
    }

    @Test func flagRequestsResetAndIsClearedImmediately() {
        let defaults = makeDefaults("rc.reset.flag")
        DatabaseReset.requestOnNextLaunch(defaults: defaults)

        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]) == .armedFlag)
        // Cleared BEFORE the erase runs, so a crash mid-erase cannot produce a
        // reset loop that wipes the database on every launch.
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]) == nil)
    }

    @Test func isPendingDoesNotConsumeTheFlag() {
        let defaults = makeDefaults("rc.reset.peek")
        DatabaseReset.requestOnNextLaunch(defaults: defaults)

        // Asking twice must report the same answer both times — a peek, not a
        // consume — so the caller can poll it in a wait loop.
        #expect(DatabaseReset.isPending(defaults: defaults, environment: [:]))
        #expect(DatabaseReset.isPending(defaults: defaults, environment: [:]))

        // The flag is still there for the real consumer to burn.
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]) == .armedFlag)
        #expect(DatabaseReset.isPending(defaults: defaults, environment: [:]) == false)
    }

    @Test func pendingTriggerDoesNotConsumeEither() {
        let defaults = makeDefaults("rc.reset.pendingTrigger")
        DatabaseReset.requestOnNextLaunch(defaults: defaults)

        #expect(DatabaseReset.pendingTrigger(defaults: defaults, environment: [:]) == .armedFlag)
        #expect(DatabaseReset.pendingTrigger(defaults: defaults, environment: [:]) == .armedFlag)
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]) == .armedFlag)
    }

    @Test func armedFlagTakesPrecedenceOverEnvironmentVariable() {
        let defaults = makeDefaults("rc.reset.precedence")
        DatabaseReset.requestOnNextLaunch(defaults: defaults)
        let environment = [DatabaseReset.environmentKey: "1"]

        #expect(DatabaseReset.pendingTrigger(defaults: defaults, environment: environment) == .armedFlag)
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: environment) == .armedFlag)
    }

    @Test func cancelPendingRequestDisarmsWithoutConsuming() {
        let defaults = makeDefaults("rc.reset.cancel")
        DatabaseReset.requestOnNextLaunch(defaults: defaults)
        #expect(DatabaseReset.isPending(defaults: defaults, environment: [:]))

        DatabaseReset.cancelPendingRequest(defaults: defaults)

        #expect(DatabaseReset.isPending(defaults: defaults, environment: [:]) == false)
        #expect(DatabaseReset.consumeRequest(defaults: defaults, environment: [:]) == nil)
    }

    /// `declineEnvironmentVariableRequest` operates on the REAL process
    /// environment (that's the whole point — it has to reach the same
    /// `ProcessInfo.processInfo.environment` read that `bootstrap()` performs
    /// moments later), so this test sets and restores the actual variable
    /// rather than passing a mock dictionary like every other test here.
    @Test func decliningTheEnvironmentVariableWithdrawsItForThisProcess() {
        let key = DatabaseReset.environmentKey
        let previous = ProcessInfo.processInfo.environment[key]
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        setenv(key, "1", 1)
        #expect(ProcessInfo.processInfo.environment[key] == "1")

        DatabaseReset.declineEnvironmentVariableRequest()

        #expect(ProcessInfo.processInfo.environment[key] == nil)
    }
}
