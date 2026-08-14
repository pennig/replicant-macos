//
//  BrainWhyEventChoiceRowView.swift
//  Replicould — Directives feature
//
//  One pending decision inside the brain's why-view. Split from
//  `BrainWhyEventChoice` per the list-row-preview-crash rule, and informational:
//  the pick is made under Location Events, which this pane cannot reach.
//

import SwiftUI
import UI

struct BrainWhyEventChoiceRowView: View {
    let choice: BrainWhyEventChoice

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            heading
            ForEach(choice.options) { option in
                optionLine(option)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(choice.designation).font(.rcBodyEmphMono).foregroundStyle(.rcTextPrimary)
            Text(choice.location).font(.rcMonoSmall).foregroundStyle(.rcTextSecondary)
            Text("tier \(choice.tier)").font(.rcCaption).foregroundStyle(.rcTextTertiary)
            Spacer(minLength: 0)
        }
    }

    private func optionLine(_ option: BrainWhyEventChoice.Option) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: option.holdsEveryDevice ? "checkmark.circle" : "shippingbox")
                .font(.system(size: IconSize.s))
                .foregroundStyle(.rcTextTertiary)
                .frame(minWidth: Space.m, alignment: .trailing)
            Text(option.name).font(.rcCaption).foregroundStyle(.rcTextSecondary)
            Text("\(option.fact) · \(option.stock)")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
            if option.exceedsOneFreighterLoad {
                Text("2+ loads").font(.rcMicro).foregroundStyle(.rcTextSecondary).rcPill(.neutral)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var accessibilityLabel: String {
        let options = choice.options
            .map { "\($0.name), \($0.fact), \($0.stock)" }
            .joined(separator: "; ")
        return "\(choice.designation) at \(choice.location), tier \(choice.tier). \(options)"
    }
}
