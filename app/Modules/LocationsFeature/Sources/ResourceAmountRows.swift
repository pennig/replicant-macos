//
//  ResourceAmountRows.swift
//  LocationsFeature
//
//  The per-resource readout for a site. In its own file because a row struct
//  beside a `#Preview` crashes the Xcode 26 preview JIT (see the
//  list-row-preview-crash memory note).
//

import SwiftUI
import UI
import UniverseModels

/// One site, with its resources broken out. The header carries the site's name
/// and designation; each line reports one resource's remaining amount.
struct SiteAmountsRow: View {
    let title: String
    let code: String
    let amounts: [ResourceAmount]
    /// Rendered before the summary, e.g. "Depleted".
    let status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.rcMono).foregroundStyle(.rcTextPrimary)
                    Text(code).font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
                }
                Spacer()
                if let summary {
                    Text(summary).font(.rcCaption).foregroundStyle(.rcTextSecondary)
                }
            }
            ForEach(amounts) { amount in
                ResourceAmountLine(amount: amount)
            }
        }
    }

    /// The collapsed figure: total units still present, summed across resources.
    /// Unassayed resources are omitted, so it is a floor — the `~` says so.
    /// Falls back to the resource names when nothing is assayed at all, which is
    /// what the row showed before assays existed.
    private var summary: String? {
        var parts: [String] = []
        if let status, !status.isEmpty { parts.append(status) }
        if let units = SiteAmounts.totalRemaining(amounts) {
            parts.append("~\(units.formatted(.number.precision(.fractionLength(0)))) units")
        } else if !amounts.isEmpty {
            parts.append(amounts.map(\.resource).joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One resource line: `conductive   132 / 331   40%`.
struct ResourceAmountLine: View {
    let amount: ResourceAmount

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(amount.resource.capitalized)
                .font(.rcCaption).foregroundStyle(.rcTextSecondary)
            Spacer()
            if let remaining = amount.remaining, let total = amount.total {
                Text("\(format(remaining)) / \(format(total))")
                    .font(.rcMonoSmall).foregroundStyle(.rcTextPrimary)
            }
            Text("\(format(amount.percentRemaining))%")
                .font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}
