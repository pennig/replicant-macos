//
//  DirectiveTimelineRow.swift
//  Replicould — Directives feature
//
//  One entry of the step timeline. In its own file per the house rule — a row
//  struct beside a `#Preview` crashes the Xcode 26 preview JIT.
//

import GameModels
import SwiftUI
import UI

struct DirectiveTimelineRow: View {
    let entry: DirectiveLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: DirectiveLogPresentation.symbol(for: entry.kind))
                .font(.system(size: IconSize.s))
                .foregroundStyle(glyphTint)
                .frame(width: IconSize.m, alignment: .center)
            Text(entry.summary)
                .font(.rcCaption)
                .foregroundStyle(isProminent ? .rcTextPrimary : .rcTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            // Ticks on its own — no timer to run, no formatter to test.
            Text(entry.occurredAt, style: .relative)
                .font(.rcMicroMono)
                .foregroundStyle(.rcTextTertiary)
        }
        .padding(.vertical, Space.xxs)
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
