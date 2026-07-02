//
//  MiningCycleView.swift
//  Replicould — UI
//
//  A repeating progress bar for a mining drone's cycle. Mining has no completion
//  deadline — the drone works the belt in fixed `cycle` intervals — so unlike
//  `OperationProgressView` this bar wraps: it fills over each cycle then resets,
//  interpolated on device via `TimelineView` (the inspector re-reads the drone at
//  each boundary to refresh the yield tally, but the animation itself is free).
//

import SwiftUI

public struct MiningCycleView: View {
    private let startedAt: Date
    private let cycleSeconds: Double
    private let tint: Color

    public init(startedAt: Date, cycleSeconds: Double, tint: Color = StatusTone.working.color) {
        self.startedAt = startedAt
        self.cycleSeconds = cycleSeconds
        self.tint = tint
    }

    public var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            VStack(alignment: .leading, spacing: Space.xs) {
                ProgressView(value: ProgressMath.cycleFraction(now: context.date, start: startedAt, cycle: cycleSeconds))
                    .tint(tint)
                Text(ProgressMath.cycleText(now: context.date, start: startedAt, cycle: cycleSeconds))
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextSecondary)
            }
        }
    }
}
