//
//  ReplicantSplitView.swift
//  A NavigationSplitView scaffold for the Replicant macOS app, wired entirely
//  to the design tokens (ReplicantDesignSystem.swift + ReplicantColors.xcassets).
//
//  This is a working skeleton with placeholder data — replace the sample
//  models in `Sample` with your API models. Structure mirrors DESIGN_SPEC.md.
//

import SwiftUI

// MARK: - Models

struct ReplicantInfo: Identifiable {
    let id: String              // replicant code
    var name: String
    var host: HostKind
    var hostName: String
    var statusRaw: String       // "travelling" | "idle"
    var travelTo: String?
    var travelRemaining: String?
    var travelProgress: Double?
    var location: String
    var xp: Int
    var deviceCount: Int
    var isNPC: Bool
    var plan: String
}

struct DeviceInfo: Identifiable {
    let id: String              // device_code
    var type: String            // device_type
    var typeName: String
    var location: String
    var statusRaw: String
    var statusParam: String?
    var capacity: Int
    var integrity: Int
    var signal: Int
    var features: [String]
    var commands: [String]
    var taskLabel: String?
    var taskProgress: Double?
    var deployedFor: String
}

struct AccountInfo { var name: String; var email: String; var xp: Int; var replicants: Int }

// MARK: - Navigation

enum NavKey: String, Identifiable, Hashable { case stars, devices, replicants, blueprints, printQueue, signals, messages, bobnet, eventLog; var id: String { rawValue } }

struct NavEntry: Identifiable {
    var id: NavKey { key }
    let key: NavKey
    let title: String
    let symbol: String
    var count: Int? = nil
    var badge: Int? = nil
    var live = false
    var soon = false
}

private let navGroups: [(String, [NavEntry])] = [
    ("Catalog", [
        .init(key: .stars, title: "Stars", symbol: SidebarSymbol.stars, count: 48),
        .init(key: .devices, title: "Devices", symbol: SidebarSymbol.devices, count: 10),
        .init(key: .replicants, title: "Replicants", symbol: SidebarSymbol.replicants, count: 5),
        .init(key: .blueprints, title: "Blueprints", symbol: SidebarSymbol.blueprints, count: 23),
    ]),
    ("Operations", [
        .init(key: .printQueue, title: "Print Queue", symbol: SidebarSymbol.printQueue, count: 3),
        .init(key: .signals, title: "Signals", symbol: SidebarSymbol.signals, soon: true),
    ]),
    ("Comms", [
        .init(key: .messages, title: "Messages", symbol: SidebarSymbol.messages, badge: 3),
        .init(key: .bobnet, title: "Bobnet", symbol: SidebarSymbol.bobnet, live: true),
        .init(key: .eventLog, title: "Event Log", symbol: SidebarSymbol.eventLog),
    ]),
]

func deviceSymbol(_ type: String) -> String {
    switch type {
    case "mining_drone": return "hexagon"
    case "survey_probe": return "circle.dotted"
    case "ftl_relay":    return "dot.radiowaves.left.and.right"
    case "forge":        return "square.grid.2x2"
    case "hauler":       return "shippingbox"
    case "scanner":      return "wave.3.right"
    case "repair_drone": return "wrench.adjustable"
    case "surge_plate":  return "diamond"
    default:             return "circle.hexagongrid"
    }
}

// MARK: - Root

struct ReplicantSplitView: View {
    @State private var nav: NavKey? = .devices
    @State private var selectedDevice: DeviceInfo.ID? = Sample.devices.first?.id
    @State private var replicants = Sample.replicants
    @State private var activeIndex = 0

