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
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                RCSectionHeader("Haul Yields")
                YieldKPIRow(summary: store.summary)
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
                    YieldOverTimeChart(summary: store.summary)
                    HStack(alignment: .top, spacing: Space.m) {
                        YieldBreakdownChart(
                            title: "By Resource",
                            rows: store.summary.byResource.map { ($0.key.capitalized, $0.units) },
                            monospacedLabels: false
                        )
                        YieldBreakdownChart(
                            title: "By Source",
                            rows: store.summary.bySource.map { ($0.designation, $0.units) },
                            monospacedLabels: true
                        )
                    }
                    List {
                        ForEach(store.yields) { yield in
                            HaulYieldRow(yield: yield)
                        }
                    }
                    .scrollDisabled(true)
                    .rcListStyle()
                }
            }
            .padding(Space.m)
        }
        .navigationTitle("Logistics")
    }
}

// Only caller of this List treatment; promote to UI/ListStyles.swift if a
// second one appears.
private extension View {
    func rcListStyle() -> some View {
        listStyle(.plain).scrollContentBackground(.hidden)
    }
}
