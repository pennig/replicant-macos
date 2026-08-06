//
//  DirectiveTimelineRow.swift
//  Replicould — Directives feature
//
//  One entry of the step timeline, optionally folding in a repeated cycle's
//  step names + count. In its own file per the house rule — a row struct
//  beside a `#Preview` crashes the Xcode 26 preview JIT.
//

import GameModels
import SwiftUI
import UI

struct DirectiveTimelineRow: View {
    let entry: DirectiveLogEntry
    var count: Int = 1
    var cycleSteps: [String] = []

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: DirectiveLogPresentation.symbol(for: entry.kind))
                .font(.system(size: IconSize.s))
                .foregroundStyle(glyphTint)
                .frame(width: IconSize.m, alignment: .center)
            Text(displaySummary)
                .font(.rcCaption)
                .foregroundStyle(isProminent ? .rcTextPrimary : .rcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if count > 1 {
                Text("×\(count)")
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                    .rcPill(.neutral)
            }
            Spacer(minLength: Space.s)
            // Ticks on its own — no timer to run, no formatter to test.
            Text(entry.occurredAt, style: .relative)
                .font(.rcMicroMono)
                .foregroundStyle(.rcTextTertiary)
        }
        .padding(.vertical, Space.xxs)
    }

    /// A collapsed multi-step cycle names its steps in order; anything else
    /// keeps the entry's own line.
    private var displaySummary: String {
        cycleSteps.count > 1 ? cycleSteps.joined(separator: " → ") : entry.summary
    }

    private var isProminent: Bool { DirectiveLogPresentation.isProminent(entry.kind) }

    private var glyphTint: Color {
        switch entry.kind {
        case .stalled: .rcWarning
        case .directiveCompleted: .rcAccent
        default: .rcTextTertiary
        }
    }
}