    var body: some View {
        NavigationSplitView {
            SidebarView(nav: $nav, replicants: $replicants, activeIndex: $activeIndex)
                .navigationSplitViewColumnWidth(min: 260, ideal: 268, max: 300)
        } content: {
            Group {
                if nav == .devices {
                    DeviceListView(selection: $selectedDevice)
                } else {
                    PlaceholderPane(title: navTitle(nav))
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 352, max: 440)
        } detail: {
            if nav == .devices, let id = selectedDevice, let d = Sample.devices.first(where: { $0.id == id }) {
                InspectorView(device: d)
            } else {
                PlaceholderPane(title: "Select an item")
            }
        }
    }

    private func navTitle(_ k: NavKey?) -> String {
        navGroups.flatMap(\.1).first { $0.key == k }?.title ?? "Replicant"
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var nav: NavKey?
    @Binding var replicants: [ReplicantInfo]
    @Binding var activeIndex: Int
    @State private var showSwitcher = false

    private var active: ReplicantInfo { replicants[activeIndex] }

    var body: some View {
        VStack(spacing: 0) {
            replicantHeader
            Divider().overlay(Color.rcSeparatorSoft)
            ScrollView { navList.padding(.horizontal, Space.l).padding(.bottom, Space.s) }
            AccountChip(account: Sample.account)
        }
        .background(Color.rcSidebarBackground)
    }

    // — replicant picker + status + plan —
    private var replicantHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Active Replicant")
                .font(.system(size: 9.5, weight: .bold)).kerning(1).textCase(.uppercase)
                .foregroundStyle(Color.rcTextTertiary)

            Button { showSwitcher.toggle() } label: {
                HStack(spacing: 11) {
                    Image(systemName: active.host.sfSymbol)
                        .font(.system(size: 16)).foregroundStyle(Color.rcAccent)
                        .frame(width: 34, height: 34)
                        .background(Color.rcAccentMuted, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.rcAccentBorder, lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active.name).font(.system(size: 15.5, weight: .bold)).foregroundStyle(Color.rcTextPrimary)
                        HStack(spacing: 5) {
                            Text(active.host.label).font(.rcCaption).foregroundStyle(Color.rcTextSecondary)
                            if active.isNPC {
                                Text("·").foregroundStyle(Color.rcTextTertiary)
                                Image(systemName: SidebarSymbol.npc).font(.system(size: 10)).foregroundStyle(Color.rcNPC)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.rcTextSecondary)
                }
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(Color.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.rcSeparator, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSwitcher, arrowEdge: .bottom) {
                SwitcherList(replicants: replicants, activeIndex: $activeIndex, dismiss: { showSwitcher = false })
            }

            TravelStatusView(replicant: active)

            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Text(active.xp.formatted()).font(.rcMonoSmall).foregroundStyle(Color.rcTextPrimary)
                    Text(" XP · ").font(.rcMonoSmall).foregroundStyle(Color.rcTextTertiary)
                    Text("\(active.deviceCount)").font(.rcMonoSmall).foregroundStyle(Color.rcTextPrimary)
                    Text(" dev").font(.rcMonoSmall).foregroundStyle(Color.rcTextTertiary)
                }
                Spacer(minLength: 0)
                Button { } label: {
                    HStack(spacing: 3) { Text("Show in Replicants"); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.rcAccent)
                }.buttonStyle(.plain)
            }

            TextField("Plan", text: $replicants[activeIndex].plan, axis: .vertical)
                .textFieldStyle(.plain).font(.rcBody).foregroundStyle(Color.rcTextSecondary)
                .lineLimit(2, reservesSpace: false)
        }
        .padding(.horizontal, Space.l).padding(.top, 10).padding(.bottom, Space.m)
    }

    private var navList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(navGroups, id: \.0) { title, items in
                Text(title).font(.system(size: 10, weight: .bold)).kerning(1).textCase(.uppercase)
                    .foregroundStyle(Color.rcTextTertiary).padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
                ForEach(items) { item in
                    NavRowView(entry: item, selected: nav == item.key) { if !item.soon { nav = item.key } }
                }
            }
        }
    }
}

