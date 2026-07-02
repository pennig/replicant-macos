//
//  TravelProgressView.swift
//  Replicould — UI
//
//  A segmented live progress bar for a multi-leg travel operation. Each leg is a
//  segment whose width is proportional to its duration, and a single fill sweeps
//  across the whole route as time elapses — so completed legs read full, the
//  active leg partial, and upcoming legs empty. Like `OperationProgressView`, the
//  fill is interpolated entirely on-device from `barStart`/`completesAt` via
//  `TimelineView` (zero network between dispatch and completion), and it latches
//  at the finish line so a slipped ETA never steps the bar backward.
//
//  `barStart` is the instant the *shown* route began: for a route captured at
//  departure that's the departure time; for one adopted mid-flight (only the
//  remaining legs are known) it's `completesAt` minus the remaining legs' total,
//  so the sweep still tracks honestly across the legs we can show.
//

import SwiftUI

public struct TravelProgressView: View {
    private let segments: [TravelBar.Segment]
    private let barStart: Date
    private let completesAt: Date
    private let tint: Color

    public init(segments: [TravelBar.Segment], barStart: Date, completesAt: Date, tint: Color = .rcAccent) {
        self.segments = segments
        self.barStart = barStart
        self.completesAt = completesAt
        self.tint = tint
    }

    /// Latches once the sweep reaches the end (see `OperationProgressView`), so a
    /// re-armed deadline doesn't visibly rewind the bar. Reset per operation by
    /// `.id(operation.id)` at the call site.
    @State private var reachedEnd = false

    private var bands: [TravelBar.Band] { TravelBar.bands(for: segments) }

    public var body: some View {
        TimelineView(.periodic(from: barStart, by: 1)) { context in
            let pending = reachedEnd || context.date >= completesAt
            let progress = pending ? 1 : ProgressMath.fraction(now: context.date, start: barStart, end: completesAt)
            VStack(alignment: .leading, spacing: Space.xs) {
                track(progress: progress)
                    .frame(height: 6)
                HStack(spacing: Space.s) {
                    if let caption = TravelBar.activeCaption(bands, progress: progress) {
                        Text(caption)
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(pending ? "Arriving…" : ProgressMath.etaText(now: context.date, end: completesAt))
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextSecondary)
                }
            }
            .onChange(of: pending, initial: true) { _, isPending in
                if isPending { reachedEnd = true }
            }
        }
    }

    private func track(progress: Double) -> some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let usable = max(geo.size.width - CGFloat(max(segments.count - 1, 0)) * spacing, 0)
            HStack(spacing: spacing) {
                ForEach(bands) { band in
                    let width = usable * CGFloat(band.end - band.start)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.rcSeparator)
                        Capsule().fill(tint).frame(width: width * CGFloat(band.fill(at: progress)))
                    }
                    .frame(width: width)
                }
            }
        }
    }

}
