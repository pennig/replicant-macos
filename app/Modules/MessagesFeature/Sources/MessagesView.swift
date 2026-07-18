//
//  MessagesView.swift
//  Replicould — Messages feature
//
//  The inbox UI: a master list (`MessagesListView`) for the split view's content
//  column and a reader (`MessageDetailView`) for the detail column. Both observe
//  the persisted messages directly via `@FetchAll`, while the shared store drives
//  selection, refresh, and read-state actions.
//

import ComposableArchitecture
import GameDatabase
import GameModels
import SQLiteData
import SwiftUI
import UI

// MARK: - Master list

public struct MessagesListView: View {
    @Bindable var store: StoreOf<MessagesFeature>

    public init(store: StoreOf<MessagesFeature>) {
        self.store = store
    }

    public var body: some View {
        SelectableList(
            store.messages,
            id: \.id,
            selection: $store.selectedMessageID,
            style: .inline
        ) { message, isSelected in
            MessageRow(message: message).rcSidebarRow(isSelected: isSelected)
        }
        .background(.rcContentBackground)
        .overlay {
            if store.messages.isEmpty {
                if store.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "Inbox Empty",
                        systemImage: SidebarSymbol.messages,
                        description: Text("Messages from the network will appear here.")
                    )
                }
            }
        }
        .navigationTitle("Messages")
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage {
                RCErrorBanner(errorMessage) { store.send(.dismissError) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if store.unreadCount > 0 {
                    Text("\(store.unreadCount) unread")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                        .padding(.horizontal, Space.m)
                }
            }
            ToolbarItemGroup {
                Button {
                    store.send(.markAllReadButtonTapped)
                } label: {
                    Image(systemName: "envelope.open")
                }
                .help("Mark all as read")
                .disabled(store.unreadCount == 0)

                Button {
                    store.send(.refreshButtonTapped)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(store.isLoading)
            }
        }
        .task { store.send(.task) }
    }

}

// MARK: - Detail / reader

public struct MessageDetailView: View {
    let store: StoreOf<MessagesFeature>

    public init(store: StoreOf<MessagesFeature>) {
        self.store = store
    }

    private var selected: Message? {
        guard let id = store.selectedMessageID else { return nil }
        return store.messages.first { $0.id == id }
    }

    /// Builds an `AttributedString` from the message body with any detected URLs
    /// turned into tappable links.
    private func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else {
            return attributed
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard
                let url = match.url,
                let attrRange = Range(match.range, in: attributed)
            else { continue }
            attributed[attrRange].link = url
        }
        return attributed
    }

    public var body: some View {
        if let message = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text(message.title)
                            .font(.rcTitle)
                            .foregroundStyle(.rcTextPrimary)
                        HStack(spacing: Space.s) {
                            if message.messageType == "story" {
                                Text(message.messageType.uppercased())
                                    .font(.rcMonoSmall)
                                    .foregroundStyle(.rcAccent)
                                    .rcPill(.accent)
                            } else {
                                Text(message.messageType.uppercased())
                                    .font(.rcMonoSmall)
                                    .foregroundStyle(.rcAccent)
                            }
                            Text("·")
                                .foregroundStyle(.rcTextTertiary)
                            Text(message.createdAt, format: .dateTime.month().day().year().hour().minute())
                                .font(.rcCaption)
                                .foregroundStyle(.rcTextTertiary)
                        }
                    }

                    Divider().overlay(.rcSeparator)

                    Text(linkified(message.body))
                        .font(.rcBody)
                        .foregroundStyle(.rcTextPrimary)
                        .tint(.rcAccent)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Space.xl)
            }
            .background(.rcContentBackground)
            .navigationTitle(message.title)
        } else {
            RCContentUnavailableView(
                "No Message Selected",
                systemImage: "envelope",
                description: Text("Select a message to read it.")
            )
        }
    }
}

// MARK: - Previews

#Preview("Inbox") {
    let _ = prepareDependencies {
        try! $0.bootstrapDatabase { db in
            try db.seed { Message.previewInbox }
        }
    }
    MessagesPreviewHarness()
        .frame(width: 820, height: 560)
}
#Preview("Detail") {
    let _ = prepareDependencies {
        try! $0.bootstrapDatabase { db in
            try db.seed { Message.previewInbox }
        }
    }
    MessageDetailView(
        store: Store(
            initialState: MessagesFeature.State(selectedMessageID: Message.previewInbox[0].id)
        ) {
            MessagesFeature()
        }
    )
    .frame(width: 560, height: 560)
}

private struct MessagesPreviewHarness: View {
    @State private var store = Store(initialState: MessagesFeature.State()) {
        MessagesFeature()
    }
    
    var body: some View {
        NavigationSplitView {
            List { Label("Messages", systemImage: SidebarSymbol.messages) }
                .navigationSplitViewColumnWidth(180)
        } content: {
            MessagesListView(store: store)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            MessageDetailView(store: store)
        }
    }
}