struct TravelStatusView: View {
    let replicant: ReplicantInfo
    var body: some View {
        let tone = DeviceStatus.tone(for: replicant.statusRaw)
        VStack(alignment: .leading, spacing: 6) {
            if replicant.statusRaw == "travelling", let to = replicant.travelTo, let rem = replicant.travelRemaining, let p = replicant.travelProgress {
                HStack(spacing: 7) {
                    Circle().fill(tone.color).frame(width: 6, height: 6).shadow(color: tone.color.opacity(0.6), radius: 3)
                    Text("Cruise → \(to)").font(.rcCaption).foregroundStyle(Color.rcTextPrimary)
                    Spacer(minLength: 0)
                    Text(rem).font(.rcMonoSmall).foregroundStyle(Color.rcTextTertiary)
                }
                ProgressView(value: p).tint(tone.color)
            } else {
                HStack(spacing: 7) {
                    Circle().fill(tone.color).frame(width: 6, height: 6)
                    Text("Idle").font(.rcCaption).foregroundStyle(Color.rcTextSecondary)
                    Spacer(minLength: 0)
                    Text(replicant.location).font(.rcMonoSmall).foregroundStyle(Color.rcTextTertiary)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(Color.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.rcSeparator, lineWidth: 0.5))
    }
}

struct SwitcherList: View {
    let replicants: [ReplicantInfo]
    @Binding var activeIndex: Int
    let dismiss: () -> Void
    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(replicants.enumerated()), id: \.element.id) { idx, r in
                Button { activeIndex = idx; dismiss() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: r.host.sfSymbol).font(.system(size: 15))
                            .foregroundStyle(idx == activeIndex ? Color.rcAccent : .rcTextSecondary)
                            .frame(width: 30, height: 30)
                            .background(Color.rcSurfaceRaisedStrong, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(r.name).font(.rcBodyEmph).foregroundStyle(Color.rcTextPrimary)
                                if r.isNPC { Image(systemName: SidebarSymbol.npc).font(.system(size: 9)).foregroundStyle(Color.rcNPC) }
                            }
                            Text("\(r.host.label) · \(r.hostName)").font(.system(size: 10.5)).foregroundStyle(Color.rcTextTertiary)
                        }
                        Spacer(minLength: 20)
                        Text(r.statusRaw == "travelling" ? "Transit" : "Idle")
                            .font(.system(size: 10.5)).foregroundStyle(Color.rcTextSecondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(idx == activeIndex ? AnyShapeStyle(Color.rcAccentMuted) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            Divider().overlay(Color.rcSeparatorSoft).padding(.vertical, 4)
            Button { } label: {
                HStack(spacing: 7) { Image(systemName: "plus"); Text("Commission new replicant") }
                    .font(.rcBody).foregroundStyle(Color.rcTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
            }.buttonStyle(.plain)
        }
        .padding(6).frame(width: 280).background(Color.rcSurfaceRaised)
    }
}

struct NavRowView: View {
    let entry: NavEntry
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: entry.symbol).font(.system(size: 13))
                    .foregroundStyle(selected ? Color.rcAccent : .rcTextSecondary).frame(width: 18)
                Text(entry.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.rcTextPrimary : Color.rcTextSecondary)
                Spacer(minLength: 0)
                badge
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(selected ? AnyShapeStyle(Color.rcAccentMuted) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(Color.rcAccent).frame(width: 3, height: 18).offset(x: -8) }
            }
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var badge: some View {
        if entry.soon {
            Text("soon").font(.system(size: 9, weight: .bold)).kerning(0.4).textCase(.uppercase).foregroundStyle(Color.rcTextTertiary)
        } else if entry.live {
            HStack(spacing: 5) {
                Circle().fill(Color.rcStatusReady).frame(width: 6, height: 6).shadow(color: .rcStatusReady.opacity(0.7), radius: 3)
                Text("live").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.rcStatusReady)
            }
        } else if let b = entry.badge {
            Text("\(b)").font(.rcMonoSmall).foregroundStyle(Color.rcAccentOnColor)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Color.rcAccent, in: Capsule())
        } else if let c = entry.count {
            Text("\(c)").font(.rcMonoSmall).foregroundStyle(selected ? Color.rcAccent : .rcTextTertiary)
        }
    }
}

