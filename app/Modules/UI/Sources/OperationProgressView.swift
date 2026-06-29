//
//  OperationProgressView.swift
//  Replicould — UI
//
//  A live progress bar + ETA for a running operation, interpolated entirely on
//  device from `startedAt`/`completesAt` via `TimelineView` — zero network reads
//  between dispatch and completion (IMPLEMENTATION_PLAN §5.4 / Phase 4). The
//  deadline scheduler takes the single confirm-read when the bar reaches the end;
//  the animation itself costs nothing.
//

import SwiftUI

public struct OperationProgressView: View {
    private let startedAt: Date
    private let completesAt: Date
    private let tint: Color

    public init(startedAt: Date, completesAt: Date, tint: Color = .rcAccent) {
        self.startedAt = startedAt
        self.completesAt = completesAt
        self.tint = tint
    }

    /// Once the bar reaches the finish line it stays there. The backstop poller
    /// can push `completesAt` out a few seconds to re-confirm a slipped ETA;
    /// without this the bar would visibly step backward from "Arriving…" to a
    /// fresh countdown. Reset per operation by `.id(operation.id)` at the call
    /// site. (Pre-arrival `completesAt` doesn't move, so this never masks real
    /// remaining time.)
    @State private var reachedEnd = false

    public var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let pending = reachedEnd || context.date >= completesAt
            VStack(alignment: .leading, spacing: Space.xs) {
                ProgressView(value: pending ? 1 : Self.fraction(now: context.date, start: startedAt, end: completesAt))
                    .tint(tint)
                Text(pending ? "Arriving…" : Self.etaText(now: context.date, end: completesAt))
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextSecondary)
            }
            .onChange(of: pending, initial: true) { _, isPending in
                if isPending { reachedEnd = true }
            }
        }
    }

    /// Elapsed fraction in `0...1`, clamped (pure — the testable core).
    static func fraction(now: Date, start: Date, end: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    /// Compact ETA string, e.g. "ETA 1m 23s", or "Arriving…" once due.
    static func etaText(now: Date, end: Date) -> String {
        let remaining = Int(end.timeIntervalSince(now).rounded())
        guard remaining > 0 else { return "Arriving…" }
        let minutes = remaining / 60
        let seconds = remaining % 60
        return minutes > 0 ? "ETA \(minutes)m \(seconds)s" : "ETA \(seconds)s"
    }
}
