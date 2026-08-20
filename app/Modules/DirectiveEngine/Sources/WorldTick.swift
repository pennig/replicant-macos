//
//  WorldTick.swift
//  Replicould — DirectiveEngine
//
//  One read per TICK, not one per directive: every running directive's world,
//  fetched in a single transaction and handed to every executor. See
//  `WorldCore.swift` and `DirectiveSlice.swift` for the two halves this
//  composes, and `WorldSnapshot.swift` for the per-directive shape it hands
//  back out.
//

import Foundation
import GameModels
import SQLiteData
import UniverseModels

/// The whole tick's world, read once: the shared `core`, every running
/// directive's own `slice`, and the roster itself. `snapshot(for:)` composes
/// the public `WorldSnapshot` a step machine actually evaluates against.
public struct WorldTick: Sendable {
    public let generation: UInt64
    public let core: WorldCore
    public let slices: [String: DirectiveSlice]
    public let running: [Directive]
    /// The brain's galaxy-wide read, built from `core` in the same
    /// transaction — see `WorldView.read(from:core:now:)`.
    public let view: WorldView
    public let now: Date

    public init(
        generation: UInt64, core: WorldCore, slices: [String: DirectiveSlice],
        running: [Directive], view: WorldView, now: Date
    ) {
        self.generation = generation
        self.core = core
        self.slices = slices
        self.running = running
        self.view = view
        self.now = now
    }

    /// One `database.read` for the whole tick: the running roster, then
    /// `WorldCore`, then every running directive's `DirectiveSlice` in one
    /// batched pass. Nothing else may open a transaction.
    public static func read(
        from database: any DatabaseReader, now: Date, generation: UInt64
    ) async throws -> WorldTick {
        try await database.read { db in
            let running = try Directive.where { $0.status.eq(DirectiveStatus.running) }.fetchAll(db)
            let core = try WorldCore.read(from: db)
            let slices = try DirectiveSlice.readAll(from: db, core: core, directives: running)
            let view = try WorldView.read(from: db, core: core, now: now)
            return WorldTick(
                generation: generation, core: core, slices: slices, running: running, view: view, now: now
            )
        }
    }

    /// The composed `WorldSnapshot` for `directiveID`, or nil when it has no
    /// slice — not among this tick's running directives.
    public func snapshot(for directiveID: String) -> WorldSnapshot? {
        guard let slice = slices[directiveID] else { return nil }
        return WorldSnapshot(core: core, slice: slice, now: now)
    }
}
