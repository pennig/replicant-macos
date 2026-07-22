//
//  NewChannelSheet.swift
//  Replicould — Bobnet feature
//
//  The "New Channel" sheet: a channel-name field (mono — it's a designation code)
//  and a first-message field. Create is enabled only for a normalizable name and
//  a non-empty message, and sends the first message (which creates the channel
//  server-side). Presented via the plain-value dialect — `.sheet(item:)` with a
//  dismiss-sending binding — from `BobnetChannelsView`.
//

import ComposableArchitecture
import SwiftUI
import UI

public struct NewChannelSheet: View {
    @Bindable var store: StoreOf<BobnetFeature>

    public init(store: StoreOf<BobnetFeature>) {
        self.store = store
    }

    /// Whether the current draft can be submitted: a normalizable channel name
    /// and a non-empty first message.
    private var canCreate: Bool {
        guard let draft = store.newChannelDraft else { return false }
        return BobnetChannelName.normalize(draft.name) != nil
            && !draft.firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.s) {
                Image(systemName: SidebarSymbol.bobnet)
                    .font(.system(size: IconSize.l))
                    .foregroundStyle(.rcAccent)
                Text("New Channel")
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
            }

            if let draft = Binding($store.newChannelDraft) {
                RCField(
                    "Channel",
                    text: draft.name,
                    placeholder: "#general",
                    hint: "a # channel name, no spaces",
                    mono: true
                )
                RCField(
                    "First message",
                    text: draft.firstMessage,
                    placeholder: "Say something…"
                )
            }

            HStack(spacing: Space.s) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    store.send(.newChannelDismissed)
                }
                .buttonStyle(RCButtonStyle(.secondary))

                Button("Create") {
                    store.send(.newChannelSubmitted)
                }
                .buttonStyle(RCButtonStyle(.primary))
                .disabled(!canCreate || store.isSending)
            }
        }
        .padding(Space.xl)
        .frame(width: 380)
        .background(.rcContentBackground)
    }
}
