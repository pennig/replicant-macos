//
//  DatabaseReset.swift
//  GameDatabase
//
//  The one deliberate way to wipe the local database. Reset happens ONLY at
//  bootstrap, before the SSE ingestion pipeline, the directive engine, and any
//  @FetchAll observer are running — an in-place erase would drop tables out
//  from under all three. Both triggers feed this single path.
//

import Foundation

public enum DatabaseReset {
    /// Set by the Tools ▸ Reset Local Database… menu item, consumed at the
    /// next launch.
    public static let userDefaultsKey = "RCResetDatabaseOnNextLaunch"

    /// The rescue path: available in every configuration, because a bad schema
    /// can stop the app launching at all, which is exactly when a menu item is
    /// unreachable.
    public static let environmentKey = "RC_RESET_DATABASE"

    /// Which of the two triggers armed a pending reset. Kept distinct (rather
    /// than a `Bool`) because the two triggers get different treatment: the
    /// armed flag was already confirmed once, at the Tools menu, and clears
    /// itself on read; the env var is unconfirmed, sticky across every launch
    /// until someone edits the scheme, and is the reason this type exists at
    /// all — see `ReplicantApp.awaitSoleInstanceIfResetPending`.
    public enum Trigger: Sendable, Equatable {
        /// Tools ▸ Reset Local Database…, armed via `requestOnNextLaunch`.
        case armedFlag
        /// `RC_RESET_DATABASE=1` in the process environment.
        case environmentVariable

        /// Human-readable, for the erase-site log line.
        public var loggingDescription: String {
            switch self {
            case .armedFlag: "the Tools ▸ Reset Local Database… flag"
            case .environmentVariable: "the \(DatabaseReset.environmentKey) environment variable"
            }
        }
    }

    /// Whether a reset is pending, WITHOUT clearing the flag. Lets the app
    /// decide to wait for other instances to exit before bootstrapping,
    /// which must happen before `consumeRequest` burns the flag.
    public static func isPending(
        defaults: UserDefaults,
        environment: [String: String]
    ) -> Bool {
        pendingTrigger(defaults: defaults, environment: environment) != nil
    }

    /// Which trigger is pending, if any, WITHOUT clearing anything. The armed
    /// flag wins when both are set, matching `consumeRequest`'s precedence.
    public static func pendingTrigger(
        defaults: UserDefaults,
        environment: [String: String]
    ) -> Trigger? {
        if defaults.bool(forKey: userDefaultsKey) { return .armedFlag }
        if environment[environmentKey] == "1" { return .environmentVariable }
        return nil
    }

    /// Which trigger requested a reset, clearing the persistent flag as a side
    /// effect. `nil` means no reset was requested. Cleared BEFORE the caller
    /// erases, so a crash mid-erase cannot leave the flag set and wipe the
    /// database on every subsequent launch.
    ///
    /// Returns the trigger rather than a `Bool` so the caller can name it in
    /// its own log line — the env var is the dangerous one (sticky across
    /// every launch until someone edits the scheme), and a bare `Bool` erases
    /// that distinction right where it matters most.
    public static func consumeRequest(
        defaults: UserDefaults,
        environment: [String: String]
    ) -> Trigger? {
        let flagged = defaults.bool(forKey: userDefaultsKey)
        if flagged {
            defaults.removeObject(forKey: userDefaultsKey)
            // `removeObject` hands off to cfprefsd over XPC; the on-disk flush
            // is not guaranteed synchronous with the call returning. Force it
            // now so a crash immediately after this point cannot find the
            // flag still readable on the next launch.
            defaults.synchronize()
            return .armedFlag
        }
        return environment[environmentKey] == "1" ? .environmentVariable : nil
    }

    /// Arms a reset for the next launch. The caller relaunches.
    ///
    /// Calls `synchronize()` itself rather than leaving that to the caller to
    /// remember — the write needs to be durable before the app can safely
    /// quit for the relaunch to pick it up.
    public static func requestOnNextLaunch(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: userDefaultsKey)
        defaults.synchronize()
    }

    /// Disarms a pending Tools-menu reset without consuming it as a reset —
    /// for when the relaunch that was supposed to pick it up never happens
    /// (see `ReplicantApp`'s `openApplication` failure branch). Leaving the
    /// flag armed in that case would erase the database at some later,
    /// unrelated launch — possibly a Release build, where there's no menu
    /// item or confirmation to explain why.
    public static func cancelPendingRequest(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: userDefaultsKey)
        defaults.synchronize()
    }

    /// Withdraws the environment-variable trigger for the remainder of this
    /// process's life, so a rescue-path erase the user just declined cannot
    /// still be picked up moments later by `bootstrap()` re-reading the
    /// environment itself. Only affects this process: the scheme's env var is
    /// untouched on disk, so a genuine rescue attempt still works next launch.
    public static func declineEnvironmentVariableRequest() {
        unsetenv(environmentKey)
    }
}
