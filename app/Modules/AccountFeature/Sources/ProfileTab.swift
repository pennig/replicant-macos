//
//  ProfileTab.swift
//  Replicould — Account feature
//
//  Read-only account identity: name, email (+ verification), status, membership,
//  experience, replicant count, the session API key, and Log Out. Editing lives
//  on the Settings tab.
//

import ComposableArchitecture
import SwiftUI
import UI

struct ProfileTab: View {
    let store: StoreOf<AccountFeature>
    /// Dismiss the sheet before bubbling logout (mirrors the old sidebar path).
    let dismiss: () -> Void

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("Name", value: store.account.name)
                LabeledContent("Email") {
                    HStack(spacing: Space.xs) {
                        Text(store.account.email)
                        if store.account.emailVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.rcSuccess)
                                .help("Verified")
                        } else {
                            Text("unverified")
                                .font(.rcCaption)
                                .foregroundStyle(.rcWarning)
                        }
                    }
                }
                if !store.account.status.isEmpty {
                    LabeledContent("Status", value: store.account.status.capitalized)
                }
                if let memberSince {
                    LabeledContent("Member since", value: memberSince)
                }
                LabeledContent("Experience", value: "\(store.account.experiencePointsTotal) XP")
                LabeledContent("Replicants", value: "\(store.replicants.count)")
            }

            Section("API Key") {
                Text(store.apiKey)
                    .font(.rcMono)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Section {
                Button("Log Out", role: .destructive) {
                    dismiss()
                    store.send(.logoutButtonTapped)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `created_at` arrives as an ISO-8601 string; render it as a medium date, or
    /// nil (row hidden) when it's absent or unparseable.
    private var memberSince: String? {
        let raw = store.account.createdAt
        guard !raw.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: raw) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
