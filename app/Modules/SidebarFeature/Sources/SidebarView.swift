//
//  SidebarView.swift
//  Replicould — Sidebar feature
//
//  The sidebar column: active-replicant header · grouped category list · account
//  footer. Progress and host glyphs are derived from the local fleet, observed
//  straight from SQLite. The switcher writes the chosen replicant to the shared
//  `activeReplicantCode` (the same appStorage key Locations/Stars read), so
//  changing the active replicant here updates the whole app.
//

import ComposableArchitecture
import GameModels
import SQLiteData
import SwiftUI
import UI

public struct SidebarView: View {
    @Bindable var store: StoreOf<SidebarFeature>
    /// Live unread-message count, observed from SQLite, for the Messages badge.
    @FetchOne(Message.where { !$0.isRead }.count()) private var unreadCount = 0
    /// Live count of unread *story* messages — surfaced as an accent pill ahead of
    /// the plain unread count, so a narrative beat in the inbox reads at a glance.
    @FetchOne(Message.where { !$0.isRead && $0.messageType.eq("story") }.count()) private var unreadStoryCount = 0
    /// Live count of open location events ("quests"), for the Location Events badge.
    @FetchOne(LocationEvent.where { $0.status.eq("active") }.count()) private var activeEventCount = 0
    /// Live count of open events whose objectives are met — the ones that can be
    /// completed right now. Surfaced as the accent pill ahead of the plain open
    /// count, exactly like unread *story* messages, so "ready to complete" reads at
    /// a glance.
    @FetchOne(LocationEvent.where { $0.status.eq("active") && $0.objectivesMet }.count()) private var readyEventCount = 0
    /// The whole fleet — the header resolves the active replicant's host glyph
    /// (and the tint/label of any running progress) from it.
    @FetchAll private var devices: [Device]
    /// Open operations — the header's progress bar is driven off these (not the
    /// device's live activity block), so it clears atomically when an op completes.
    @FetchAll(Operation.order { $0.startedAt.desc() }) private var operations: [Operation]
    /// The known-replicant directory — the header reads the active replicant's
    /// public `plan` from here (hydrated on appear/change).
    @FetchAll private var knownReplicants: [KnownReplicant]
    /// The app-wide active-replicant selection (shared with Locations / Stars).
    @Shared(.appStorage(Account.activeReplicantCodeKey)) private var activeReplicantCode: String?

    public init(store: StoreOf<SidebarFeature>) {
        self.store = store
    }

    /// The badge count for a category — Messages shows unread, Location Events
    /// shows open quests, everything else stays silent (`.badge(0)` renders none).
    private func badgeCount(for item: SidebarItem) -> Int {
        switch item {
        case .messages: unreadCount
        case .locationEvents: activeEventCount
        default: 0
        }
    }

    /// The accent-pill count for a category — the "needs attention now" subset shown
    /// ahead of the plain count. Messages surfaces unread *story* beats; Location
    /// Events surfaces quests that are ready to complete. Everything else stays 0.
    private func accentCount(for item: SidebarItem) -> Int {
        switch item {
        case .messages: unreadStoryCount
        case .locationEvents: readyEventCount
        default: 0
        }
    }

    /// A sidebar category row. Every row shares one structure — `Label` + a
    /// trailing `SidebarCategoryBadge` — so the outline list's identity diffing
    /// stays stable (a per-row structural conditional trips a `ViewListTree`
    /// assertion). Messages and Location Events pass an accent count, so they can
    /// show the composite pill (ready/story count + a plain remainder).
    private func categoryRow(for item: SidebarItem) -> some View {
        let accent = accentCount(for: item)
        return HStack(spacing: Space.xs) {
            Label {
                Text(item.title)
            } icon: {
                Image(systemName:item.symbol)
                    .frame(width: 16)
            }
            Spacer(minLength: Space.xs)
            SidebarCategoryBadge(
                storyCount: accent,
                otherCount: max(0, badgeCount(for: item) - accent)
            )
        }
        .padding(.vertical, Space.xs)
        .padding(.trailing, Space.xs)
    }

