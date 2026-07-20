//
//  EventLogRow.swift
//  Replicould — EventLogFeature
//
//  One event in the sidebar list: the dotted event name (a designation-style code,
//  so rendered in mono) with its receipt time, the coarse category, an optional
//  scope code (device/location), and an "UNHANDLED" flag when nothing consumed it.
//
//  Kept in its own file: an inline `#Preview` beside a list-row struct can wedge
//  Xcode's preview build, so this row has no preview of its own.
//

import GameModels
import SwiftUI
import UI

struct EventLogRow: View {
    let event: EventLog

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(event.event)
                    .font(.rcBodyEmphMono)
                    .foregroundStyle(.rcTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.s)
                Text(event.receivedAt.formatted(.dateTime.hour().minute().second()))
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
            HStack(spacing: Space.s) {
                Text(event.category)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                    .lineLimit(1)
                if let scope = scopeCode {
                    Text(scope)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if !event.isHandled {
                    UnhandledFlag()
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The most specific scope code the event carries, for a mono hint on line two.
    private var scopeCode: String? {
        event.deviceCode ?? event.location ?? event.replicantCode ?? event.star
    }
}

/// A compact warning-tinted badge marking an event no feature route consumed.
private struct UnhandledFlag: View {
    var body: some View {
        Text("UNHANDLED")
            .font(.rcMicro)
            .foregroundStyle(.rcWarning)
            .padding(.vertical, 2)
            .padding(.horizontal, Space.xs)
            .background(
                .rcWarning.opacity(0.14),
                in: RoundedRectangle(cornerRadius: Radius.textBadge, style: .continuous)
            )
            .fixedSize()
    }
}
