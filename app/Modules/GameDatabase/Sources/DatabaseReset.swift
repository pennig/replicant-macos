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

    /// Whether a reset was requested, clearing the persistent flag as a side
    /// effect. Cleared BEFORE the caller erases, so a crash mid-erase cannot
    /// leave the flag set and wipe the database on every subsequent launch.
    public static func consumeRequest(
        defaults: UserDefaults,
        environment: [String: String]
    ) -> Bool {
        let flagged = defaults.bool(forKey: userDefaultsKey)
        if flagged {
            defaults.removeObject(forKey: userDefaultsKey)
            // `removeObject` hands off to cfprefsd over XPC; the on-disk flush
            // is not guaranteed synchronous with the call returning. Force it
            // now so a crash immediately after this point cannot find the
            // flag still readable on the next launch.
            defaults.synchronize()
        }
        return flagged || environment[environmentKey] == "1"
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
}
