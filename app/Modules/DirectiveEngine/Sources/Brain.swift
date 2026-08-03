//
//  Brain.swift
//  Replicould — DirectiveEngine
//
//  The automation brain's evaluation entry point. `DirectiveEngineCore` ticks
//  a `Brain` alongside its existing supervisor (`tickBrain()` in
//  `DirectiveEngine.swift`) — this is the real seam every later brain task
//  (goal derivation, grow/prune ranking, dispatch) tests end-to-end through
//  (`brain-executor-seam`).
//
//  Phase A (this build) is deliberately inert: `evaluateOnce()` reads a
//  `WorldView` and always answers `.idle`. Nothing here creates, mutates, or
//  cancels a row — the brain is a PURE SELECTOR (`brain-robustness-bar`
//  clause 1), and its only writes, added in later tasks, run through
//  directive creation/cancellation and `DirectiveResolutionClient.{retry,
//  cancel}`, never a bespoke write from inside this type.
//
//  Not an actor, and deliberately so: a plain, non-actor-isolated type's
//  `async` methods are nonisolated by default, so calling `evaluateOnce()`
//  from `DirectiveEngineCore.tickBrain()` (actor-isolated) hops the ranking
//  work off `DirectiveEngineCore`'s serial executor rather than running it
//  inline — the (today trivial, later real) ranking pass can never block the
//  executor-reconciliation loop ticking alongside it.
//

import Dependencies
import Foundation
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Brain")

/// One tick's worth of brain evaluation. Stateless between ticks by design
/// (`brain-robustness-bar` clause 2): every field here is an input to THIS
/// evaluation, never state carried over from the last one.
struct Brain: Sendable {
    /// The tick's clock reading, bridged in by the caller via
    /// `@Dependency(\.date)` rather than sampled here — keeps `WorldView`'s
    /// snapshot, and every test built on `TestClock`, deterministic. Never
    /// `Date()` directly.
    let now: Date

    /// Read the world, decide what — if anything — is worth doing. Phase A
    /// reads the world and always idles; later tasks replace the body below
    /// the read, never the read itself or the loop around it.
    func evaluateOnce() async -> BrainDecision {
        @Dependency(\.defaultDatabase) var database

        let view: WorldView
        do {
            view = try await database.read { db in try WorldView.read(from: db, now: now) }
        } catch {
            logger.error("world read failed: \(error)")
            return .idle(reason: "world unavailable")
        }

        return .idle(reason: view.meshSystems.isEmpty ? "no mesh yet" : "no grow or prune work")
    }
}
