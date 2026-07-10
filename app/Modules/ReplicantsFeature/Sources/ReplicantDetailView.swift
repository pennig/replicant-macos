//
//  ReplicantDetailView.swift
//  Replicould — Replicants feature
//
//  The replicant inspector for the split view's detail column: identity (name,
//  code, NPC badge, pronouns, status), last-known location with the time it was
//  seen, stats (XP, host, carried devices), and — for NPCs and any replicant that
//  publishes them — the lore fields (plan, project, description). Reads the
//  selected row straight from the `KnownReplicant` table and asks the reducer to
//  refresh its full details when the selection changes.
//

import ComposableArchitecture
import GameModels
import GameServices
import IssueReporting
import SQLiteData
import SwiftUI
import UI

public struct ReplicantDetailView: View {
    let store: StoreOf<ReplicantsFeature>

    public init(store: StoreOf<ReplicantsFeature>) {
        self.store = store
    }

    /// Whether the inspector is waiting on the details fetch for this replicant.
    private var isLoadingDetails: Bool {
        store.selectedReplicant.map { store.loadingDetailCode == $0.replicantCode } ?? false
    }

    public var body: some View {
        Group {
            if let replicant = store.selectedReplicant {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        header(replicant)
                        locationCard(replicant)
                        lore(replicant)
                        devices(replicant)
                    }
                    .padding(Space.xl)
                    .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(replicant.name.isEmpty ? replicant.replicantCode : replicant.name)
                .overlay(alignment: .top) {
                    if isLoadingDetails {
                        ProgressView()
                            .controlSize(.small)
                            .padding(Space.s)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Replicant Selected",
                    systemImage: SidebarSymbol.replicants,
                    description: Text("Select a replicant to inspect it.")
                )
            }
        }
        // Fetch this replicant's full details on selection; they merge into its
        // record and surface via the observed `directory`.
        .task(id: store.selectedReplicantCode) {
            store.send(.detailsRequested(code: store.selectedReplicantCode))
        }
        // Ensure the host device is in the local fleet so its row can show the real
        // type/glyph. Re-runs when the host code changes.
        .task(id: store.selectedReplicant?.hostedDeviceCode) {
            store.send(.hostDeviceRequested(code: store.selectedReplicant?.hostedDeviceCode))
        }
    }

    // MARK: Header

