//
//  AchievementRow.swift
//  Replicould — Account feature
//
//  One achievement row: a trophy/lock glyph, title + description, galaxy-wide
//  player count, and a trailing XP + earned-date / Locked readout. Locked rows
//  read dimmer. (Kept in its own file, away from any `#Preview`, per the List
//  preview-crash gotcha.)
//

import GameModels
import SwiftUI
import UI

struct AchievementRow: View {
    let achievement: Achievement

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: achievement.isEarned ? "trophy.fill" : "lock.fill")
                .font(.rcHeadline)
                .foregroundStyle(achievement.isEarned ? .rcAccent : .rcTextTertiary)
                .frame(width: TileSize.small)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(achievement.title)
                    .font(.rcBodyEmph)
                    .foregroundStyle(achievement.isEarned ? .rcTextPrimary : .rcTextSecondary)
                Text(achievement.summary)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let playerCount = achievement.playerCount {
                    Text("\(playerCount) \(playerCount == 1 ? "player" : "players") galaxy-wide")
                        .font(.rcMicro)
                        .foregroundStyle(.rcTextTertiary)
                }
            }

            Spacer(minLength: Space.s)

            VStack(alignment: .trailing, spacing: Space.xs) {
                Text("\(achievement.xpReward) XP")
                    .font(.rcMonoSmall)
                    .foregroundStyle(achievement.isEarned ? .rcAccent : .rcTextTertiary)
                if achievement.isEarned {
                    if let date = achievement.achievedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.rcMicro)
                            .foregroundStyle(.rcTextTertiary)
                    }
                } else {
                    Text("Locked")
                        .font(.rcMicro)
                        .foregroundStyle(.rcTextTertiary)
                }
            }
        }
        .padding(.vertical, Space.xs)
        .opacity(achievement.isEarned ? 1 : 0.7)
    }
}
