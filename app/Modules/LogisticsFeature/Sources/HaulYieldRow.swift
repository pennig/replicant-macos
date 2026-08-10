//
//  HaulYieldRow.swift
//  Replicould — Logistics feature
//

import GameModels
import SwiftUI
import UI

struct HaulYieldRow: View {
    let yield: HaulYield

    var body: some View {
        HStack(spacing: Space.m) {
            Text(yield.collectedAt, format: .dateTime.month().day().hour().minute())
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
            Text(yield.sourceDesignation).font(.rcBodyEmphMono)
            Spacer()
            ForEach(ResourceCost.displayOrder, id: \.key) { slot in
                let amount = yield.perType.amount(forKey: slot.key)
                if amount > 0 {
                    HStack(spacing: Space.xs) {
                        Circle().fill(Color.rcResource(slot.key)).frame(width: 8, height: 8)
                        Text("\(amount)").font(.rcMonoSmall)
                    }
                }
            }
            Text("\(yield.unitsCollected)").font(.rcBodyEmph).monospacedDigit()
            if yield.breakdownState != .exact {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.rcTextTertiary)
                    .help(yield.breakdownState == .partial ? "Breakdown reconstructed" : "Breakdown unavailable")
            }
        }
        .padding(.vertical, Space.xs)
    }
}