struct AccountChip: View {
    let account: AccountInfo
    var body: some View {
        Button { } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: SidebarSymbol.account).font(.system(size: 11)).foregroundStyle(Color.rcTextTertiary)
                    Text("Logged in").font(.system(size: 9, weight: .bold)).kerning(1).textCase(.uppercase).foregroundStyle(Color.rcTextTertiary)
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name).font(.rcBodyEmph).foregroundStyle(Color.rcTextPrimary)
                        Text(account.email).font(.system(size: 10.5)).foregroundStyle(Color.rcTextTertiary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 3) {
                            Text("\(Double(account.xp) / 1000, specifier: "%.1f")k").font(.rcMonoSmall).foregroundStyle(Color.rcAccent)
                            Text("XP").font(.system(size: 10.5)).foregroundStyle(Color.rcTextTertiary)
                        }
                        HStack(spacing: 3) {
                            Text("\(account.replicants)").font(.rcMonoSmall).foregroundStyle(Color.rcAccent)
                            Text("repl").font(.system(size: 10.5)).foregroundStyle(Color.rcTextTertiary)
                        }
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.rcTextTertiary)
                }
            }
            .padding(.horizontal, Space.l).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Color.rcSeparator).frame(height: 1) }
        }.buttonStyle(.plain)
    }
}

// MARK: - Device list

struct DeviceListView: View {
    @Binding var selection: DeviceInfo.ID?
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Devices").font(.system(size: 19, weight: .bold)).foregroundStyle(Color.rcTextPrimary)
                Text("\(Sample.devices.count)").font(.rcMonoSmall).foregroundStyle(Color.rcTextTertiary)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Color.rcStatusReady).frame(width: 6, height: 6)
                    Text("8 deployed").font(.rcCaption).foregroundStyle(Color.rcTextSecondary)
                }
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.m)
            Divider().overlay(Color.rcSeparator)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Sample.devices) { d in
                        DeviceRowView(device: d, selected: d.id == selection)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = d.id }
                    }
                }
            }
        }
        .background(Color.rcContentBackground)
    }
}

struct DeviceRowView: View {
    let device: DeviceInfo
    let selected: Bool
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: deviceSymbol(device.type)).font(.system(size: 18))
                .foregroundStyle(selected ? Color.rcAccent : .rcTextSecondary)
                .frame(width: 38, height: 38)
                .background(selected ? AnyShapeStyle(Color.rcAccentMuted) : AnyShapeStyle(Color.rcSurfaceRaisedStrong), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.typeName).font(.rcBodyEmph).foregroundStyle(Color.rcTextPrimary)
                    Text(device.id).font(.rcMonoSmall).foregroundStyle(Color.rcTextTertiary)
                }
                HStack(spacing: 7) {
                    Circle().fill(DeviceStatus.tone(for: device.statusRaw).color).frame(width: 5, height: 5)
                    Text(DeviceStatus.label(for: device.statusRaw)).font(.rcCaption).foregroundStyle(Color.rcTextSecondary)
                    Spacer(minLength: 0)
                    Text(device.location).font(.rcMonoSmall).foregroundStyle(Color.rcTextTertiary)
                }
            }
            VStack(alignment: .trailing, spacing: 5) {
                Text("\(device.capacity)%").font(.rcMonoSmall).foregroundStyle(Color.rcTextSecondary)
                Capsule().fill(Color.rcSeparator).frame(width: 48, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(DeviceStatus.tone(for: device.statusRaw).color)
                            .frame(width: 48 * CGFloat(device.capacity) / 100, height: 4)
                    }
            }
        }
        .padding(.horizontal, Space.m).padding(.vertical, 10)
        .background(selected ? AnyShapeStyle(Color.rcAccentMuted) : AnyShapeStyle(.clear))
        .overlay(alignment: .leading) { if selected { Capsule().fill(Color.rcAccent).frame(width: 3, height: 22).offset(x: 0) } }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.rcSeparatorSoft).frame(height: 1) }
    }
}

// MARK: - Inspector

struct InspectorView: View {
    let device: DeviceInfo
    @State private var selectedCommand: String? = "travel"

