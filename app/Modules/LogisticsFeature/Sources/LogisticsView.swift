//
//  LogisticsView.swift
//  Replicould — Logistics feature
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

public struct LogisticsView: View {
    @Bindable var store: StoreOf<LogisticsFeature>
    // Ephemeral presentation state, not domain state — stays off the reducer.
    @State private var showAllSources = false

    public init(store: StoreOf<LogisticsFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RCSegmentedControl(selection: $store.tab, options: LogisticsFeature.Tab.allCases, label: \.title)
                .padding(Space.m)
            switch store.tab {
            case .yields: yieldsTab
            case .theatres: TheatresTab(store: store)
            }
        }
        .navigationTitle("Logistics")
    }

    private var yieldsTab: some View {
        let summary = store.summary
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                RCSectionHeader("Haul Yields")
                YieldKPIRow(summary: summary)
                RCSegmentedControl(
                    selection: $store.range,
                    options: LogisticsFeature.TimeRange.allCases,
                    label: \.title
                )
                if store.yields.isEmpty {
                    RCContentUnavailableView(
                        "No Yields Yet",
                        systemImage: "shippingbox",
                        description: Text("A Haul Run's pickups appear here as they are observed.")
                    )
                } else {
                    YieldOverTimeChart(summary: summary)
                    HStack(alignment: .top, spacing: Space.m) {
                        ResourceDonutChart(title: "By Resource", rows: summary.byResource)
                        YieldBreakdownChart(
                            title: "By Source",
                            sources: summary.bySource,
                            showAll: $showAllSources
                        )
                    }
                    LazyVStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(summary.rows) { yield in
                            HaulYieldRow(yield: yield)
                        }
                    }
                }
            }
            .padding(Space.m)
        }
    }
}
