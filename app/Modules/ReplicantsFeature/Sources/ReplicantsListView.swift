//
//  ReplicantsListView.swift
//  Replicould — Replicants feature
//
//  The directory master list for the split view's content column. It's a pure
//  renderer of `store.sections`: the `KnownReplicant` directory is observed as a
//  static `@FetchAll` *in the reducer's state*, and the search/filter/sort
//  grouping is a synchronous computed property on that state. So the list always
//  matches state exactly — no async query reload, no empty-state flash. The store
//  drives selection and the cold-load / refresh.
//

import ComposableArchitecture
import GameModels
import GameServices
import SwiftUI
import UI

public struct ReplicantsListView: View {
    @Bindable var store: StoreOf<ReplicantsFeature>

    public init(store: StoreOf<ReplicantsFeature>) {
        self.store = store
    }

    public var body: some View {
        // The account's own replicants — tags which rows get the accent host glyph
        // (the section grouping isn't visible inside the row closure).
        let ownCodes = Set(store.roster.map(\.replicantCode))
        return SelectableList(
            selection: $store.selectedReplicantCode,
            sections: store.sections.map {
                SelectableSection(id: $0.id, title: $0.id, items: $0.replicants)
            },
            rowID: \.replicantCode,
            style: .inline,
            pinnedViews: [.sectionHeaders]
        ) { replicant, isSelected in
            ReplicantRow(replicant: replicant, isOwn: ownCodes.contains(replicant.replicantCode))
                .rcSidebarRow(isSelected: isSelected)
        }
        .background(.rcContentBackground)
        .overlay {
            if store.sections.isEmpty {
                if store.isDirectoryEmpty && store.isLoading {
                    ProgressView()
                } else if !store.searchText.isEmpty {
                    ContentUnavailableView.search(text: store.searchText)
                } else {
                    ContentUnavailableView(
                        "No Replicants",
                        systemImage: SidebarSymbol.replicants,
                        description: Text("The galaxy's replicants will appear here once the directory loads.")
                    )
                }
            }
        }
        .navigationTitle("Replicants")
        .navigationSubtitle(Text("^[\(store.directory.count) known replicants](inflect: true)"))
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search replicants")
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage {
                RCErrorBanner(errorMessage) { store.send(.dismissError) }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.send(.refreshButtonTapped)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh directory")
                .disabled(store.isLoading)
            }
        }
        // Cold-load trigger (first run / empty directory).
        .task { store.send(.task) }
    }

}

// MARK: - Row

private struct ReplicantRow: View {
    let replicant: KnownReplicant
    let isOwn: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            glyphTile
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(replicant.name.isEmpty ? replicant.replicantCode : replicant.name)
                        .font(.rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                    if replicant.isNPC {
                        Text("NPC")
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                            .rcPill(.neutral)
                    }
                    Spacer(minLength: Space.xs)
                    if replicant.experiencePoints > 0 {
                        Text("\(replicant.experiencePoints) XP")
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                    }
                }
                HStack(spacing: Space.s) {
                    if let status = replicant.status, !status.isEmpty {
                        StatusBadge(status)
                    }
                    if let location = replicant.displayLocationLabel {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .labelStyle(.titleAndIcon)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextSecondary)
                            .lineLimit(1)
                        if let seen = replicant.lastSeenAt {
                            Text("· \(seen.formatted(.relative(presentation: .named)))")
                                .font(.rcMonoSmall)
                                .foregroundStyle(.rcTextTertiary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("Location unknown")
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextTertiary)
                    }
                    Spacer(minLength: Space.xs)
                }
            }
        }
        .padding(.vertical, Space.xs)
    }

    private var glyphTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(isOwn ? Color.rcAccentBorder : .rcSeparator, lineWidth: Hairline.thin)
                )
            Image(systemName: replicant.isNPC ? SidebarSymbol.npc : SidebarSymbol.replicants)
                .font(.system(size: IconSize.m, weight: .regular))
                .foregroundStyle(isOwn ? Color.rcAccent : .rcTextSecondary)
        }
        .frame(width: 30, height: 30)
    }
}
