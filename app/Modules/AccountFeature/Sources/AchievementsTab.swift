//
//  AchievementsTab.swift
//  Replicould — Account feature
//
//  Every achievement, earned or locked, grouped by category. Merges the player's
//  earned set with the global catalog (so locked ones show too, with galaxy-wide
//  player counts). Loaded on appear via the store.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

struct AchievementsTab: View {
    let store: StoreOf<AccountFeature>

    var body: some View {
        Group {
            if store.isLoadingAchievements, store.achievements.isEmpty {
                ProgressView("Loading achievements…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.achievements.isEmpty {
                ContentUnavailableView {
                    Label("No Achievements", systemImage: "trophy")
                } description: {
                    Text(store.achievementsError ?? "Nothing to show yet.")
                }
            } else {
                List {
                    ForEach(groups, id: \.category) { group in
                        Section {
                            ForEach(group.items) { achievement in
                                AchievementRow(achievement: achievement)
                            }
                        } header: {
                            HStack {
                                Text(displayName(group.category))
                                Spacer()
                                Text("\(group.earnedCount)/\(group.items.count)")
                                    .font(.rcMonoSmall)
                                    .foregroundStyle(.rcTextTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Achievements grouped by category (alphabetical), earned first within each.
    private var groups: [CategoryGroup] {
        let byCategory = Dictionary(grouping: store.achievements, by: \.category)
        return byCategory.keys.sorted().map { category in
            let items = (byCategory[category] ?? []).sorted { lhs, rhs in
                if lhs.isEarned != rhs.isEarned { return lhs.isEarned }
                return lhs.title < rhs.title
            }
            return CategoryGroup(
                category: category,
                items: items,
                earnedCount: items.filter(\.isEarned).count
            )
        }
    }

    private func displayName(_ category: String) -> String {
        category.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// A category and its achievements, for one `List` section.
    private struct CategoryGroup {
        var category: String
        var items: [Achievement]
        var earnedCount: Int
    }
}
