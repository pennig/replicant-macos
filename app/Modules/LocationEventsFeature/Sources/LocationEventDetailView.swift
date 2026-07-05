//
//  LocationEventDetailView.swift
//  LocationEventsFeature
//
//  The quest sheet: the selected event's broadcast, tier/status, live per-resource
//  and per-device progress toward each fulfilment option, and the completion
//  rewards. Everything is decoded from the row's `detail` blob via
//  `LocationEvent.quest`.
//

import ComposableArchitecture
import GameModels
import SwiftUI
import UI

public struct LocationEventDetailView: View {
    let store: StoreOf<LocationEventsFeature>

    public init(store: StoreOf<LocationEventsFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if let event = store.selectedEvent {
                QuestSheet(event: event)
            } else {
                ContentUnavailableView(
                    "No Event Selected",
                    systemImage: "flag",
                    description: Text("Select an event to see its objectives and rewards.")
                )
            }
        }
    }
}

// MARK: - Quest sheet

private struct QuestSheet: View {
    let event: LocationEvent

    private var quest: LocationEventDetail? { event.quest }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header

                if let broadcast = event.broadcastMessage, !broadcast.isEmpty {
                    broadcastCard(broadcast)
                }

                if let quest {
                    ForEach(quest.options) { option in
                        objectivesCard(option, multi: quest.options.count > 1)
                    }
                    rewardsCard(quest)
                }

                if let description = event.eventDescription, !description.isEmpty {
                    RCReadoutCard("Briefing") {
                        Text(description)
                            .font(.rcBody)
                            .foregroundStyle(.rcTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.l)
        }
        .navigationTitle(event.title.isEmpty ? event.designation : event.title)
    }

    // — Header —

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(event.title.isEmpty ? event.designation : event.title)
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)
            HStack(spacing: Space.s) {
                Text(event.designation).font(.rcMono).foregroundStyle(.rcTextTertiary)
                StatusBadge(event.status, parameter: event.tier > 0 ? "Tier \(event.tier)" : nil)
            }
            HStack(spacing: Space.s) {
                Label(event.locationLabel, systemImage: "mappin.and.ellipse")
                    .font(.rcCaption).foregroundStyle(.rcTextSecondary)
                if let category = event.category, !category.isEmpty {
                    Text(category.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.rcCaption).foregroundStyle(.rcTextTertiary)
                }
            }
        }
    }

    // — Broadcast —

    private func broadcastCard(_ message: String) -> some View {
        RCReadoutCard("Broadcast") {
            Text(message)
                .font(.rcBody.italic())
                .foregroundStyle(.rcTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // — Objectives (one card per fulfilment option) —

    private func objectivesCard(_ option: LocationEventDetail.Option, multi: Bool) -> some View {
        let heading = multi ? "Objective · \(option.name.capitalized)" : "Objectives"
        return RCReadoutCard(heading) {
            ForEach(option.resources) { req in
                RequirementRow(
                    label: req.resourceType.replacingOccurrences(of: "_", with: " ").capitalized,
                    current: req.current, required: req.required, met: req.met, fraction: req.fraction
                )
            }
            ForEach(option.devices) { req in
                RequirementRow(
                    label: req.deviceType.replacingOccurrences(of: "_", with: " ").capitalized,
                    current: req.current, required: req.required, met: req.met, fraction: req.fraction
                )
            }
            if option.resources.isEmpty && option.devices.isEmpty {
                Text("No delivery required.").font(.rcCaption).foregroundStyle(.rcTextTertiary)
            }
        }
    }

    // — Rewards —

    private func rewardsCard(_ quest: LocationEventDetail) -> some View {
        RCReadoutCard("Rewards") {
            if let xp = quest.experiencePoints {
                RewardRow(label: "Experience", value: "\(xp.formatted()) XP")
            }
            ForEach(quest.rewardResources) { reward in
                RewardRow(
                    label: reward.resourceType.replacingOccurrences(of: "_", with: " ").capitalized,
                    value: reward.amount.formatted()
                )
            }
            if let civ = quest.civilisationPoints {
                RewardRow(label: "Civilisation", value: "+\(civ)")
            }
            if let achievement = quest.completionAchievement, !achievement.isEmpty {
                RewardRow(
                    label: "Achievement",
                    value: achievement.replacingOccurrences(of: "_", with: " ").capitalized
                )
            }
        }
    }
}

// MARK: - Rows

/// One requirement line: label, current/required readout, and a meter bar. A met
/// requirement reads in the accent tint with a check.
private struct RequirementRow: View {
    let label: String
    let current: Int
    let required: Int
    let met: Bool
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                if met {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.rcAccent)
                }
                Text(label).font(.rcBody).foregroundStyle(.rcTextSecondary)
                Spacer()
                Text("\(current.formatted()) / \(required.formatted())")
                    .font(.rcMono)
                    .foregroundStyle(met ? .rcAccent : .rcTextPrimary)
            }
            RCMeterBar(fraction: fraction)
        }
    }
}

private struct RewardRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.rcBody).foregroundStyle(.rcTextSecondary)
            Spacer()
            Text(value).font(.rcBodyEmph).foregroundStyle(.rcTextPrimary)
        }
    }
}