    private let primary = ["retarget", "recall", "travel", "start_mining", "stow", "deploy"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                readouts
                details
                commands
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
        .background(Color.rcContentBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: deviceSymbol(device.type)).font(.system(size: 26)).foregroundStyle(Color.rcAccent)
                .frame(width: 54, height: 54)
                .background(Color.rcAccentMuted, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.rcAccentBorder, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(device.typeName).font(.rcTitle).foregroundStyle(Color.rcTextPrimary)
                    StatusBadge(device.statusRaw, parameter: device.statusParam)
                }
                HStack(spacing: 8) {
                    Text(device.id).font(.rcMono).foregroundStyle(Color.rcTextSecondary)
                    Circle().fill(Color.rcTextTertiary).frame(width: 3, height: 3)
                    Text(device.location).font(.rcMono).foregroundStyle(Color.rcTextSecondary)
                }
            }
            Spacer()
        }
    }

    private var readouts: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 10) {
                CapacityRing(pct: device.capacity)
                Text("Op. Capacity").font(.system(size: 10.5, weight: .bold)).kerning(0.8).textCase(.uppercase).foregroundStyle(Color.rcTextTertiary)
            }
            .frame(width: 168).padding(16)
            .background(Color.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.rcSeparator, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 10) {
                Text("Active Task").font(.system(size: 10.5, weight: .bold)).kerning(0.8).textCase(.uppercase).foregroundStyle(Color.rcTextTertiary)
                if let label = device.taskLabel, let p = device.taskProgress {
                    Text(label).font(.rcHeadline).foregroundStyle(Color.rcTextPrimary)
                    ProgressView(value: p).tint(DeviceStatus.tone(for: device.statusRaw).color)
                    Text("\(Int(p * 100))% complete").font(.rcMonoSmall).foregroundStyle(Color.rcTextSecondary)
                } else {
                    Text("No active task — awaiting command").font(.rcBody).foregroundStyle(Color.rcTextTertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.rcSeparator, lineWidth: 0.5))
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Details")
            HStack(alignment: .top, spacing: 28) {
                detail("Type", device.typeName)
                detail("Owner", "Sylphrena")
                detail("Deployed", device.deployedFor)
            }
            HStack(spacing: 6) {
                ForEach(device.features, id: \.self) { f in
                    Text(f).font(.rcMonoSmall).foregroundStyle(Color.rcTextSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.rcSurfaceRaisedStrong, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.rcSeparator, lineWidth: 0.5))
    }

    private func detail(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k).font(.system(size: 10, weight: .semibold)).kerning(0.6).textCase(.uppercase).foregroundStyle(Color.rcTextTertiary)
            Text(v).font(.rcBody).foregroundStyle(Color.rcTextPrimary)
        }
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Commands")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                ForEach(primary, id: \.self) { cmd in
                    CommandButton(title: RD_CMD[cmd] ?? cmd, active: selectedCommand == cmd, disabled: cmd == "deploy") {
                        selectedCommand = (selectedCommand == cmd) ? nil : cmd
                    }
                }
            }
            if let cmd = selectedCommand, cmd != "deploy" { CommandParamPanel(command: cmd) { selectedCommand = nil } }
        }
    }
}

struct CapacityRing: View {
    let pct: Int
    var size: CGFloat = 104
    var body: some View {
        ZStack {
            Circle().stroke(Color.rcSeparator, lineWidth: 9)
            Circle().trim(from: 0, to: Double(pct) / 100)
                .stroke(Color.rcAccent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .rcAccent.opacity(0.4), radius: 4)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(pct)").font(.system(size: 24, weight: .bold, design: .monospaced)).foregroundStyle(Color.rcTextPrimary)
                Text("%").font(.system(size: 13)).foregroundStyle(Color.rcTextSecondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct CommandButton: View {
    let title: String
    var active = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.rcBodyEmph)
                .foregroundStyle(active ? Color.rcAccentOnColor : .rcTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(active ? AnyShapeStyle(Color.rcAccent) : AnyShapeStyle(Color.rcSurfaceRaisedStrong), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.rcSeparator, lineWidth: active ? 0 : 0.5))
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1)
    }
}

/// Parameterized command affordance — the key interaction rule.
struct CommandParamPanel: View {
    let command: String
    let onClose: () -> Void
    @State private var destination = "TARAZEDAR-BELT-1"
    @State private var resource = "Iron"
    @State private var transport = "Cruise"

