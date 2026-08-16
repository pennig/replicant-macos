//
//  CommandOwner.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The directive step responsible for a dispatched command, threaded onto the
//  written `Operation` row so a later reader can attribute it without
//  reconstructing ownership from a log join.
//

import Foundation

public struct CommandOwner: Sendable, Equatable {
    public let directiveID: String
    public let step: String
    /// The dispatching directive's `stepStartedAt` — where a de-dup window starts.
    public let since: Date

    public init(directiveID: String, step: String, since: Date) {
        self.directiveID = directiveID
        self.step = step
        self.since = since
    }
}
