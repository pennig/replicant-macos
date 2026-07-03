//
//  MessagesFeature.swift
//  Replicould — Messages feature
//
//  The reducer behind the inbox. It refreshes messages from the API into the
//  local SQLite store, marks messages read (optimistically locally, then on the
//  server), and tracks the current selection. The list itself is observed
//  straight from the database via `@FetchAll` in the views, so any write here
//  flows back to the UI automatically.
//

import ComposableArchitecture
import Foundation
import GameModels
import SQLiteData

@Reducer
public struct MessagesFeature {
    @ObservableState
    public struct State: Equatable {
        /// The inbox, newest first — observed straight from SQLite in state so the
        /// view is a pure renderer. `@ObservationStateIgnored` because `@FetchAll`
        /// drives its own observation.
        @ObservationStateIgnored
        @FetchAll(Message.order { $0.createdAt.desc() }) public var messages: [Message]
        /// Live unread count, observed from SQLite (drives the toolbar + actions).
        @ObservationStateIgnored
        @FetchOne(Message.where { !$0.isRead }.count()) public var unreadCount = 0

        public var selectedMessageID: Message.ID?
        public var isLoading: Bool
        public var errorMessage: String?

        public init(
            selectedMessageID: Message.ID? = nil,
            isLoading: Bool = false,
            errorMessage: String? = nil
        ) {
            self.selectedMessageID = selectedMessageID
            self.isLoading = isLoading
            self.errorMessage = errorMessage
        }
    }

    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case task
        case refreshButtonTapped
        case refreshSucceeded
        case refreshFailed(String)
        case markAllReadButtonTapped
        case markReadFailed(String)
        case dismissError
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.messagesClient) var messagesClient

    public var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.selectedMessageID):
                // Opening a message marks it read — locally first for an instant
                // UI response, then on the server.
                guard let id = state.selectedMessageID else { return .none }
                let database = self.database
                let messagesClient = self.messagesClient
                return .run { _ in
                    // Only the messages that were actually unread need a server
                    // round-trip. Scrolling the list with the arrow keys reselects
                    // already-read messages, and firing `markRead` for those trips
                    // the API rate limiter.
                    let wasUnread = try await database.write { db -> Bool in
                        let message = Message.where { $0.id.eq(id) }
                        guard let current = try message.fetchOne(db), !current.isRead
                        else { return false }
                        try message.update { $0.isRead = true }.execute(db)
                        return true
                    }
                    guard wasUnread else { return }
                    try await messagesClient.markRead([id], false)
                } catch: { error, send in
                    await send(.markReadFailed(error.localizedDescription))
                }

            case .binding:
                return .none

            case .task, .refreshButtonTapped:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                let database = self.database
                let messagesClient = self.messagesClient
                return .run { send in
                    let page = try await messagesClient.fetch(nil, 50, false)
                    try await database.write { db in
                        for message in page.messages {
                            try Message.upsert { message }.execute(db)
                        }
                    }
                    await send(.refreshSucceeded)
                } catch: { error, send in
                    await send(.refreshFailed(error.localizedDescription))
                }

            case .refreshSucceeded:
                state.isLoading = false
                return .none

            case let .refreshFailed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none

            case .markAllReadButtonTapped:
                let database = self.database
                let messagesClient = self.messagesClient
                return .run { _ in
                    try await database.write { db in
                        try Message.update { $0.isRead = true }.execute(db)
                    }
                    try await messagesClient.markRead(nil, true)
                } catch: { error, send in
                    await send(.markReadFailed(error.localizedDescription))
                }

            case let .markReadFailed(message):
                state.errorMessage = message
                return .none

            case .dismissError:
                state.errorMessage = nil
                return .none
            }
        }
    }
}