    public var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()
            SelectableList(
                selection: $store.category,
                sections: SidebarItem.groups.map {
                    SelectableSection(id: $0.id, title: $0.id, items: $0.items)
                },
                rowID: \.self
            ) { item, isSelected in
                categoryRow(for: item).rcSidebarRow(isSelected: isSelected)
            }

            Divider()
            RCAccountFooter(
                name: store.account.name,
                email: store.account.email,
                experiencePoints: store.account.experiencePointsTotal,
                replicantCount: store.replicants.count
            ) {
                store.send(.accountButtonTapped)
            }
        }
    }

    // — Active replicant header —
    @ViewBuilder private var sidebarHeader: some View {
        if store.replicants.isEmpty {
            // No roster yet (fresh session / mid-sync) — a quiet placeholder.
            HStack(spacing: Space.s) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.rcTextTertiary)
                Text("No replicants yet")
                    .font(.rcBody)
                    .foregroundStyle(.rcTextSecondary)
                Spacer()
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.m)
        } else {
            RCActiveReplicantHeader(
                replicants: rosterOptions,
                selection: switcherSelection,
                location: activeReplicant?.currentLocationName ?? activeReplicant?.currentLocation,
                experiencePoints: activeReplicant?.experiencePoints ?? 0,
                deviceCount: activeReplicant?.deviceCount ?? 0,
                progress: activeReplicantProgress,
                plan: activePlan,
                onShowInReplicants: { store.category = .replicants },
                onEditPlan: { plan in
                    if let code = activeReplicant?.replicantCode {
                        store.send(.savePlan(code: code, plan: plan))
                    }
                }
            )
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.m)
            // Hydrate the active replicant's public details (its plan) whenever the
            // selection changes, so the plan line reflects the server.
            .task(id: activeReplicant?.replicantCode) {
                if let code = activeReplicant?.replicantCode {
                    store.send(.loadActivePlan(code))
                }
            }
        }
    }

    /// The active replicant's public plan, read from its known-replicant record.
    private var activePlan: String? {
        guard let code = activeReplicant?.replicantCode else { return nil }
        return knownReplicants.first { $0.replicantCode == code }?.plan
    }

    // — Active replicant derivation —

    /// The currently-active replicant: the stored selection, or the sole replicant
    /// when there's exactly one. On a multi-replicant roster with nothing (or a
    /// stale code) selected it's nil rather than a guessed first — matching the
    /// resolution used by Locations / Stars so the whole app agrees on "active".
    /// (The switcher itself still shows a first-option default for display; see
    /// `switcherSelection`.)
    private var activeReplicant: Replicant? {
        store.replicants.first { $0.replicantCode == activeReplicantCode }
            ?? (store.replicants.count == 1 ? store.replicants.first : nil)
    }

    /// The roster mapped to switcher options, each carrying its host glyph.
    private var rosterOptions: [RCReplicant] {
        store.replicants.map { replicant in
            let device = hostDevice(for: replicant)
            return RCReplicant(
                id: replicant.replicantCode,
                name: replicant.name,
                host: device.map { HostKind(deviceType: $0.deviceType) } ?? .heaven_vessel,
                hostDeviceType: device?.deviceType
            )
        }
    }

    /// A binding the switcher drives: reads the active option, writes the choice
    /// back to the shared `activeReplicantCode`.
    private var switcherSelection: Binding<RCReplicant> {
        Binding(
            get: {
                rosterOptions.first { $0.id == activeReplicant?.replicantCode }
                    ?? rosterOptions.first
                    ?? RCReplicant(id: "", name: "—", host: .heaven_vessel)
            },
            set: { newValue in $activeReplicantCode.withLock { $0 = newValue.id } }
        )
    }

    /// The hosting device for a replicant, when it's in the local fleet — the
    /// source of both the host kind and the raw `device_type` glyph.
    private func hostDevice(for replicant: Replicant) -> Device? {
        guard let code = replicant.hostedDeviceCode else { return nil }
        return devices.first { $0.deviceCode == code }
    }

    /// The active replicant's most relevant running operation — derived from the
    /// `Operation` table (see `SidebarProgress`) so it clears the instant an op
    /// completes, in lock-step with the device inspector's own bar.
    private var activeReplicantProgress: RCReplicantProgress? {
        guard let active = activeReplicant else { return nil }
        return SidebarProgress.active(replicant: active, devices: devices, operations: operations)
    }
}

