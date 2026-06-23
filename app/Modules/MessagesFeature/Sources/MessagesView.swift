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
import SQLiteData
import SwiftUI
import UI

// MARK: - Master list

public struct MessagesListView: View {
    @Bindable var store: StoreOf<MessagesFeature>
    @FetchAll(Message.order { $0.createdAt.desc() }) private var messages
    @FetchOne(Message.where { !$0.isRead }.count()) private var unreadCount = 0

    public init(store: StoreOf<MessagesFeature>) {
        self.store = store
    }

    public var body: some View {
        List(selection: $store.selectedMessageID) {
            ForEach(messages) { message in
                MessageRow(message: message)
                    .tag(message.id)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .overlay {
            if messages.isEmpty {
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
                errorBanner(errorMessage)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if unreadCount > 0 {
                    Text("\(unreadCount) unread")
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
                .disabled(unreadCount == 0)

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

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.rcWarning)
            Text(message)
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
                .lineLimit(2)
            Spacer(minLength: Space.s)
            Button("Dismiss") { store.send(.dismissError) }
                .buttonStyle(RCButtonStyle(.text))
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(.rcSurfaceRaised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.rcSeparator).frame(height: 0.5)
        }
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
                Text(message.messageType.uppercased())
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
        .padding(.vertical, Space.xs)
    }
}

// MARK: - Detail / reader

public struct MessageDetailView: View {
    let store: StoreOf<MessagesFeature>
    @FetchAll(Message.order { $0.createdAt.desc() }) private var messages

    public init(store: StoreOf<MessagesFeature>) {
        self.store = store
    }

    private var selected: Message? {
        guard let id = store.selectedMessageID else { return nil }
        return messages.first { $0.id == id }
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
                            Text(message.messageType.uppercased())
                                .font(.rcMonoSmall)
                                .foregroundStyle(.rcAccent)
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
    let _ = prepareDependencies { try? $0.bootstrapDatabase() }
    MessagesPreviewHarness()
        .frame(width: 820, height: 560)
}

private struct MessagesPreviewHarness: View {
    @State private var store = Store(initialState: MessagesFeature.State(apiKey: "preview")) {
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