    private let locations = ["CHAMAKUY-BELT-1", "CHAMAKUY-GATE", "TARAZEDAR-BELT-1", "TARAZEDAR-BELT-2", "VELZAN-REACH", "SELAY-DRIFT", "NARAK-VEIL"]
    private let resources = ["Iron", "Rares", "Conductive", "Carbon", "Ice", "Silicates"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(RD_CMD[command] ?? command).font(.system(size: 11, weight: .bold)).kerning(0.5).textCase(.uppercase).foregroundStyle(Color.rcAccent)
                Text("·").foregroundStyle(Color.rcTextTertiary)
                Text(paramTitle).font(.rcBodyEmph).foregroundStyle(Color.rcTextPrimary)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.rcTextSecondary) }.buttonStyle(.plain)
            }

            switch command {
            case "travel", "retarget", "recall":
                Picker("Destination", selection: $destination) { ForEach(locations, id: \.self) { Text($0).font(.rcMono) } }
                    .pickerStyle(.menu).labelsHidden()
                if command == "travel" {
                    Picker("Transport", selection: $transport) { Text("Cruise").tag("Cruise"); Text("Surge").tag("Surge") }
                        .pickerStyle(.segmented).labelsHidden()
                }
            case "start_mining":
                Picker("Resource", selection: $resource) { ForEach(resources, id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            default:
                Text("Confirm \(RD_CMD[command] ?? command)?").font(.rcBody).foregroundStyle(Color.rcTextSecondary)
            }

            HStack(spacing: 9) {
                Spacer()
                Button("Cancel") { onClose() }.buttonStyle(.plain).foregroundStyle(Color.rcTextSecondary)
                Button(confirmTitle) { onClose() }
                    .buttonStyle(.borderedProminent).tint(Color.rcAccent)
            }
        }
        .padding(16)
        .background(Color.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.rcAccentBorder, lineWidth: 0.5))
    }

    private var paramTitle: String {
        switch command {
        case "travel": return "Set destination"
        case "retarget": return "Choose target site"
        case "recall": return "Recall destination"
        case "start_mining": return "Select resource"
        default: return ""
        }
    }
    private var confirmTitle: String {
        switch command {
        case "start_mining": return "Start mining → \(resource)"
        case "travel", "retarget", "recall": return "\(RD_CMD[command] ?? command) → \(destination)"
        default: return RD_CMD[command] ?? command
        }
    }
}

// MARK: - Small shared pieces

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.rcSectionLabel).kerning(1.2).textCase(.uppercase).foregroundStyle(Color.rcTextTertiary)
    }
}

struct PlaceholderPane: View {
    let title: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "circle.dotted").font(.system(size: 30)).foregroundStyle(Color.rcTextTertiary)
            Text(title).font(.rcHeadline).foregroundStyle(Color.rcTextSecondary)
            Text("Not built in this scaffold yet.").font(.rcBody).foregroundStyle(Color.rcTextTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.rcContentBackground)
    }
}

// Friendly command labels (mirrors RD_CMD in the web data layer).
let RD_CMD: [String: String] = [
    "deploy": "Deploy", "recall": "Recall", "retarget": "Retarget", "travel": "Travel",
    "stow": "Stow", "start_mining": "Start mining", "change_owner": "Change owner",
    "deactivate": "Deactivate", "decommission": "Decommission",
]

// MARK: - Sample data (replace with your API models)

enum Sample {
    static let account = AccountInfo(name: "K. Pennig", email: "kell@pennig.name", xp: 128400, replicants: 5)