    private func header(_ replicant: KnownReplicant) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(.rcSeparator, lineWidth: 0.5)
                    )
                Image(systemName: replicant.isNPC ? SidebarSymbol.npc : SidebarSymbol.replicants)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.rcAccent)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(replicant.name.isEmpty ? replicant.replicantCode : replicant.name)
                        .font(.rcTitle)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                    if replicant.isNPC {
                        Text("NPC")
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                            .rcPill(.neutral)
                    }
                }
                if let status = replicant.status, !status.isEmpty {
                    StatusBadge(status)
                }
                HStack(spacing: Space.s) {
                    Text(replicant.replicantCode)
                        .font(.rcMono)
                        .foregroundStyle(.rcTextSecondary)
                        .textSelection(.enabled)
                    if let pronouns = replicant.pronouns, !pronouns.isEmpty {
                        Text("·").foregroundStyle(.rcTextTertiary)
                        Text(pronouns)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: Space.m)
            if replicant.experiencePoints > 0 {
                VStack(spacing: Space.xs) {
                    Text("\(replicant.experiencePoints)")
                        .font(.rcHeadline)
                        .foregroundStyle(.rcTextPrimary)
                        .monospacedDigit()
                    Text("XP")
                        .font(.rcSectionLabel)
                        .foregroundStyle(.rcTextTertiary)
                }
                .fixedSize()
            }
        }
    }

    // MARK: Location

    private func locationCard(_ replicant: KnownReplicant) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("LAST KNOWN LOCATION")
                .font(.rcSectionLabel).kerning(1)
                .foregroundStyle(.rcTextTertiary)
            if let location = replicant.displayLocationLabel {
                HStack(spacing: Space.s) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 12))
                        .foregroundStyle(.rcAccent)
                    Text(location)
                        .font(.rcHeadlineMono)
                        .foregroundStyle(.rcTextPrimary)
                        .textSelection(.enabled)
                }
                if let seen = replicant.lastSeenAt {
                    Text("Seen \(seen.formatted(.relative(presentation: .named)))")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                } else if replicant.lastKnownLocation == nil {
                    Text("From the directory — position not precisely tracked.")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            } else {
                Text("No sightings yet. Scan a system this replicant occupies to locate it.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(cardBackground)
    }

    // MARK: Lore

    @ViewBuilder
    private func lore(_ replicant: KnownReplicant) -> some View {
        let entries: [(String, String)] = [
            ("Plan", replicant.plan),
            ("Project", replicant.project),
            ("Description", replicant.descriptionText),
        ].compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("PROFILE")
                    .font(.rcSectionLabel).kerning(1)
                    .foregroundStyle(.rcTextTertiary)
                ForEach(entries, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(label.uppercased())
                            .font(.rcSectionLabel)
                            .foregroundStyle(.rcTextTertiary)
                        Text(value)
                            .font(.rcBody)
                            .foregroundStyle(.rcTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.m)
            .background(cardBackground)
        }
    }

    // MARK: Devices

    @ViewBuilder
    private func devices(_ replicant: KnownReplicant) -> some View {
        let stowed = replicant.stowedDevices
        let attached = replicant.attachedDevices
        if !stowed.isEmpty || !attached.isEmpty || replicant.hostedDeviceCode != nil {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("DEVICES")
                    .font(.rcSectionLabel).kerning(1)
                    .foregroundStyle(.rcTextTertiary)
                if let host = replicant.hostedDeviceCode {
                    // The host resolves to a real device once we have it locally —
                    // show its type/glyph; otherwise fall back to the generic mark.
                    let resolved = store.selectedHostDevice?.deviceCode == host ? store.selectedHostDevice : nil
                    deviceRow(
                        code: host,
                        type: resolved.map { ReplicantPresentation.displayName($0.deviceType) } ?? "Host device",
                        deviceType: resolved?.deviceType,
                        isHost: true
                    )
                }
                ForEach(attached) { device in
                    deviceRow(code: device.deviceCode, type: ReplicantPresentation.displayName(device.deviceType), deviceType: device.deviceType)
                }
                ForEach(stowed) { device in
                    deviceRow(code: device.deviceCode, type: ReplicantPresentation.displayName(device.deviceType), deviceType: device.deviceType)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.m)
            .background(cardBackground)
        }
    }

    private func deviceRow(code: String, type: String, deviceType: String? = nil, isHost: Bool = false) -> some View {
        HStack(spacing: Space.m) {
            Group {
                // Actual devices get their per-type glyph; a host we haven't yet
                // resolved to a device falls back to the semantic house mark.
                if let deviceType {
                    Image.rcSymbol("device.\(deviceType)")
                } else {
                    Image(systemName: isHost ? "house" : "circle.hexagongrid")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(isHost ? Color.rcAccent : .rcTextTertiary)
            .frame(width: 16)
            Text(type)
                .font(.rcBody)
                .foregroundStyle(.rcTextPrimary)
            if isHost {
                Text("HOST")
                    .font(.rcSectionLabel).kerning(0.5)
                    .foregroundStyle(.rcAccent)
                    .rcPill(.accent)
            }
            Spacer(minLength: Space.s)
            Text(code)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextTertiary)
                .textSelection(.enabled)
        }
        .padding(.vertical, isHost ? Space.xs : 0)
        .padding(.horizontal, isHost ? Space.s : 0)
        .background {
            if isHost {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Color.rcAccent.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Color.rcAccentBorder, lineWidth: 0.5)
                    )
            }
        }
    }

    // MARK: Chrome

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(.rcSurfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: 0.5)
            )
    }
}

// MARK: - Presentation

/// View-side display helpers for the Replicants feature.
enum ReplicantPresentation {
    /// "mining_drone" → "Mining Drone".
    static func displayName(_ raw: String) -> String {
        raw
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
