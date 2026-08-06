//
//  DevicesView.swift
//  Replicould — Devices feature
//
//  The fleet master list for the split view's content column. Rows render
//  straight from the `Device` table via `@FetchAll`, so every stream update flows
//  in automatically; the store drives selection and the cold-load/refresh.
//

import ComposableArchitecture
import GameModels
import GameServices
import SQLiteData
import SwiftUI
import UI

public struct DevicesListView: View {
    @Bindable var store: StoreOf<DevicesFeature>

    public init(store: StoreOf<DevicesFeature>) {
        self.store = store
    }

    public var body: some View {
        // Bound once: `sections` is derived on access, so reading it from the
        // list, the overlay, and the subtitle would recompute the whole layout
        // three times per body evaluation.
        let sections = store.sections

        SelectableList(
            selection: $store.selectedDeviceCode,
            orderedIDs: sections.orderedIDs,
            style: .inline,
            pinnedViews: [.sectionHeaders]
        ) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        SelectableRow(id: entry.id) { isSelected in
                            DeviceRow(entry: entry) {
                                store.send(
                                    .hostDisclosureToggled(entry.id),
                                    animation: disclosureAnimation(rows: entry.childCount)
                                )
                            }
                            .rcSidebarRow(isSelected: isSelected)
                        }
                    }
                } header: {
                    if let header = section.header {
                        RCReadoutSectionHeader(
                            title: header.title,
                            count: header.count,
                            isCollapsed: header.isCollapsed,
                            isWarning: header.hasDamaged,
                            isTitleDesignation: header.titleIsDesignation,
                            shares: header.statusShares.map {
                                RCReadoutSectionHeader.Share(
                                    label: $0.status,
                                    count: $0.count,
                                    color: DeviceStatus.tone(for: $0.status).color
                                )
                            }
                        ) {
                            store.send(
                                .groupDisclosureToggled(section.id),
                                animation: disclosureAnimation(rows: header.count)
                            )
                        }
                    }
                }
            }
        }
        .background(.rcContentBackground)
        .overlay {
            if sections.isEmpty { emptyState }
        }
        .navigationTitle("Devices")
        .navigationSubtitle(subtitle)
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search devices")
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage {
                RCErrorBanner(errorMessage) { store.send(.dismissError) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Group by", selection: groupingSelection) {
                        ForEach(DeviceGrouping.allCases) { option in
                            Label(option.label, systemImage: option.symbol).tag(option)
                        }
                    }
                } label: {
                    Label("Group by", systemImage: "rectangle.3.group")
                }
                .help("Group the fleet")
            }
            ToolbarItem {
                Button {
                    store.send(.refreshButtonTapped)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh fleet")
                .disabled(store.isLoading)
            }
        }
        .task { store.send(.task) }
    }

    /// Nil past `Motion.disclosureRowLimit`, so opening a huge
    /// section doesn't animate every row in at once. The chevron animates on
    /// its own regardless.
    private func disclosureAnimation(rows: Int) -> Animation? {
        rows <= Motion.disclosureRowLimit ? Motion.disclosure : nil
    }

    // `grouping` is `@Shared`, which is written through an action, never set.
    private var groupingSelection: Binding<DeviceGrouping> {
        Binding(
            get: { store.grouping },
            set: { store.send(.groupingSelected($0)) }
        )
    }

    /// "N of M devices" while a query is active, the plain inflected count
    /// otherwise. N counts *matches across the whole fleet*, not visible rows —
    /// a revealed ancestor is visible without being a match.
    private var subtitle: Text {
        let total = store.devices.count
        guard total > 0 else { return Text("") }
        guard !store.searchText.isEmpty else {
            return Text("^[\(total) device](inflect: true)")
        }
        return Text("\(store.matchCount) of ^[\(total) device](inflect: true)")
    }

    @ViewBuilder
    private var emptyState: some View {
        if !store.searchText.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else if store.isLoading {
            ProgressView()
        } else {
            ContentUnavailableView(
                "No Devices",
                systemImage: SidebarSymbol.devices,
                description: Text("Your fleet will appear here once it loads.")
            )
        }
    }
}