// MARK: - Category badge

/// The trailing badge for a sidebar category. Messages passes a non-zero
/// `storyCount` to get the composite treatment — an accent pill for the unread
/// story count, then a plain `+N` for the remaining unread; every other category
/// passes `storyCount: 0` and shows a plain count. A zero total renders nothing,
/// so a category stays silent until it has something to report.
struct SidebarCategoryBadge: View {
    /// Unread *story* messages (Messages only) — the accent pill.
    let storyCount: Int
    /// The remainder — unread non-story messages, or a plain category count.
    let otherCount: Int

    var body: some View {
        HStack(spacing: Space.xs) {
            if storyCount > 0 {
                Text("\(storyCount)")
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcAccent)
                    .rcPill(.accent)
                if otherCount > 0 {
                    Text("+\(otherCount)")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            } else if otherCount > 0 {
                Text("\(otherCount)")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Previews

/// The sidebar's category list with the composite Messages badge — one unread
/// story (accent pill) plus three other unread → ⟨1⟩ +3.
///
/// This drives the real row layout and `SidebarCategoryBadge` with fixed counts
/// rather than mounting the live `SidebarView`: the headless preview agent can't
/// host that view's TCA store + SQLite `@Fetch` observers (they re-publish during
/// the outline list's first diff and trip a `ViewListTree` assertion). The list
/// itself renders identically to the shipping sidebar.
#Preview("Story badge · ⟨1⟩ +3") {
    let prime = RCReplicant(id: "RPL-0001", name: "pennig-1", host: .heaven_vessel)
    return NavigationSplitView {
        // Mirror the real `SidebarView.body` — header · category list · footer —
        // with fixed values in place of the live store/@Fetch layer.
        VStack(spacing: 0) {
            RCActiveReplicantHeader(
                replicants: [prime],
                selection: .constant(prime),
                location: "SHERATONON-6-52",
                experiencePoints: 4_536,
                deviceCount: 3,
                plan: "Make a Mac app to play this game",
                onShowInReplicants: {},
                onEditPlan: { _ in }
            )
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.m)
            Divider()
            SelectableList(
                selection: .constant(SidebarItem.locations),
                sections: SidebarItem.groups.map {
                    SelectableSection(id: $0.id, title: $0.id, items: $0.items)
                },
                rowID: \.self
            ) { item, isSelected in
                HStack(alignment: .center, spacing: Space.xs) {
                    Label {
                        Text(item.title)
                    } icon: {
                        Image(systemName:item.symbol)
                            .frame(width: 16)
                    }
                    Spacer(minLength: Space.xs)
                    SidebarCategoryBadge(
                        storyCount: item == .messages ? 1 : 0,
                        otherCount: item == .messages ? 3 : (item == .locationEvents ? 2 : 0)
                    )
                }
                .padding(.vertical, Space.xs)
                .padding(.trailing, Space.xs)
                .rcSidebarRow(isSelected: isSelected)
            }
            Divider()
            RCAccountFooter(
                name: "pennig",
                email: "matt@pennig.name",
                experiencePoints: 4_536,
                replicantCount: 1,
                action: {}
            )
        }
        .navigationSplitViewColumnWidth(260)
    } detail: {
        Color.rcContentBackground
    }
    .frame(width: 720, height: 720)
    .preferredColorScheme(.dark)
}
