//
//  YieldKPIRow.swift
//  Replicould — Logistics feature
//

import GameModels
import SwiftUI
import UI

struct YieldKPIRow: View {
    let summary: YieldSummary

    private var topResource: (key: String, units: Int)? {
        summary.byResource.filter { $0.units > 0 }.max { $0.units < $1.units }
    }

    var body: some View {
        HStack(spacing: Space.m) {
            RCReadoutCard("Units Hauled") {
                Text("\(summary.totalUnits)").font(.rcDisplay).monospacedDigit()
            }
            RCReadoutCard("Trips") {
                Text("\(summary.tripCount)").font(.rcDisplay).monospacedDigit()
            }
            RCReadoutCard("Units / Day") {
                Text(summary.unitsPerDay, format: .number.precision(.fractionLength(0)))
                    .font(.rcDisplay).monospacedDigit()
            }
            RCReadoutCard("Most Hauled") {
                if let topResource {
                    HStack(spacing: Space.xs) {
                        // The mark carries identity; the text stays ink.
                        Circle()
                            .fill(Color.rcResource(topResource.key))
                            .frame(width: MarkerSize.resourceSwatch, height: MarkerSize.resourceSwatch)
                        Text(topResource.key.capitalized).font(.rcHeadline)
                    }
                } else {
                    Text("—").font(.rcHeadline).foregroundStyle(.rcTextTertiary)
                }
            }
        }
    }
}
