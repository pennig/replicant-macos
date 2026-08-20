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
    /// How much of the readout to draw. `.compact` is the bar alone, at list-row
    /// scale; `.standard` stacks the ETA caption beneath it.
    public enum Style: Sendable {
        case standard
        case compact
    }

    private let startedAt: Date
    private let completesAt: Date
    private let tint: Color
    private let style: Style

    public init(startedAt: Date, completesAt: Date, tint: Color = .rcAccent, style: Style = .standard) {
        self.startedAt = startedAt
        self.completesAt = completesAt
        self.tint = tint
        self.style = style
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
            let bar = ProgressView(value: pending ? 1 : ProgressMath.fraction(now: context.date, start: startedAt, end: completesAt))
                .tint(tint)
            Group {
                switch style {
                case .standard:
                    VStack(alignment: .leading, spacing: Space.xs) {
                        bar
                        Text(pending ? "Arriving…" : ProgressMath.etaText(now: context.date, end: completesAt))
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextSecondary)
                    }
                case .compact:
                    bar.controlSize(.small)
                }
            }
            .onChange(of: pending, initial: true) { _, isPending in
                if isPending { reachedEnd = true }
            }
        }
    }
}
