//
//  DeviceRow.swift
//  Replicould — Devices feature
//
//  One row of the fleet master list. Renders a `DeviceEntry` and nothing else:
//  containment is already resolved into `depth` / `childCount` / `host` by
//  `DeviceListLayout`, so this view never walks the fleet.
//
//  No `#Preview` in this file — the Xcode 26 preview JIT crashes when a list-row
//  struct sits beside one (.claude/memory/list-row-preview-crash.md).
//

import GameModels
import SwiftUI
import UI

struct DeviceRow: View {
    let entry: DeviceEntry
    let onDisclosureToggle: () -> Void

    private var device: Device { entry.device }

    /// Reserved so a leaf's glyph lines up with a host's, one indent per depth.
    private static let disclosureWidth: CGFloat = 22

    var body: some View {
        HStack(spacing: Space.s) {
            disclosure
            VStack(spacing: Space.xs) {
                RCGlyphTile(Image.rcSymbol("device.\(device.deviceType)"))
                RCMeterBar(fraction: device.operationalCapacity / 100)
                    .frame(width: 30)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                titleLine
                metaLine
            }
        }
        .padding(.vertical, Space.xs)
        .padding(.leading, CGFloat(entry.depth) * Space.l)
    }

    @ViewBuilder
    private var disclosure: some View {
        if entry.childCount > 0 {
            Button(action: onDisclosureToggle) {
                VStack(spacing: Space.xxs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: IconSize.s))
                        .rotationEffect(.degrees(entry.isExpanded ? 90 : 0))
                    Text("\(entry.childCount)")
                        .font(.rcMicroMono)
                }
                .foregroundStyle(.rcTextTertiary)
                .frame(width: Self.disclosureWidth)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.isExpanded ? "Collapse" : "Expand")
        } else {
            Color.clear.frame(width: Self.disclosureWidth, height: 1)
        }
    }

    private var titleLine: some View {
        HStack(spacing: Space.s) {
            if !entry.attention.isEmpty {
                Circle()
                    .fill(.rcDanger)
                    .frame(width: 6, height: 6)
                    .help(entry.attention.map(\.label).joined(separator: " · "))
            }
            Text(DevicePresentation.displayName(device.deviceType))
                .font(.rcBodyEmph)
                .foregroundStyle(.rcTextPrimary)
                .lineLimit(1)
            Text(device.deviceCode)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextTertiary)
            Spacer(minLength: Space.xs)
        }
    }

    private var metaLine: some View {
        HStack(spacing: Space.s) {
            StatusBadge(device.statusBase)
            if let location = device.location {
                Text(location)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                    .lineLimit(1)
            } else if let destination = travelDestination {
                Label(destination, systemImage: "location.north.line")
                    .labelStyle(.titleAndIcon)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                    .lineLimit(1)
            }
            if let host = entry.host {
                Label(host.hostCode, systemImage: host.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
                    .lineLimit(1)
                    .help(host.label)
            }
            ForEach(device.tags, id: \.self) { tag in
                Text(tag)
                    .font(.rcMicro)
                    .foregroundStyle(.rcTextSecondary)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, Space.xxs)
                    .background(Capsule().fill(.rcSurfaceRaised))
            }
            Spacer(minLength: Space.xs)
        }
    }

    /// The trip's destination code while the device is en route — surfaced only
    /// when there's no settled `location` to show instead. Prefers the whole
    /// route's `final_destination` over the active leg's `destination`.
    private var travelDestination: String? {
        guard device.derivedActivity?.kind == .travel else { return nil }
        return device.detail["travel"]?["final_destination"]?.stringValue
            ?? device.detail["travel"]?["destination"]?.stringValue
    }
}
