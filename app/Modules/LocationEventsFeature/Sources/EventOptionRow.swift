//
//  EventOptionRow.swift
//  LocationEventsFeature
//
//  One selectable fulfilment option: its bills, its load, and whether it is the pick.
//

import GameModels
import SwiftUI
import UI

/// The chosen row is marked three ways — a filled glyph, the word "Chosen", and
/// a raised fill — so hue is never what tells it apart.
struct EventOptionRow: View {
    let option: LocationEventDetail.Option
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: Space.xs) {
                heading
                ForEach(option.devices) { device in
                    billLine(Self.label(device.deviceType), "× \(device.required.formatted())")
                }
                ForEach(option.resources) { resource in
                    billLine(Self.label(resource.resourceType), resource.required.formatted())
                }
                if option.devices.isEmpty && option.resources.isEmpty {
                    Text("No delivery required.")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(background))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control)
                    .stroke(border, lineWidth: Hairline.regular)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }

    private var heading: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                .font(.system(size: IconSize.m))
                .foregroundStyle(isChosen ? .rcAccent : .rcTextTertiary)
            Text(Self.label(option.name))
                .font(.rcBodyEmph)
                .foregroundStyle(.rcTextPrimary)
            if isChosen {
                Text("Chosen").font(.rcMicro).foregroundStyle(.rcAccent).rcPill(.accent)
            }
            Spacer()
            if option.exceedsOneFreighterLoad {
                Label("2+ loads", systemImage: "shippingbox")
                    .font(.rcMicro)
                    .foregroundStyle(.rcTextSecondary)
                    .rcPill(.neutral)
            }
        }
    }

    private func billLine(_ label: String, _ amount: String) -> some View {
        HStack {
            Text(label).font(.rcBody).foregroundStyle(.rcTextSecondary)
            Spacer()
            Text(amount).font(.rcMonoSmall).foregroundStyle(.rcTextPrimary)
        }
    }

    private var background: Color { isChosen ? .rcAccentMuted : .rcSurfaceRaisedStrong }
    private var border: Color { isChosen ? .rcAccentBorder : .rcSeparator }

    private static func label(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
