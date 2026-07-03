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
import DependencyClients
import GameModels
import SQLiteData
import SwiftUI
import UI

public struct SidebarView: View {
    @Bindable var store: StoreOf<SidebarFeature>
    /// Live unread-message count, observed from SQLite, for the Messages badge.
    @FetchOne(Message.where { !$0.isRead }.count()) private var unreadCount = 0
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

    public var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()
            List(selection: $store.category) {
                ForEach(SidebarItem.groups) { group in
                    Section(group.id) {
                        ForEach(group.items) { item in
                            Label(item.title, systemImage: item.symbol)
                                // `.badge(0)` renders nothing, so only Messages
                                // shows a count, and only while unread > 0.
                                .badge(item == .messages ? unreadCount : 0)
                                .tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            RCAccountFooter(
                name: store.account.name,
                email: store.account.email,
                experiencePoints: store.account.experiencePointsTotal,
                replicantCount: store.replicants.count
            ) {
                store.isShowingAccount = true
            }
        }
        .sheet(isPresented: $store.isShowingAccount) {
            AccountView(store: store)
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

    /// The currently-active replicant, falling back to the first in the roster
    /// when nothing (or a stale code) is selected.
    private var activeReplicant: Replicant? {
        store.replicants.first { $0.replicantCode == activeReplicantCode } ?? store.replicants.first
    }

    /// The roster mapped to switcher options, each carrying its host glyph.
    private var rosterOptions: [RCReplicant] {
        store.replicants.map { replicant in
            RCReplicant(id: replicant.replicantCode, name: replicant.name, host: host(for: replicant))
        }
    }

    /// A binding the switcher drives: reads the active option, writes the choice
    /// back to the shared `activeReplicantCode`.
    private var switcherSelection: Binding<RCReplicant> {
        Binding(
            get: {
                rosterOptions.first { $0.id == activeReplicant?.replicantCode }
                    ?? rosterOptions.first
                    ?? RCReplicant(id: "", name: "—", host: .vessel)
            },
            set: { newValue in $activeReplicantCode.withLock { $0 = newValue.id } }
        )
    }

    /// The host kind for a replicant, read from its hosting device's type when
    /// that device is in the local fleet (defaults to a vessel otherwise).
    private func host(for replicant: Replicant) -> HostKind {
        guard
            let code = replicant.hostedDeviceCode,
            let device = devices.first(where: { $0.deviceCode == code })
        else { return .vessel }
        return HostKind(deviceType: device.deviceType)
    }

    /// The active replicant's most relevant running operation — derived from the
    /// `Operation` table (see `SidebarProgress`) so it clears the instant an op
    /// completes, in lock-step with the device inspector's own bar.
    private var activeReplicantProgress: RCReplicantProgress? {
        guard let active = activeReplicant else { return nil }
        return SidebarProgress.active(replicant: active, devices: devices, operations: operations)
    }
}
