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
        List(selection: $store.selectedMessageID) {
            ForEach(store.messages) { message in
                MessageRow(message: message)
                    .tag(message.id)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
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

// MARK: - Row

private struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Circle()
                .fill(message.isRead ? Color.clear : Color.rcAccent)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(message.title)
                        .font(message.isRead ? .rcBody : .rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Space.xs)
                    Text(message.createdAt, format: .relative(presentation: .named))
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                        .fixedSize()
                }
                Text(message.body)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                    .lineLimit(2)
                // Story beats get an accent pill so they stand out from routine
                // system/achievement traffic in the inbox.
                if message.messageType == "story" {
                    Text("STORY")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcAccent)
                        .rcPill(.accent)
                } else {
                    Text(message.messageType.uppercased())
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
            }
        }
        .padding(.vertical, Space.xs)
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
                                Text("STORY")
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

                    Rectangle().fill(.rcSeparator).frame(height: 0.5)

                    Text(message.body)
                        .font(.rcBody)
                        .foregroundStyle(.rcTextPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Space.xl)
            }
            .background(.rcContentBackground)
            .navigationTitle(message.title)
        } else {
            ContentUnavailableView(
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
        let database = try! SQLiteData.defaultDatabase()
        var migrator = DatabaseMigrator()
        Message.registerMigrations(&migrator)
        try! migrator.migrate(database)
        $0.defaultDatabase = database
    }
    MessagesPreviewHarness()
        .frame(width: 820, height: 560)
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
