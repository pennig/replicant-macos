//
//  BlueprintComponentsSection.swift
//  Replicould — BlueprintsFeature
//
//  The printed devices a blueprint consumes, beyond its raw resource cost.
//

import GameModels
import SwiftUI
import UI

struct BlueprintComponentsSection: View {
    let components: [String: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCSectionHeader("Components")
            ForEach(components.sorted(by: { $0.key < $1.key }), id: \.key) { type, count in
                HStack(spacing: Space.m) {
                    Text(BlueprintPresentation.displayName(type))
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextSecondary)
                    Spacer(minLength: 0)
                    Text("×\(count)")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
