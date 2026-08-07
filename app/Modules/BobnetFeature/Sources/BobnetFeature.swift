//
//  BobnetFeature.swift
//  Replicould — Bobnet feature
//
//  The reducer behind the Bobnet panes. Channels + messages are observed
//  straight from SQLite (the SSE route keeps `BobnetMessage` warm); an active
//  FTL relay fills gaps on appearance (channel directory + forward-cursor
//  catch-up). Read markers advance after a 3-second linger at the newest
//  message, or on send. With no relaying relay, the feature is read-only over
//  stored history and the UI says so.
//

import ComposableArchitecture
import Foundation
import GameModels
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "name.pennig.replicould", category: "BobnetFeature")

@Reducer
public struct BobnetFeature {
    /// One draft of the "New Channel" sheet (a plain value, per the
    /// presentation dialect — `.sheet(item:)` with a dismiss-sending binding).
    public struct NewChannelDraft: Equatable, Identifiable, Sendable {
        public var name: String = ""
        public var firstMessage: String = ""
        /// One sheet at a time — a stable identity is all `.sheet(item:)` needs.
        public var id: String { "new-channel" }
        public init() {}
    }

    @ObservableState
    public struct State: Equatable {
        /// Every known channel with activity + unread state, observed from
        /// SQLite. `@ObservationStateIgnored` because `@Fetch` drives its own
        /// observation.
        @ObservationStateIgnored
        @Fetch(BobnetChannelList()) public var channelList = BobnetChannelList.Value()
        /// The relay roster, observed live so the no-relay state flips itself
        /// when a relay (de)activates. Status filtering happens in
        /// `activeRelayCode` (statusBase is computed, not a column).
        @ObservationStateIgnored
        @FetchAll(Device.where { $0.deviceType.eq("ftl_relay") }) public var relays: [Device]
        /// The selected channel's messages, oldest first; reloaded (new request
        /// instance) whenever the selection changes.
        @ObservationStateIgnored
        @Fetch(BobnetChannelMessages(channel: nil, marker: 0)) public var channelMessages = BobnetChannelMessages.Value()

        public var selectedChannel: String?
        /// The read-marker snapshot for the *current selection*, set
        /// synchronously so the channel list highlights instantly. Compare
        /// `channelMessages.marker`, the snapshot the *rendered* messages loaded with.
        public var markerAtSelection: Int = 0
        /// Whether the detail view is showing the newest message: geometry's
        /// truth, established on selection and on the pane appearing (both render
        /// pinned to the bottom) and thereafter only maintained by its reports.
        public var isAtLatest: Bool = false
        /// Messages that landed while the reader was away from the bottom.
        /// Zeroed wherever the view is known to be pinned to the newest message.
        public var newWhileAway: Int = 0
        /// Bumped to ask the view to scroll to the bottom.
        public var scrollToBottomToken: Int = 0
        /// A bottom-scroll was requested and has not been observed to land. It
        /// masks `isAtLatest`: OR-ed with it wherever "effectively at the newest
        /// message" is the question.
        public var pendingBottomScroll: Bool = false
        public var composeText: String = ""
        public var newChannelDraft: NewChannelDraft?
        public var isCatchingUp: Bool = false
        public var isSending: Bool = false
        public var errorMessage: String?

        @ObservationStateIgnored
        @Shared(.appStorage(Account.activeReplicantCodeKey)) public var activeReplicantCode: String?

        /// The relay to read from: the first relaying `ftl_relay` by device
        /// code, for determinism. Nil → Bobnet is offline (stored history only).
        public var activeRelayCode: String? {
            relays
                .filter { $0.statusBase == "relaying" }
                .map(\.deviceCode)
                .sorted()
                .first
        }

        /// True when sending is possible: an active relay and a replicant to
        /// speak as.
        public var canSend: Bool {
            activeRelayCode != nil && activeReplicantCode != nil
        }

