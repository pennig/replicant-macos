//
//  CapacityRing.swift
//  Replicould — Devices feature
//
//  The small ring gauge in the device inspector header: a device's operational
//  capacity (0–100) as a trimmed circular stroke, colored by a simple
//  three-tier tone (healthy / degraded / critical).
//

import SwiftUI
import UI

struct CapacityRing: View {
    let value: Double   // 0...100

    private var tone: Color {
        switch value {
        case 66...:  return .rcStatusReady
        case 33..<66: return .rcWarning
        default:     return .rcError
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.rcSeparator, lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(0, min(1, value / 100)))
                .stroke(tone, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value))")
                .font(.rcHeadline)
                .foregroundStyle(.rcTextPrimary)
                .monospacedDigit()
        }
        .frame(width: 60, height: 60)
    }
}