    @MainActor static let replicants: [ReplicantInfo] = [
        .init(id: "30B93F2F", name: "Sylphrena", host: .vessel, hostName: "Cognition", statusRaw: "travelling",
              travelTo: "TARAZEDAR-BELT-1", travelRemaining: "2h 14m", travelProgress: 0.64,
              location: "CHAMAKUY-BELT-1", xp: 12840, deviceCount: 10, isNPC: true,
              plan: "Seed the Chamakuy belt with self-sustaining infrastructure."),
        .init(id: "9F22A1C7", name: "Pattern", host: .matrix, hostName: "Lattice C-7", statusRaw: "idle",
              travelTo: nil, travelRemaining: nil, travelProgress: nil,
              location: "TARAZEDAR-BELT-1", xp: 8420, deviceCount: 6, isNPC: true,
              plan: "Hold and harden the Tarazedar lattice."),
        .init(id: "5D0E88B3", name: "Ivory", host: .hub, hostName: "Velzan Claim", statusRaw: "idle",
              travelTo: nil, travelRemaining: nil, travelProgress: nil,
              location: "VELZAN-REACH", xp: 21030, deviceCount: 14, isNPC: false,
              plan: "Expand the Velzan claim; survey adjacent systems."),
    ]

    static let devices: [DeviceInfo] = [
        .init(id: "B58FCC78", type: "mining_drone", typeName: "Mining Drone", location: "TARAZEDAR-BELT-1",
              statusRaw: "mining", statusParam: "Iron", capacity: 67, integrity: 96, signal: 88,
              features: ["cruise", "mine", "stow"],
              commands: ["change_owner", "deactivate", "decommission", "deploy", "recall", "retarget", "start_mining", "stow", "travel"],
              taskLabel: "Mining Iron · Vein 7C", taskProgress: 0.42, deployedFor: "14d 6h"),
        .init(id: "A1F00C2D", type: "survey_probe", typeName: "Survey Probe", location: "CHAMAKUY-BELT-1",
              statusRaw: "prospecting", statusParam: nil, capacity: 88, integrity: 99, signal: 94,
              features: ["cruise", "scan", "stow"], commands: ["recall", "retarget", "travel"],
              taskLabel: "Prospecting", taskProgress: 0.71, deployedFor: "3d 11h"),
        .init(id: "7C0E9B41", type: "ftl_relay", typeName: "FTL Relay", location: "CHAMAKUY-GATE",
              statusRaw: "relaying", statusParam: nil, capacity: 100, integrity: 100, signal: 100,
              features: ["relay"], commands: ["recall", "deactivate"], taskLabel: nil, taskProgress: nil, deployedFor: "61d 2h"),
        .init(id: "22D7E5A9", type: "forge", typeName: "Forge", location: "CHAMAKUY-BELT-1",
              statusRaw: "printing", statusParam: "Mining Drone", capacity: 54, integrity: 91, signal: 90,
              features: ["print", "stow"], commands: ["recall", "print"], taskLabel: "Printing Mining Drone", taskProgress: 0.33, deployedFor: "9d 0h"),
        .init(id: "9E33B70F", type: "hauler", typeName: "Hauler", location: "TARAZEDAR-BELT-1",
              statusRaw: "cruising", statusParam: nil, capacity: 73, integrity: 88, signal: 76,
              features: ["cruise", "carry", "stow"], commands: ["recall", "retarget", "travel"], taskLabel: "En route · Chamakuy-Gate", taskProgress: 0.55, deployedFor: "2d 4h"),
        .init(id: "D4A2110B", type: "mining_drone", typeName: "Mining Drone", location: "TARAZEDAR-BELT-2",
              statusRaw: "idle", statusParam: nil, capacity: 91, integrity: 97, signal: 82,
              features: ["cruise", "mine", "stow"], commands: ["deploy", "retarget", "start_mining"], taskLabel: nil, taskProgress: nil, deployedFor: "20d 8h"),
    ]
}

// MARK: - Previews

#Preview("Split · dark") {
    ReplicantSplitView().frame(width: 1180, height: 760).preferredColorScheme(.dark)
}

#Preview("Split · light") {
    ReplicantSplitView().frame(width: 1180, height: 760).preferredColorScheme(.light)
}