        public init() {}
    }

    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case task
        case refreshButtonTapped
        case catchUpFinished
        case catchUpFailed(String)
        /// The newest message in the selected channel changed (view-reported) —
        /// re-arm the linger window.
        case latestMessageChanged
        /// The 3-second linger at the newest message elapsed — mark read.
        case lingerElapsed
        /// The detail view's scrolling content (identified by the channel it
        /// was rendering) disappeared — tears the linger down if that
        /// identity is still the current selection (a true pane departure,
        /// not a stale intra-pane channel switch).
        case detailDisappeared(String?)
        /// The detail view's scrolling content (identified by the channel it is
        /// rendering) appeared — re-establishes the at-latest flag.
        case detailAppeared(String?)
        /// The jump-to-latest affordance was tapped.
        case jumpToLatestTapped
        /// The bottom-scroll mask window closed without the scroll being
        /// observed to land. Carries the `scrollToBottomToken` that armed it;
        /// any other value is an escaped expiry from a closed window.
        case pendingScrollExpired(Int)
        case sendButtonTapped
        /// The channel a send was posted to, captured at dispatch — the
        /// selection can have moved on by the time this lands.
        case sendSucceeded(String)
        case sendFailed(String)
        case newChannelButtonTapped
        case newChannelDismissed
        case newChannelSubmitted
        case channelCreated(String)
        case dismissError
    }

    public init() {}

    @Dependency(\.defaultDatabase) var database
    @Dependency(\.bobnetClient) var bobnetClient
    @Dependency(\.continuousClock) var clock

    private enum CancelID { case linger, pendingScroll }

    public var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.selectedChannel):
                return selectionChanged(&state)

            case .binding(\.isAtLatest):
                if state.isAtLatest {
                    state.newWhileAway = 0
                    state.pendingBottomScroll = false
                    return .merge(
                        .cancel(id: CancelID.pendingScroll),
                        reevaluateLinger(state)
                    )
                }
                return reevaluateLinger(state)

            case .binding:
                return .none

            case .task, .refreshButtonTapped:
                guard !state.isCatchingUp, let relay = state.activeRelayCode else { return .none }
                state.isCatchingUp = true
                state.errorMessage = nil
                let database = self.database
                let bobnetClient = self.bobnetClient
                return .run { send in
                    // Channel directory → upsert, preserving read markers.
                    let directory = try await bobnetClient.channels(relay)
                    try await database.write { db in
                        for info in directory {
                            var row = try BobnetChannel
                                .where { $0.name.eq(info.name) }.fetchOne(db)
                                ?? BobnetChannel(name: info.name, lastActive: nil, lastReadMessageID: 0)
                            row.lastActive = info.lastActive
                            try BobnetChannel.upsert { row }.execute(db)
                        }
                    }

                    // History catch-up: forward walk from the local max id, or
                    // a latest-page seed when the table is empty.
                    let maxLocalID = try await database.read { db in
                        try BobnetMessage.all.fetchAll(db).map(\.id).max()
                    }
                    if var cursor = maxLocalID {
                        var pages = 0
                        while pages < 5 {
                            let page = try await bobnetClient.messages(relay, cursor, 100, false)
                            guard !page.messages.isEmpty else { break }
                            try await database.write { db in
                                for message in page.messages {
                                    try BobnetMessage.upsert { message }.execute(db)
                                }
                            }
                            pages += 1
                            guard page.messages.count >= 100, let next = page.nextCursor else { break }
                            cursor = next
                        }
                        if pages == 5 {
                            logger.info("catch-up truncated at 5 pages; older gap remains")
                        }
                    } else {
                        let page = try await bobnetClient.messages(relay, nil, 100, true)
                        try await database.write { db in
                            for message in page.messages {
                                try BobnetMessage.upsert { message }.execute(db)
                            }
                        }
                    }
                    await send(.catchUpFinished)
                } catch: { error, send in
                    await send(.catchUpFailed(error.localizedDescription))
                }

            case .catchUpFinished:
                state.isCatchingUp = false
                return .none

            case let .catchUpFailed(message):
                state.isCatchingUp = false
                state.errorMessage = message
                return .none

            case .latestMessageChanged:
                guard state.isAtLatest || state.pendingBottomScroll else {
                    state.newWhileAway += 1
                    return reevaluateLinger(state)
                }
                let scroll = requestBottomScroll(&state)
                return .merge(scroll, reevaluateLinger(state))

            case .lingerElapsed:
                // Re-check the arming conditions rather than trusting that a
                // cancellation took. `.cancel(id:)` cannot cancel an effect whose
                // task has not yet registered its token, so a linger armed and
                // cancelled microseconds apart still fires — observed in the wild,
                // marking a channel read while the user scrolled *away* from the
                // bottom. Cancellation is the optimisation; this guard is the rule.
                guard let channel = lingerableChannel(state) else { return .none }
                let database = self.database
                return .run { _ in
                    try await database.write { db in
                        let maxID = try BobnetMessage
                            .where { $0.channel.eq(channel) }
                            .fetchAll(db).map(\.id).max() ?? 0
                        try BobnetReadMarker.advance(db, channel: channel, to: maxID)
                    }
                } catch: { error, _ in
                    // Without this the write threw into a discarded effect and the
                    // marker silently never moved.
                    logger.error("read-marker write failed for \(channel, privacy: .public): \(error)")
                }

            case let .detailAppeared(channel):
                // Re-entering the pane rebuilds the scroll view at the bottom,
                // but delivers no geometry *change* — so the flag `.detailDisappeared`
                // cleared on the way out has to be re-established here, or the
                // linger can never re-arm. Stale identities from a channel switch
                // are ignored, mirroring `.detailDisappeared`.
                guard channel == state.selectedChannel else { return .none }
                state.isAtLatest = true
                state.newWhileAway = 0
                state.pendingBottomScroll = false
                return reevaluateLinger(state)

            case let .detailDisappeared(channel):
                // Stale identities from an intra-pane channel switch (the old `.id`'s
                // onDisappear can fire after the new channel is already selected) must
                // not clobber the new channel's linger — only a true pane departure
                // (the disappearing identity is still the selection) tears down.
                guard channel == state.selectedChannel else { return .none }
                state.isAtLatest = false
                state.newWhileAway = 0
                state.pendingBottomScroll = false
                return .merge(
                    .cancel(id: CancelID.linger),
                    .cancel(id: CancelID.pendingScroll)
                )

            case .jumpToLatestTapped:
                state.newWhileAway = 0
                let scroll = requestBottomScroll(&state)
                return .merge(scroll, reevaluateLinger(state))

            case let .pendingScrollExpired(token):
                // Dropping the mask can change lingerability, so re-test it here.
                guard token == state.scrollToBottomToken, state.pendingBottomScroll
                else { return .none }
                state.pendingBottomScroll = false
                return reevaluateLinger(state)

            case .sendButtonTapped:
                let text = state.composeText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !state.isSending,
                      let channel = state.selectedChannel,
                      state.activeRelayCode != nil,
                      let replicant = state.activeReplicantCode
                else { return .none }
                state.isSending = true
                return sendMessage(channel: channel, text: text, as: replicant) { .sendSucceeded(channel) }

            case let .sendSucceeded(channel):
                state.isSending = false
                // A stale identity (switched channels mid-send) must not force
                // latest/scroll onto the channel now showing, nor wipe its draft.
                guard channel == state.selectedChannel else { return .none }
                state.composeText = ""
                state.newWhileAway = 0
                let scroll = requestBottomScroll(&state)
                return .merge(scroll, reevaluateLinger(state))

            case let .sendFailed(message):
                state.isSending = false
                state.errorMessage = message
                return .none

            case .newChannelButtonTapped:
                guard state.canSend else { return .none }
                state.newChannelDraft = NewChannelDraft()
                return .none

            case .newChannelDismissed:
                state.newChannelDraft = nil
                return .none

            case .newChannelSubmitted:
                guard let draft = state.newChannelDraft, !state.isSending,
                      let name = BobnetChannelName.normalize(draft.name),
                      let replicant = state.activeReplicantCode,
                      state.activeRelayCode != nil
                else { return .none }
                let text = draft.firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return .none }
                state.isSending = true
                return sendMessage(channel: name, text: text, as: replicant) { .channelCreated(name) }

            case let .channelCreated(name):
                state.isSending = false
                state.newChannelDraft = nil
                state.selectedChannel = name
                return selectionChanged(&state)

            case .dismissError:
                state.errorMessage = nil
                return .none
            }
        }
    }

    /// Selection housekeeping: snapshot the divider marker, reload the detail
    /// query, re-arm the linger, and *establish* `isAtLatest` — the new channel
    /// renders at its newest message, and geometry only maintains that.
    private func selectionChanged(_ state: inout State) -> Effect<Action> {
        let channel = state.selectedChannel
        let marker = state.channelList.rows
            .first { $0.name == channel }?.lastReadMessageID ?? 0
        state.markerAtSelection = marker
        state.isAtLatest = channel != nil
        state.newWhileAway = 0
        state.pendingBottomScroll = false
        return .merge(
            reevaluateLinger(state),
            .cancel(id: CancelID.pendingScroll),
            .run { [fetch = state.$channelMessages] _ in
                _ = try? await fetch.load(BobnetChannelMessages(channel: channel, marker: marker))
            }
        )
    }

    /// The channel whose read marker the linger may advance: a selection,
    /// effectively at the newest message, with something unread. Shared by arming
    /// and firing — the conditions must hold at *both* ends of the window.
    private func lingerableChannel(_ state: State) -> String? {
        guard let channel = state.selectedChannel,
              state.isAtLatest || state.pendingBottomScroll,
              let row = state.channelList.rows.first(where: { $0.name == channel }),
              row.latestMessageID > row.lastReadMessageID
        else { return nil }
        return channel
    }

    /// Ask the view to scroll to the bottom, masking "effectively at latest"
    /// until it lands or 250 ms passes.
    private func requestBottomScroll(_ state: inout State) -> Effect<Action> {
        state.scrollToBottomToken += 1
        state.pendingBottomScroll = true
        let token = state.scrollToBottomToken
        let clock = self.clock
        return .run { send in
            try await clock.sleep(for: .milliseconds(250))
            await send(.pendingScrollExpired(token))
        }
        .cancellable(id: CancelID.pendingScroll, cancelInFlight: true)
    }

    /// (Re)arm or cancel the 3-second read-marker linger. `cancelInFlight`
    /// restarts the window when a new message arrives mid-linger.
    private func reevaluateLinger(_ state: State) -> Effect<Action> {
        guard lingerableChannel(state) != nil else { return .cancel(id: CancelID.linger) }
        let clock = self.clock
        return .run { send in
            try await clock.sleep(for: .seconds(3))
            await send(.lingerElapsed)
        }
        .cancellable(id: CancelID.linger, cancelInFlight: true)
    }

    /// Send `text` to `channel` as `replicant`: persist the echoed message,
    /// advance the read marker past it (the sender has read their own message),
    /// then emit `success()`.
    private func sendMessage(
        channel: String, text: String, as replicant: String,
        success: @escaping @Sendable () -> Action
    ) -> Effect<Action> {
        let database = self.database
        let bobnetClient = self.bobnetClient
        return .run { send in
            let message = try await bobnetClient.send(replicant, channel, text)
            try await database.write { db in
                try BobnetMessage.upsert { message }.execute(db)
                try BobnetReadMarker.advance(db, channel: channel, to: message.id)
            }
            await send(success())
        } catch: { error, send in
            await send(.sendFailed(error.localizedDescription))
        }
    }
}

/// Channel-name normalization for the New Channel sheet. Plain namespace —
/// testable without SwiftUI.
enum BobnetChannelName {
    /// Trim, require non-empty and space-free, and ensure the IRC `#` prefix.
    /// Returns nil for names that can't be normalized.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let named = trimmed.hasPrefix("#") ? trimmed : "#" + trimmed
        guard named.count > 1 else { return nil }
        return named
    }
}
