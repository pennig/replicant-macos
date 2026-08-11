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

    public init(store: StoreOf<LogisticsFeature>) {
        self.store = store
    }

    public var body: some View {
        let summary = store.summary
        ScrollView {
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
                        YieldBreakdownChart(
                            title: "By Resource",
                            rows: summary.byResource.map { ($0.key.capitalized, $0.units) },
                            monospacedLabels: false
                        )
                        YieldBreakdownChart(
                            title: "By Source",
                            rows: summary.bySource.map { ($0.designation, $0.units) },
                            monospacedLabels: true
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
        .navigationTitle("Logistics")
    }
}
