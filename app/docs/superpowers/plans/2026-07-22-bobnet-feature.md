# Bobnet Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract Bobnet from DevicesFeature into a new `BobnetFeature` TCA module: a 3-panel channels/messages experience with sending, channel creation, per-channel read markers (3-second linger rule), and FTL-relay catch-up, per `app/docs/superpowers/specs/2026-07-22-bobnet-feature-design.md`.

**Architecture:** Local-first over the existing `BobnetMessage` SQLite table (kept warm by GameSync's SSE route). A new `BobnetChannel` table stores per-channel read markers + relay-reported activity. A thin `BobnetClient` wraps three generated OpenAPI operations. The reducer owns selection, catch-up, linger read-marking, send, and channel creation.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26), TCA (`@Reducer`/`@ObservableState`), SQLiteData (`@Table`, `@Fetch`/`@FetchAll`, `FetchKeyRequest`), swift-openapi-generator client via `@Dependency(\.gameClient)`, Swift Testing (`@Suite`/`@Test`/`#expect`).

## Global Constraints

- Working directory for all commands: `app/Modules` (the SPM package root; also the LSP root).
- Verify with Swift-LSP (goToDefinition/findReferences/hover) before signing off on any task — LSP output over text matching.
- Design tokens only — no hard-coded colors/spacing/fonts. Fonts: `.rcBody`, `.rcBodyEmph`, `.rcMonoSmall`, etc.; colors `.rcTextPrimary/.rcTextSecondary/.rcTextTertiary/.rcAccent`; spacing `Space.xs/s/m`.
- Logging: `os.Logger`, subsystem `name.pennig.replicould`, category `"BobnetFeature"`.
- Loud test defaults: `testValue` closures use `unimplemented(...)`.
- List-row structs and `#Preview`s live in separate files (Xcode 26 preview JIT crash).
- Pure logic lives in SwiftUI-free namespaces (statics-on-View trap under `swift test`).
- Plain-value sheets use a presentation optional + `.sheet(item:)` whose binding setter sends dismiss.
- Commits go to the current worktree branch (`worktree-bobnet-feature`); no PRs, no origin.
- `swift test` from `app/Modules` runs the package suites; keep them green at every commit.

---

### Task 1: `BobnetChannel` table (GameModels) + schema registration

**Files:**
- Create: `app/Modules/GameModels/Sources/BobnetChannel.swift`
- Modify: `app/Modules/GameDatabase/Sources/GameDatabase.swift` (add one `registerMigrations` line after `BobnetMessage.registerMigrations(&migrator)`)

**Interfaces:**
- Produces: `BobnetChannel(name: String, lastActive: Date?, lastReadMessageID: Int)`, `@Table` with `name` as TEXT primary key; `BobnetChannel.registerMigrations(_:)`.

- [ ] **Step 1: Write the model + migration** (`BobnetChannel.swift`):

```swift
//
//  BobnetChannel.swift
//  Replicould — shared game models
//
//  A Bobnet channel's local bookkeeping: the relay-reported last-activity
//  timestamp and this account's per-channel read marker. Rows are created by
//  relay channel-directory syncs, by channel creation, and lazily by the first
//  read-marker write — a channel known only from streamed messages appears in
//  the UI via the channel-list merge even before a row exists here.
//

import Foundation
import SQLiteData

@Table
public struct BobnetChannel: Identifiable, Equatable, Sendable {
    /// Channel name (IRC-style, e.g. `#general`) — the natural primary key.
    @Column(primaryKey: true) public var name: String
    /// Last message activity as reported by a relay's channel directory.
    public var lastActive: Date?
    /// Highest message `id` this account has read in the channel. 0 = nothing read.
    public var lastReadMessageID: Int

    public var id: String { name }

    public init(name: String, lastActive: Date?, lastReadMessageID: Int) {
        self.name = name
        self.lastActive = lastActive
        self.lastReadMessageID = lastReadMessageID
    }
}

// MARK: - Schema

extension BobnetChannel {
    /// Registers the `bobnetChannels` table migration. Composed into the app's
    /// `bootstrapDatabase` alongside other tables.
    public static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create 'bobnetChannels' table") { db in
            try #sql(
                """
                CREATE TABLE "bobnetChannels" (
                  "name" TEXT PRIMARY KEY NOT NULL,
                  "lastActive" TEXT,
                  "lastReadMessageID" INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """
            )
            .execute(db)
        }
    }
}
```

- [ ] **Step 2: Register it in `GameDatabase.migrator()`** — insert directly after the `BobnetMessage.registerMigrations(&migrator)` line:

```swift
        BobnetChannel.registerMigrations(&migrator)
```

- [ ] **Step 3: Build + run existing tests**

Run: `swift build && swift test 2>&1 | tail -5` (from `app/Modules`)
Expected: build succeeds; all existing suites pass (DEBUG `eraseDatabaseOnSchemaChange` absorbs the schema change; direct table tests come with Task 3).

- [ ] **Step 4: Commit**

```bash
git add GameModels/Sources/BobnetChannel.swift GameDatabase/Sources/GameDatabase.swift
git commit -m "Add BobnetChannel table: per-channel read marker + relay last-activity"
```

*(Session-logout cleanup for this table is an app-target edit — folded into Task 8 with the other shell edits.)*

---

### Task 2: `BobnetFeature` module scaffold

**Files:**
- Create: `app/Modules/BobnetFeature/Sources/BobnetFeature.swift` (placeholder, replaced in Task 4)
- Create: `app/Modules/BobnetFeature/Tests/BobnetFeatureTests.swift` (placeholder, replaced in Task 3)
- Modify: `app/Modules/Package.swift` (product + target + test target, alphabetical: **B**obnetFeature sorts after **B**lueprintsFeature)

- [ ] **Step 1: Create directories + placeholders**

```bash
mkdir -p BobnetFeature/Sources BobnetFeature/Tests
printf '// This file intentionally left minimal.\n' > BobnetFeature/Sources/BobnetFeature.swift
printf '// This file intentionally left minimal.\n' > BobnetFeature/Tests/BobnetFeatureTests.swift
```

- [ ] **Step 2: Package.swift — three edits, alphabetical after BlueprintsFeature**

Products array:
```swift
        .library(name: "BobnetFeature", targets: ["BobnetFeature"]),
```

Targets array (model on the `MessagesFeature` target; no `GameServices` — this feature needs no engine services):
```swift
        .target(
            name: "BobnetFeature",
            dependencies: [
                "API",
                "GameDatabase",
                "GameModels",
                "GameSession",
                "UI",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "BobnetFeature/Sources"
        ),
        .testTarget(
            name: "BobnetFeatureTests",
            dependencies: ["BobnetFeature"],
            path: "BobnetFeature/Tests"
        ),
```

- [ ] **Step 3: Verify**

Run: `swift package resolve && swift build 2>&1 | tail -3`
Expected: resolves and builds.

- [ ] **Step 4: Commit**

```bash
git add Package.swift BobnetFeature
git commit -m "Scaffold BobnetFeature module"
```

---

### Task 3: `BobnetClient` — relay channels, relay messages, replicant send

**Files:**
- Create: `app/Modules/BobnetFeature/Sources/BobnetClient.swift`
- Create: `app/Modules/BobnetFeature/Tests/BobnetClientMappingTests.swift` (replaces the placeholder test file)

**Interfaces:**
- Consumes: generated ops `getV1DevicesDeviceCodeChannels`, `getV1DevicesDeviceCodeMessages`, `postV1ReplicantsReplicantCodeMessage`; `@Dependency(\.gameClient)` from `GameSession`; `BobnetMessage` from `GameModels`.
- Produces: `BobnetChannelInfo { name, lastActive }`, `BobnetPage { messages, nextCursor }`, `@Dependency(\.bobnetClient)` with `channels(relayCode)`, `messages(relayCode, cursor, limit, latest)`, `send(replicantCode, channel, text)`; `BobnetMessage.init?(item:)` / `init?(sendResponse:)`.

**API facts (probed live 2026-07-22):** `cursor=N` pages **forward** (ascending ids > N; `next_cursor` = last id of page, null at tail); `latest=true` returns the newest page **descending** with `next_cursor: null`. Channel item: `{name, last_active}`. Message item/send-response fields match `BobnetMessage` columns (`id` required for keying). Generated property names are camelCase; treat all as optional and coalesce.

- [ ] **Step 1: Write failing mapping tests** (`BobnetClientMappingTests.swift`):

```swift
//
//  BobnetClientMappingTests.swift
//  Replicould — Bobnet feature
//

import API
import Foundation
import Testing
@testable import BobnetFeature
import GameModels

@Suite struct BobnetClientMappingTests {
    @Test func messageItemMapsAllFields() throws {
        let item = Components.Schemas.AppSchemasDevicesBobnetMessageItemSchema(
            id: 5088,
            replicantName: "Bill",
            replicantCode: "A8F48B26",
            currentStar: "SOL",
            channel: "#general",
            message: "hello",
            time: "2026-07-22T14:52:32-05:00"
        )
        let message = try #require(BobnetMessage(item: item))
        #expect(message.id == 5088)
        #expect(message.replicantName == "Bill")
        #expect(message.replicantCode == "A8F48B26")
        #expect(message.currentStar == "SOL")
        #expect(message.channel == "#general")
        #expect(message.message == "hello")
        #expect(message.time == Date(timeIntervalSince1970: 1_784_749_952))
    }

    @Test func messageItemWithoutIDIsNil() {
        let item = Components.Schemas.AppSchemasDevicesBobnetMessageItemSchema(
            id: nil, channel: "#general", message: "x", time: nil
        )
        #expect(BobnetMessage(item: item) == nil)
    }

    @Test func sendResponseMapsToMessage() throws {
        let body = Components.Schemas.AppSchemasReplicantsReplicantMessageResponseSchema(
            status: "sent",
            id: 6001,
            relayCode: "3AFC718C",
            replicantName: "Matt",
            replicantCode: "99380EDF",
            currentStar: nil,
            channel: "#trade",
            message: "selling rocks",
            time: "2026-07-22T20:00:00.123456Z"
        )
        let message = try #require(BobnetMessage(sendResponse: body))
        #expect(message.id == 6001)
        #expect(message.channel == "#trade")
        #expect(message.currentStar == nil)
    }

    @Test func channelInfoParsesFractionalTimestamp() {
        let info = BobnetChannelInfo(
            name: "#general",
            lastActive: BobnetTimestamp.parse("2026-07-22T19:52:32.066645Z")
        )
        #expect(info.lastActive != nil)
        #expect(info.lastActive != Date(timeIntervalSince1970: 0))
    }

    @Test func unparseableTimestampFallsBackToEpoch() {
        #expect(BobnetTimestamp.parse("not-a-date") == Date(timeIntervalSince1970: 0))
        #expect(BobnetTimestamp.parse(nil) == Date(timeIntervalSince1970: 0))
    }
}
```

Note: if the generated schema memberwise-init parameter order differs, follow the compiler (all parameters are defaulted-optional; label order in `Types.swift` wins). The epoch constant `1_784_749_952` = 2026-07-22T19:52:32Z; if the assertion disagrees with the parser by exactly the timezone offset, recompute with `date -j -u -f "%Y-%m-%dT%H:%M:%S" "2026-07-22T19:52:32" +%s`.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BobnetClientMappingTests 2>&1 | tail -5`
Expected: FAIL — `BobnetChannelInfo`/`BobnetTimestamp`/mapping inits not defined.

- [ ] **Step 3: Implement** (`BobnetClient.swift`):

```swift
//
//  BobnetClient.swift
//  Replicould — Bobnet feature
//
//  The dependency that talks to the Bobnet endpoints: a relay's channel
//  directory + message history (`GET /v1/devices/{code}/channels|messages`) and
//  sending via the active replicant (`POST /v1/replicants/{code}/message`).
//  Cursor semantics (probed live): `cursor=N` pages forward (ascending ids > N,
//  `next_cursor` = last id of the page, nil at the tail); `latest=true` returns
//  the newest page descending with a nil cursor. Generated payloads map onto
//  the locally-persisted `BobnetMessage`. Exposed via `@Dependency(\.bobnetClient)`.
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import GameSession

/// One entry of a relay's channel directory.
public struct BobnetChannelInfo: Equatable, Sendable {
    public var name: String
    public var lastActive: Date?

    public init(name: String, lastActive: Date?) {
        self.name = name
        self.lastActive = lastActive
    }
}

/// One page of a relay's message history.
public struct BobnetPage: Equatable, Sendable {
    public var messages: [BobnetMessage]
    public var nextCursor: Int?

    public init(messages: [BobnetMessage], nextCursor: Int?) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

public struct BobnetClient: Sendable {
    /// The channel directory seen by a relay-capable device.
    public var channels: @Sendable (_ relayCode: String) async throws -> [BobnetChannelInfo]
    /// A page of message history visible from a relay. `cursor` pages forward
    /// (ascending ids after it); `latest` returns the newest page instead and is
    /// incompatible with `cursor`.
    public var messages: @Sendable (
        _ relayCode: String,
        _ cursor: Int?,
        _ limit: Int,
        _ latest: Bool
    ) async throws -> BobnetPage
    /// Send a message to a channel as the given replicant. Sending to a channel
    /// that doesn't exist yet creates it (and subscribes the account).
    public var send: @Sendable (
        _ replicantCode: String,
        _ channel: String,
        _ text: String
    ) async throws -> BobnetMessage
}

/// The send endpoint answered without a usable message payload.
public struct BobnetMalformedResponse: Error {}

// MARK: - Live implementation

extension BobnetClient: DependencyKey {
    public static let liveValue = BobnetClient(
        channels: { relayCode in
            @Dependency(\.gameClient) var gameClient
            let output = try await gameClient().getV1DevicesDeviceCodeChannels(
                path: .init(deviceCode: relayCode)
            )
            let body = try output.ok.body.json
            return (body.channels ?? []).compactMap { item in
                guard let name = item.name, !name.isEmpty else { return nil }
                return BobnetChannelInfo(
                    name: name,
                    lastActive: item.lastActive.map { BobnetTimestamp.parse($0) }
                )
            }
        },
        messages: { relayCode, cursor, limit, latest in
            @Dependency(\.gameClient) var gameClient
            let output = try await gameClient().getV1DevicesDeviceCodeMessages(
                path: .init(deviceCode: relayCode),
                query: .init(cursor: cursor, limit: limit, latest: latest ? true : nil)
            )
            let body = try output.ok.body.json
            return BobnetPage(
                messages: (body.messages ?? []).compactMap(BobnetMessage.init(item:)),
                nextCursor: body.nextCursor
            )
        },
        send: { replicantCode, channel, text in
            @Dependency(\.gameClient) var gameClient
            let output = try await gameClient().postV1ReplicantsReplicantCodeMessage(
                path: .init(replicantCode: replicantCode),
                body: .json(.init(channel: channel, text: text))
            )
            let body = try output.ok.body.json
            guard let message = BobnetMessage(sendResponse: body) else {
                throw BobnetMalformedResponse()
            }
            return message
        }
    )
}

// MARK: - Test / preview implementation

extension BobnetClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the network without
    /// stubbing it fails loudly.
    public static let testValue = BobnetClient(
        channels: unimplemented("BobnetClient.channels", placeholder: []),
        messages: unimplemented(
            "BobnetClient.messages",
            placeholder: BobnetPage(messages: [], nextCursor: nil)
        ),
        send: unimplemented("BobnetClient.send")
    )
}

extension DependencyValues {
    public var bobnetClient: BobnetClient {
        get { self[BobnetClient.self] }
        set { self[BobnetClient.self] = newValue }
    }
}

// MARK: - Mapping

extension BobnetMessage {
    /// Maps a relay-history item onto the local record. Returns nil without a
    /// numeric `id` (nothing to key/dedup on).
    init?(item: Components.Schemas.AppSchemasDevicesBobnetMessageItemSchema) {
        guard let id = item.id else { return nil }
        self.init(
            id: id,
            replicantName: item.replicantName ?? "",
            replicantCode: item.replicantCode ?? "",
            currentStar: item.currentStar,
            channel: item.channel ?? "",
            message: item.message ?? "",
            time: BobnetTimestamp.parse(item.time)
        )
    }

    /// Maps the send endpoint's echo of the created message onto the local
    /// record. Returns nil without a numeric `id`.
    init?(sendResponse body: Components.Schemas.AppSchemasReplicantsReplicantMessageResponseSchema) {
        guard let id = body.id else { return nil }
        self.init(
            id: id,
            replicantName: body.replicantName ?? "",
            replicantCode: body.replicantCode ?? "",
            currentStar: body.currentStar,
            channel: body.channel ?? "",
            message: body.message ?? "",
            time: BobnetTimestamp.parse(body.time)
        )
    }
}

/// ISO-8601 parsing shared by every Bobnet payload (with or without fractional
/// seconds), falling back to the Unix epoch so malformed rows still sort
/// predictably. Plain namespace — testable without SwiftUI.
enum BobnetTimestamp {
    static func parse(_ string: String?) -> Date {
        guard let string else { return Date(timeIntervalSince1970: 0) }
        if let date = try? Date(string, strategy: isoWithFraction) { return date }
        if let date = try? Date(string, strategy: isoPlain) { return date }
        return Date(timeIntervalSince1970: 0)
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()
}
```

Also delete the placeholder comment file content if it's still `BobnetFeature/Tests/BobnetFeatureTests.swift` — leave that file in place (Task 5 fills it).

- [ ] **Step 4: Run tests**

Run: `swift test --filter BobnetClientMappingTests 2>&1 | tail -5`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add BobnetFeature
git commit -m "Add BobnetClient: relay channels/messages + replicant send"
```

---

### Task 4: Channel-list and channel-messages queries

**Files:**
- Create: `app/Modules/BobnetFeature/Sources/BobnetQueries.swift`
- Create: `app/Modules/BobnetFeature/Tests/BobnetQueriesTests.swift`

**Interfaces:**
- Produces:
  - `BobnetChannelRow { name, lastActivity: Date?, latestMessageID: Int, lastReadMessageID: Int, unreadCount: Int }` (`Identifiable` by `name`)
  - `BobnetChannelList: FetchKeyRequest` (`Value { rows: [BobnetChannelRow] }`) + pure `BobnetChannelList.merge(channels:messages:)`
  - `BobnetChannelMessages: FetchKeyRequest` (`var channel: String?`, `Value { messages: [BobnetMessage] }`, ascending `(time, id)`)
  - `BobnetReadMarker.advance(_ db:channel:to:)` — monotonic marker write preserving `lastActive`

- [ ] **Step 1: Write failing tests** (`BobnetQueriesTests.swift`):

```swift
//
//  BobnetQueriesTests.swift
//  Replicould — Bobnet feature
//

import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import BobnetFeature

private func message(
    _ id: Int, channel: String, at seconds: TimeInterval, from name: String = "Bill"
) -> BobnetMessage {
    BobnetMessage(
        id: id, replicantName: name, replicantCode: "A8F48B26", currentStar: nil,
        channel: channel, message: "m\(id)", time: Date(timeIntervalSince1970: seconds)
    )
}

@Suite struct BobnetChannelMergeTests {
    @Test func mergesMessageOnlyAndRelayOnlyChannels() {
        let rows = BobnetChannelList.merge(
            channels: [BobnetChannel(name: "#trade", lastActive: Date(timeIntervalSince1970: 500), lastReadMessageID: 0)],
            messages: [message(1, channel: "#general", at: 100)]
        )
        #expect(rows.map(\.name) == ["#trade", "#general"]) // activity desc
        #expect(rows[0].latestMessageID == 0)               // relay-only: no local messages
        #expect(rows[1].unreadCount == 1)                   // no marker row → all unread
    }

    @Test func unreadCountsAgainstMarker() {
        let rows = BobnetChannelList.merge(
            channels: [BobnetChannel(name: "#general", lastActive: nil, lastReadMessageID: 2)],
            messages: [
                message(1, channel: "#general", at: 100),
                message(2, channel: "#general", at: 200),
                message(3, channel: "#general", at: 300),
                message(4, channel: "#general", at: 400),
            ]
        )
        #expect(rows.count == 1)
        #expect(rows[0].unreadCount == 2)
        #expect(rows[0].latestMessageID == 4)
        #expect(rows[0].lastReadMessageID == 2)
        #expect(rows[0].lastActivity == Date(timeIntervalSince1970: 400))
    }

    @Test func activityPrefersNewerOfRelayAndLocal() {
        let rows = BobnetChannelList.merge(
            channels: [BobnetChannel(name: "#general", lastActive: Date(timeIntervalSince1970: 900), lastReadMessageID: 0)],
            messages: [message(1, channel: "#general", at: 100)]
        )
        #expect(rows[0].lastActivity == Date(timeIntervalSince1970: 900))
    }

    @Test func sortsByActivityDescThenName() {
        let rows = BobnetChannelList.merge(
            channels: [
                BobnetChannel(name: "#b", lastActive: Date(timeIntervalSince1970: 100), lastReadMessageID: 0),
                BobnetChannel(name: "#a", lastActive: Date(timeIntervalSince1970: 100), lastReadMessageID: 0),
                BobnetChannel(name: "#quiet", lastActive: nil, lastReadMessageID: 0),
            ],
            messages: []
        )
        #expect(rows.map(\.name) == ["#a", "#b", "#quiet"]) // ties by name, nil activity last
    }
}

@Suite struct BobnetQueriesDatabaseTests {
    @Test func channelListFetchReadsBothTables() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetChannel.upsert {
                BobnetChannel(name: "#general", lastActive: nil, lastReadMessageID: 1)
            }.execute(db)
            try BobnetMessage.upsert { message(1, channel: "#general", at: 100) }.execute(db)
            try BobnetMessage.upsert { message(2, channel: "#general", at: 200) }.execute(db)
        }
        let value = try await database.read { db in try BobnetChannelList().fetch(db) }
        #expect(value.rows.map(\.name) == ["#general"])
        #expect(value.rows[0].unreadCount == 1)
    }

    @Test func channelMessagesAreScopedAndAscending() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetMessage.upsert { message(2, channel: "#general", at: 200) }.execute(db)
            try BobnetMessage.upsert { message(1, channel: "#general", at: 100) }.execute(db)
            try BobnetMessage.upsert { message(3, channel: "#trade", at: 300) }.execute(db)
        }
        let value = try await database.read { db in
            try BobnetChannelMessages(channel: "#general").fetch(db)
        }
        #expect(value.messages.map(\.id) == [1, 2])

        let empty = try await database.read { db in
            try BobnetChannelMessages(channel: nil).fetch(db)
        }
        #expect(empty.messages.isEmpty)
    }

    @Test func readMarkerAdvancesMonotonicallyAndPreservesLastActive() async throws {
        let database = try GameDatabase.bootstrap()
        let active = Date(timeIntervalSince1970: 900)
        try await database.write { db in
            try BobnetChannel.upsert {
                BobnetChannel(name: "#general", lastActive: active, lastReadMessageID: 5)
            }.execute(db)
            try BobnetReadMarker.advance(db, channel: "#general", to: 9)
            try BobnetReadMarker.advance(db, channel: "#general", to: 7) // regression ignored
            try BobnetReadMarker.advance(db, channel: "#fresh", to: 3)   // creates the row
        }
        let rows = try await database.read { db in
            try BobnetChannel.order { $0.name }.fetchAll(db)
        }
        #expect(rows.map(\.name) == ["#fresh", "#general"])
        #expect(rows.map(\.lastReadMessageID) == [3, 9])
        #expect(rows[1].lastActive == active)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter Bobnet 2>&1 | tail -5`
Expected: FAIL — types not defined.

- [ ] **Step 3: Implement** (`BobnetQueries.swift`):

```swift
//
//  BobnetQueries.swift
//  Replicould — Bobnet feature
//
//  The queries behind both panes, plus the read-marker write. The channel list
//  merges the two tables (marker rows + message aggregates) so a channel shows
//  up whether it's known from a relay directory, from streamed messages, or
//  both — all inside `fetch`, which SQLiteData re-runs whenever either table
//  changes. Pure logic lives in plain namespaces (SwiftUI-free) for testing.
//

import Foundation
import GameModels
import SQLiteData

/// One row of the channels pane.
public struct BobnetChannelRow: Equatable, Sendable, Identifiable {
    public var name: String
    /// Newer of the relay-reported activity and the latest local message.
    public var lastActivity: Date?
    /// Highest local message id (0 when no local messages).
    public var latestMessageID: Int
    /// The stored read marker (0 when no marker row exists).
    public var lastReadMessageID: Int
    /// Local messages with `id > lastReadMessageID`.
    public var unreadCount: Int

    public var id: String { name }

    public init(
        name: String,
        lastActivity: Date?,
        latestMessageID: Int,
        lastReadMessageID: Int,
        unreadCount: Int
    ) {
        self.name = name
        self.lastActivity = lastActivity
        self.latestMessageID = latestMessageID
        self.lastReadMessageID = lastReadMessageID
        self.unreadCount = unreadCount
    }
}

/// The channels-pane query: every known channel with activity + unread state.
public struct BobnetChannelList: FetchKeyRequest {
    public struct Value: Equatable, Sendable {
        public var rows: [BobnetChannelRow] = []
        public init(rows: [BobnetChannelRow] = []) { self.rows = rows }
    }

    public init() {}

    public func fetch(_ db: Database) throws -> Value {
        let channels = try BobnetChannel.all.fetchAll(db)
        let messages = try BobnetMessage.all.fetchAll(db)
        return Value(rows: Self.merge(channels: channels, messages: messages))
    }

    /// Pure merge of marker rows and message aggregates, sorted by activity
    /// (descending, nil last), ties by name.
    static func merge(
        channels: [BobnetChannel],
        messages: [BobnetMessage]
    ) -> [BobnetChannelRow] {
        let markers = Dictionary(uniqueKeysWithValues: channels.map { ($0.name, $0) })

        struct Aggregate {
            var latestID = 0
            var latestTime: Date?
            var unread = 0
        }
        var aggregates: [String: Aggregate] = [:]
        for message in messages {
            var aggregate = aggregates[message.channel] ?? Aggregate()
            aggregate.latestID = max(aggregate.latestID, message.id)
            aggregate.latestTime = max(aggregate.latestTime ?? message.time, message.time)
            if message.id > (markers[message.channel]?.lastReadMessageID ?? 0) {
                aggregate.unread += 1
            }
            aggregates[message.channel] = aggregate
        }

        let names = Set(markers.keys).union(aggregates.keys)
        let rows = names.map { name -> BobnetChannelRow in
            let marker = markers[name]
            let aggregate = aggregates[name]
            let activity = [marker?.lastActive, aggregate?.latestTime].compactMap(\.self).max()
            return BobnetChannelRow(
                name: name,
                lastActivity: activity,
                latestMessageID: aggregate?.latestID ?? 0,
                lastReadMessageID: marker?.lastReadMessageID ?? 0,
                unreadCount: aggregate?.unread ?? 0
            )
        }
        return rows.sorted { lhs, rhs in
            switch (lhs.lastActivity, rhs.lastActivity) {
            case let (l?, r?) where l != r: l > r
            case (.some, .none): true
            case (.none, .some): false
            default: lhs.name < rhs.name
            }
        }
    }
}

/// The detail-pane query: one channel's messages, oldest first.
public struct BobnetChannelMessages: FetchKeyRequest {
    public var channel: String?

    public struct Value: Equatable, Sendable {
        public var messages: [BobnetMessage] = []
        public init(messages: [BobnetMessage] = []) { self.messages = messages }
    }

    public init(channel: String?) { self.channel = channel }

    public func fetch(_ db: Database) throws -> Value {
        guard let channel else { return Value() }
        return Value(
            messages: try BobnetMessage
                .where { $0.channel.eq(channel) }
                .order { ($0.time, $0.id) }
                .fetchAll(db)
        )
    }
}

/// Monotonic read-marker writes, preserving the row's other columns.
enum BobnetReadMarker {
    static func advance(_ db: Database, channel: String, to id: Int) throws {
        var row = try BobnetChannel.where { $0.name.eq(channel) }.fetchOne(db)
            ?? BobnetChannel(name: channel, lastActive: nil, lastReadMessageID: 0)
        guard id > row.lastReadMessageID else { return }
        row.lastReadMessageID = id
        try BobnetChannel.upsert { row }.execute(db)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter Bobnet 2>&1 | tail -5`
Expected: PASS (mapping + merge + database suites).

- [ ] **Step 5: Commit**

```bash
git add BobnetFeature
git commit -m "Add Bobnet channel-list/messages queries and read-marker write"
```

---

### Task 5: Reducer — relay discovery, catch-up, selection

**Files:**
- Create: `app/Modules/BobnetFeature/Sources/BobnetFeature.swift` (replaces placeholder)
- Modify: `app/Modules/BobnetFeature/Tests/BobnetFeatureTests.swift` (replaces placeholder)

**Interfaces:**
- Consumes: `BobnetClient`, `BobnetChannelList`, `BobnetChannelMessages`, `BobnetReadMarker`, `Device` (relay roster), `Account.activeReplicantCodeKey`.
- Produces: `BobnetFeature` reducer with `State` (`channelList`, `relays`, `channelMessages`, `selectedChannel`, `markerAtSelection`, `isAtLatest`, `composeText`, `newChannelDraft`, `isCatchingUp`, `isSending`, `errorMessage`, `activeReplicantCode`, computed `activeRelayCode`), `Action` (`binding`, `task`, `refreshButtonTapped`, `catchUpFinished`, `catchUpFailed`, `latestMessageChanged`, `lingerElapsed`, `sendButtonTapped`, `sendSucceeded`, `sendFailed`, `newChannelButtonTapped`, `newChannelDismissed`, `newChannelSubmitted`, `channelCreated`, `dismissError`). Tasks 6–7 fill in linger/send/create cases — this task lands the full state/action surface with those cases returning `.none` where noted.

- [ ] **Step 1: Write failing tests** (replace `BobnetFeatureTests.swift`):

```swift
//
//  BobnetFeatureTests.swift
//  Replicould — Bobnet feature
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import BobnetFeature

/// A stand-in error whose `localizedDescription` is a known string.
struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A minimal relay device fixture; only code/type/status matter to Bobnet.
func relayFixture(_ code: String, status: String = "relaying") -> Device {
    Device(
        deviceCode: code, deviceType: "ftl_relay", replicantCode: "99380EDF",
        status: status, location: "SOL-3-1", locationName: nil,
        operationalCapacity: 100, queueSize: 0, stowedInDeviceCode: nil,
        controllerDeviceCode: nil, attachedToDeviceCode: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        availableCommands: [], features: ["relay"], tags: [], detail: .object([:]),
        updatedAt: Date(timeIntervalSince1970: 0),
        firstSeenAt: Date(timeIntervalSince1970: 0)
    )
}

func bobnetMessage(
    _ id: Int, channel: String = "#general", at seconds: TimeInterval = 0
) -> BobnetMessage {
    BobnetMessage(
        id: id, replicantName: "Bill", replicantCode: "A8F48B26", currentStar: nil,
        channel: channel, message: "m\(id)", time: Date(timeIntervalSince1970: seconds)
    )
}

@MainActor
@Suite struct BobnetCatchUpTests {
    /// With no relaying relay, `.task` does no network work at all — the loud
    /// unimplemented `bobnetClient` would fail this test if it were touched.
    @Test func taskWithoutActiveRelayShortCircuits() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.upsert { relayFixture("AAAA1111", status: "inactive") }.execute(db)
        }
        let store = TestStore(initialState: BobnetFeature.State()) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.finish()
    }

    /// Fresh install (empty table): seed with the newest page (`latest=true`).
    @Test func taskSeedsEmptyTableWithLatestPage() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.upsert { relayFixture("AAAA1111") }.execute(db)
        }
        let calls = LockIsolated<[[String: String]]>([])
        let store = TestStore(initialState: BobnetFeature.State()) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.bobnetClient.channels = { _ in
                [BobnetChannelInfo(name: "#general", lastActive: Date(timeIntervalSince1970: 500))]
            }
            $0.bobnetClient.messages = { relay, cursor, limit, latest in
                calls.withValue { $0.append([
                    "relay": relay, "cursor": cursor.map(String.init) ?? "nil",
                    "limit": "\(limit)", "latest": "\(latest)",
                ]) }
                return BobnetPage(
                    messages: [bobnetMessage(10, at: 400), bobnetMessage(9, at: 300)],
                    nextCursor: nil
                )
            }
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.receive(\.catchUpFinished)

        #expect(calls.value == [
            ["relay": "AAAA1111", "cursor": "nil", "limit": "100", "latest": "true"]
        ])
        let stored = try await database.read { db in
            try BobnetMessage.order { $0.id }.fetchAll(db)
        }
        #expect(stored.map(\.id) == [9, 10])
        let channels = try await database.read { db in try BobnetChannel.all.fetchAll(db) }
        #expect(channels.map(\.name) == ["#general"])
    }

    /// Existing history: walk forward from the local max id until a short page.
    @Test func taskWalksForwardFromLocalMaxID() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.upsert { relayFixture("AAAA1111") }.execute(db)
            try BobnetMessage.upsert { bobnetMessage(50, at: 100) }.execute(db)
        }
        let cursors = LockIsolated<[Int?]>([])
        let store = TestStore(initialState: BobnetFeature.State()) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.bobnetClient.channels = { _ in [] }
            $0.bobnetClient.messages = { _, cursor, _, latest in
                #expect(latest == false)
                cursors.withValue { $0.append(cursor) }
                switch cursor {
                case 50:
                    return BobnetPage(
                        messages: (51...150).map { bobnetMessage($0, at: Double($0)) },
                        nextCursor: 150
                    )
                default:
                    return BobnetPage(
                        messages: [bobnetMessage(151, at: 151)], nextCursor: 151
                    )
                }
            }
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.receive(\.catchUpFinished)

        #expect(cursors.value == [50, 150]) // second page short → stop
        let count = try await database.read { db in try BobnetMessage.all.fetchCount(db) }
        #expect(count == 102) // 50 + 100 walked + 1 short-page
    }

    /// A failed catch-up surfaces the error and clears the in-flight flag.
    @Test func catchUpFailureSurfacesError() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.upsert { relayFixture("AAAA1111") }.execute(db)
        }
        let store = TestStore(initialState: BobnetFeature.State()) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.bobnetClient.channels = { _ in throw StubError(message: "relay offline") }
        }
        store.exhaustivity = .off
        await store.send(.task)
        await store.receive(\.catchUpFailed) {
            $0.errorMessage = "relay offline"
            $0.isCatchingUp = false
        }
    }

    /// A second refresh while one is in flight is ignored.
    @Test func refreshIsIgnoredWhileCatchingUp() async throws {
        let database = try GameDatabase.bootstrap()
        var state = BobnetFeature.State()
        state.isCatchingUp = true
        let store = TestStore(initialState: state) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        await store.send(.refreshButtonTapped)
    }
}

@MainActor
@Suite struct BobnetSelectionTests {
    /// Selecting a channel snapshots its marker (for the "new" divider), resets
    /// the at-latest flag, and reloads the detail query.
    @Test func selectionSnapshotsMarkerAndReloadsMessages() async throws {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetChannel.upsert {
                BobnetChannel(name: "#general", lastActive: nil, lastReadMessageID: 7)
            }.execute(db)
            try BobnetMessage.upsert { bobnetMessage(7, at: 100) }.execute(db)
            try BobnetMessage.upsert { bobnetMessage(8, at: 200) }.execute(db)
        }
        var initial = BobnetFeature.State()
        initial.isAtLatest = true
        let store = TestStore(initialState: initial) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
        }
        // The channel list is part of the fetch machinery, not the assertion.
        try await store.state.$channelList.load(BobnetChannelList())

        await store.send(.binding(.set(\.selectedChannel, "#general"))) {
            $0.selectedChannel = "#general"
            $0.markerAtSelection = 7
            $0.isAtLatest = false
        }
        await store.finish()
        #expect(store.state.channelMessages.messages.map(\.id) == [7, 8])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BobnetCatchUpTests 2>&1 | tail -5`
Expected: FAIL — `BobnetFeature` reducer not defined.

- [ ] **Step 3: Implement the reducer** (`BobnetFeature.swift`). Complete file — the linger/send/create cases referenced here are implemented in Tasks 6–7; in this task their bodies are exactly as shown (the linger cases return `.none` via `reevaluateLinger`'s cancel path only after Task 6 introduces it — for now `latestMessageChanged`/`lingerElapsed`/send/create cases compile as written below with their Task 6/7 bodies included only if you are executing tasks in order; if you prefer, land them as `.none` stubs and let Tasks 6–7 replace them. The final file after Task 7 must match the union of these listings):

```swift
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
        @Fetch(BobnetChannelMessages(channel: nil)) public var channelMessages = BobnetChannelMessages.Value()

        public var selectedChannel: String?
        /// The read marker as it stood when the channel was selected — the
        /// "New messages" divider anchors here so it doesn't jump while the
        /// live marker advances.
        public var markerAtSelection: Int = 0
        /// Whether the detail view is scrolled to the newest message (reported
        /// by the view via scroll geometry).
        public var isAtLatest: Bool = false
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
        case sendButtonTapped
        case sendSucceeded
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

    private enum CancelID { case linger }

    public var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.selectedChannel):
                return selectionChanged(&state)

            case .binding(\.isAtLatest):
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
                return reevaluateLinger(state)

            case .lingerElapsed:
                guard let channel = state.selectedChannel else { return .none }
                let database = self.database
                return .run { _ in
                    try await database.write { db in
                        let maxID = try BobnetMessage
                            .where { $0.channel.eq(channel) }
                            .fetchAll(db).map(\.id).max() ?? 0
                        try BobnetReadMarker.advance(db, channel: channel, to: maxID)
                    }
                }

            case .sendButtonTapped:
                let text = state.composeText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !state.isSending,
                      let channel = state.selectedChannel,
                      state.activeRelayCode != nil,
                      let replicant = state.activeReplicantCode
                else { return .none }
                state.isSending = true
                return sendMessage(channel: channel, text: text, as: replicant) { .sendSucceeded }

            case .sendSucceeded:
                state.isSending = false
                state.composeText = ""
                return .none

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

    /// Selection housekeeping shared by direct selection and channel creation:
    /// snapshot the marker for the divider, reset the scroll flag, reload the
    /// detail query, and cancel any linger in flight.
    private func selectionChanged(_ state: inout State) -> Effect<Action> {
        let channel = state.selectedChannel
        state.markerAtSelection = state.channelList.rows
            .first { $0.name == channel }?.lastReadMessageID ?? 0
        state.isAtLatest = false
        return .merge(
            .cancel(id: CancelID.linger),
            .run { [fetch = state.$channelMessages] _ in
                try? await fetch.load(BobnetChannelMessages(channel: channel))
            }
        )
    }

    /// (Re)arm or cancel the 3-second read-marker linger: it runs only while a
    /// channel is selected, the view sits at the newest message, and something
    /// is unread. `cancelInFlight` restarts the window when a new message
    /// arrives mid-linger.
    private func reevaluateLinger(_ state: State) -> Effect<Action> {
        guard let channel = state.selectedChannel,
              state.isAtLatest,
              let row = state.channelList.rows.first(where: { $0.name == channel }),
              row.latestMessageID > row.lastReadMessageID
        else { return .cancel(id: CancelID.linger) }
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
```

Implementation notes for this step:
- `.binding(\.selectedChannel)` case-key syntax mirrors `MessagesFeature`'s `case .binding(\.selectedMessageID)`.
- If `BobnetMessage.all.fetchAll(db).map(\.id).max()` offends (full-table read to get a max), a `select { $0.id.max() }` form may be available — prefer it if it compiles; the fetched-all form is correct either way at Bobnet's table sizes.
- `Fetch`/`FetchAll` equality: `State: Equatable` works because the wrappers compare by value (see `MessagesFeature.State`/`LocationsFeature.State` precedent).

- [ ] **Step 4: Run tests**

Run: `swift test --filter Bobnet 2>&1 | tail -6`
Expected: PASS — catch-up + selection suites (and Tasks 3–4 suites still green).

- [ ] **Step 5: Commit**

```bash
git add BobnetFeature
git commit -m "Add BobnetFeature reducer: relay discovery, catch-up walk, selection"
```

---

### Task 6: Read-marker linger tests (TestClock)

The linger machinery landed in Task 5's reducer; this task proves its timing semantics.

**Files:**
- Create: `app/Modules/BobnetFeature/Tests/BobnetLingerTests.swift`

- [ ] **Step 1: Write the tests**:

```swift
//
//  BobnetLingerTests.swift
//  Replicould — Bobnet feature
//
//  The 3-second read-marker linger: reaching the newest message arms a timer;
//  scrolling away or switching channels cancels it; a new arrival re-arms it;
//  firing advances the stored marker to the channel's max id.
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import BobnetFeature

@MainActor
@Suite struct BobnetLingerTests {
    /// Builds a store over a database seeded with #general (marker 0) and two
    /// messages (ids 1, 2), with #general selected and the channel list loaded.
    private func makeStore(
        clock: TestClock<Duration>
    ) async throws -> (TestStore<BobnetFeature.State, BobnetFeature.Action>, any DatabaseWriter) {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetMessage.upsert { bobnetMessage(1, at: 100) }.execute(db)
            try BobnetMessage.upsert { bobnetMessage(2, at: 200) }.execute(db)
        }
        var state = BobnetFeature.State()
        state.selectedChannel = "#general"
        let store = TestStore(initialState: state) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.continuousClock = clock
        }
        store.exhaustivity = .off
        try await store.state.$channelList.load(BobnetChannelList())
        return (store, database)
    }

    private func marker(_ database: any DatabaseWriter, _ channel: String) async throws -> Int? {
        try await database.read { db in
            try BobnetChannel.where { $0.name.eq(channel) }.fetchOne(db)?.lastReadMessageID
        }
    }

    /// Lingering at the newest message for 3 seconds marks the channel read.
    @Test func threeSecondLingerAdvancesMarker() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await clock.advance(by: .seconds(3))
        await store.receive(\.lingerElapsed)
        await store.finish()

        #expect(try await marker(database, "#general") == 2)
    }

    /// Scrolling away before 3 seconds cancels the pending mark.
    @Test func scrollingAwayCancelsLinger() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await clock.advance(by: .seconds(2))
        await store.send(.binding(.set(\.isAtLatest, false)))
        await clock.advance(by: .seconds(5))
        await store.finish()

        #expect(try await marker(database, "#general") == nil) // no row ever written
    }

    /// Switching channels cancels the pending mark for the old channel.
    @Test func switchingChannelCancelsLinger() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await clock.advance(by: .seconds(2))
        await store.send(.binding(.set(\.selectedChannel, "#trade")))
        await clock.advance(by: .seconds(5))
        await store.finish()

        #expect(try await marker(database, "#general") == nil)
    }

    /// A new arrival mid-linger restarts the window: the marker only advances
    /// 3 seconds after the *newest* message became visible.
    @Test func arrivalMidLingerRestartsWindow() async throws {
        let clock = TestClock()
        let (store, database) = try await makeStore(clock: clock)

        await store.send(.binding(.set(\.isAtLatest, true)))
        await clock.advance(by: .seconds(2))

        // A new message lands (the SSE route writes it) and the view reports it.
        try await database.write { db in
            try BobnetMessage.upsert { bobnetMessage(3, at: 300) }.execute(db)
        }
        try await store.state.$channelList.load(BobnetChannelList())
        await store.send(.latestMessageChanged)

        await clock.advance(by: .seconds(2))
        #expect(try await marker(database, "#general") == nil) // old window would have fired at 3s

        await clock.advance(by: .seconds(1))
        await store.receive(\.lingerElapsed)
        await store.finish()
        #expect(try await marker(database, "#general") == 3)
    }

    /// A fully-read channel arms nothing.
    @Test func nothingUnreadArmsNoTimer() async throws {
        let clock = TestClock()
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try BobnetMessage.upsert { bobnetMessage(1, at: 100) }.execute(db)
            try BobnetChannel.upsert {
                BobnetChannel(name: "#general", lastActive: nil, lastReadMessageID: 1)
            }.execute(db)
        }
        var state = BobnetFeature.State()
        state.selectedChannel = "#general"
        let store = TestStore(initialState: state) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.continuousClock = clock
        }
        store.exhaustivity = .off
        try await store.state.$channelList.load(BobnetChannelList())

        await store.send(.binding(.set(\.isAtLatest, true)))
        await clock.run() // nothing scheduled: run() returns immediately
        await store.finish()
        #expect(try await marker(database, "#general") == 1) // unchanged
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter BobnetLingerTests 2>&1 | tail -6`
Expected: PASS (5 tests). If `arrivalMidLingerRestartsWindow` sees the marker advance at 2s+2s, the `cancelInFlight: true` on the linger effect is missing — that flag is the restart semantics.

- [ ] **Step 3: Commit**

```bash
git add BobnetFeature/Tests/BobnetLingerTests.swift
git commit -m "Prove the 3-second read-marker linger semantics (TestClock)"
```

---

### Task 7: Send + create-channel tests

Send/create machinery landed in Task 5's reducer; this task proves it.

**Files:**
- Create: `app/Modules/BobnetFeature/Tests/BobnetSendTests.swift`

- [ ] **Step 1: Write the tests**:

```swift
//
//  BobnetSendTests.swift
//  Replicould — Bobnet feature
//

import ComposableArchitecture
import Foundation
import GameDatabase
import GameModels
import SQLiteData
import Testing
@testable import BobnetFeature

@MainActor
@Suite struct BobnetSendTests {
    /// Seeds a relaying relay + selected #general and stubs the active
    /// replicant.
    private func makeStore(
        send: @escaping @Sendable (String, String, String) async throws -> BobnetMessage
    ) async throws -> (TestStore<BobnetFeature.State, BobnetFeature.Action>, any DatabaseWriter) {
        let database = try GameDatabase.bootstrap()
        try await database.write { db in
            try Device.upsert { relayFixture("AAAA1111") }.execute(db)
        }
        var state = BobnetFeature.State()
        state.selectedChannel = "#general"
        state.composeText = "  hello there  "
        state.$activeReplicantCode.withLock { $0 = "99380EDF" }
        let store = TestStore(initialState: state) {
            BobnetFeature()
        } withDependencies: {
            $0.defaultDatabase = database
            $0.bobnetClient.send = send
        }
        store.exhaustivity = .off
        try await store.state.$relays.load()
        return (store, database)
    }

    /// A successful send trims + posts the draft, persists the echo, advances
    /// the marker past it, and clears the compose box.
    @Test func sendPersistsEchoAndAdvancesMarker() async throws {
        let sent = LockIsolated<[[String]]>([])
        let (store, database) = try await makeStore { replicant, channel, text in
            sent.withValue { $0.append([replicant, channel, text]) }
            return bobnetMessage(42, at: 500)
        }

        await store.send(.sendButtonTapped) { $0.isSending = true }
        await store.receive(\.sendSucceeded) {
            $0.isSending = false
            $0.composeText = ""
        }
        #expect(sent.value == [["99380EDF", "#general", "hello there"]])

        let stored = try await database.read { db in
            try BobnetMessage.where { $0.id.eq(42) }.fetchOne(db)
        }
        #expect(stored != nil)
        let markerRow = try await database.read { db in
            try BobnetChannel.where { $0.name.eq("#general") }.fetchOne(db)
        }
        #expect(markerRow?.lastReadMessageID == 42)
    }

    /// A failed send keeps the draft and surfaces the error.
    @Test func sendFailureKeepsDraft() async throws {
        let (store, _) = try await makeStore { _, _, _ in
            throw StubError(message: "no relay in range")
        }
        await store.send(.sendButtonTapped) { $0.isSending = true }
        await store.receive(\.sendFailed) {
            $0.isSending = false
            $0.errorMessage = "no relay in range"
            $0.composeText = "  hello there  "
        }
    }

    /// Without an active replicant, send is a no-op.
    @Test func sendWithoutReplicantIsNoOp() async throws {
        let (store, _) = try await makeStore { _, _, _ in
            Issue.record("send must not be called")
            throw StubError(message: "unreachable")
        }
        store.state.$activeReplicantCode.withLock { $0 = nil }
        await store.send(.sendButtonTapped)
    }

    /// Submitting the New Channel sheet normalizes the name, posts the first
    /// message (which creates + subscribes the channel network-side), then
    /// selects the new channel.
    @Test func newChannelSubmitCreatesAndSelects() async throws {
        let sent = LockIsolated<[[String]]>([])
        let (store, database) = try await makeStore { replicant, channel, text in
            sent.withValue { $0.append([replicant, channel, text]) }
            return BobnetMessage(
                id: 77, replicantName: "Matt", replicantCode: "99380EDF",
                currentStar: nil, channel: channel, message: text,
                time: Date(timeIntervalSince1970: 900)
            )
        }
        await store.send(.newChannelButtonTapped) {
            $0.newChannelDraft = BobnetFeature.NewChannelDraft()
        }
        await store.send(.binding(.set(\.newChannelDraft, {
            var draft = BobnetFeature.NewChannelDraft()
            draft.name = "salvage"
            draft.firstMessage = "anyone stripping hulks near SOL?"
            return draft
        }())))
        await store.send(.newChannelSubmitted) { $0.isSending = true }
        await store.receive(\.channelCreated) {
            $0.isSending = false
            $0.newChannelDraft = nil
            $0.selectedChannel = "#salvage"
        }
        #expect(sent.value == [["99380EDF", "#salvage", "anyone stripping hulks near SOL?"]])
        let row = try await database.read { db in
            try BobnetChannel.where { $0.name.eq("#salvage") }.fetchOne(db)
        }
        #expect(row?.lastReadMessageID == 77)
    }
}

@Suite struct BobnetChannelNameTests {
    @Test func normalizeAddsPrefixAndTrims() {
        #expect(BobnetChannelName.normalize("  salvage ") == "#salvage")
        #expect(BobnetChannelName.normalize("#trade") == "#trade")
    }

    @Test func normalizeRejectsEmptyAndSpaced() {
        #expect(BobnetChannelName.normalize("") == nil)
        #expect(BobnetChannelName.normalize("   ") == nil)
        #expect(BobnetChannelName.normalize("#") == nil)
        #expect(BobnetChannelName.normalize("two words") == nil)
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter "BobnetSendTests|BobnetChannelNameTests" 2>&1 | tail -6`
Expected: PASS. (If `$relays.load()` with no argument doesn't compile, use `try await store.state.$relays.load(Device.where { $0.deviceType.eq("ftl_relay") })` — mirror `ReplicantsFeatureTests`'s `$roster.load()` usage.)

- [ ] **Step 3: Run the whole package**

Run: `swift test 2>&1 | tail -4`
Expected: all suites green.

- [ ] **Step 4: Commit**

```bash
git add BobnetFeature/Tests/BobnetSendTests.swift
git commit -m "Prove Bobnet send + channel-creation flows"
```

---

### Task 8: Views — channels pane, detail pane, compose, sheet

**Files:**
- Create: `app/Modules/BobnetFeature/Sources/BobnetChannelsView.swift` (content pane + `#Preview`-free)
- Create: `app/Modules/BobnetFeature/Sources/BobnetChannelListRow.swift` (row struct, own file)
- Create: `app/Modules/BobnetFeature/Sources/BobnetChannelDetailView.swift` (detail pane)
- Create: `app/Modules/BobnetFeature/Sources/BobnetMessageRow.swift` (row struct, own file)
- Create: `app/Modules/BobnetFeature/Sources/NewChannelSheet.swift`
- Create: `app/Modules/BobnetFeature/Sources/BobnetPreviews.swift` (`#Preview`s only, own file)

**Interfaces:**
- Consumes: `StoreOf<BobnetFeature>`; design tokens; `SidebarSymbol.bobnet` (UI module).
- Produces: `public struct BobnetChannelsView: View { public init(store:) }`, `public struct BobnetChannelDetailView: View { public init(store:) }` — the two panes MainFeature mounts in Task 9.

Guidelines (verify token names against `DesignSystem.swift`/`Controls.swift` with LSP before building):
- Channel names render in a mono token (`.rcBodyEmphMono` for the row title, `.rcMonoSmall` where secondary) — they're designation-style codes.
- Unread badge: match the sidebar's unread badge treatment (see `SidebarView`); if nothing is reusable, a `.rcMonoSmall` count in a capsule tinted `.rcAccent` with `.rcTextOnAccent`-equivalent (check the token; do not invent colors).
- No-relay banner: a compact `safeAreaInset(edge: .top)` strip on the channels list — icon `antenna.radiowaves.left.and.right.slash`, text "No active FTL relays — showing stored history. Catch-up and sending are unavailable." Fonts `.rcMonoSmall`/`.rcBody`, background `.rcWindowBackground`-family token, never a hard-coded color.
- Channels pane: `List(selection: $store.selectedChannel)` over `store.channelList.rows`, `.listStyle(.inset)`, `.navigationTitle("Bobnet")`; toolbar = refresh button (`arrow.clockwise`, disabled while `isCatchingUp`, spins via `ProgressView` swap like other features) + new-channel button (`plus`, disabled when `!store.canSend`). Empty state: `ContentUnavailableView("Bobnet Quiet", systemImage: SidebarSymbol.bobnet, description: Text("Chatter from the network will appear here."))` — preserved from the old `BobnetView`.
- Row: name (mono, `.rcTextPrimary`), relative last-activity (`.relative(presentation: .named)`, `.rcMonoSmall`, `.rcTextTertiary`), unread badge trailing. `.listRowSeparator(.hidden)`, vertical padding `Space.xs`.
- Detail pane, no selection: `RCContentUnavailableView("No Channel Selected", systemImage: SidebarSymbol.bobnet)`.
- Detail pane, selected: `ScrollView` + `LazyVStack(alignment: .leading, spacing: Space.s)` of `BobnetMessageRow`s (adapted from the deleted `BobnetRow`: replicant name `.rcBodyEmph`, optional star `.rcMonoSmall`/`.rcTextTertiary` (mono — it's a designation), relative time trailing, message `.rcBody`/`.rcTextSecondary`, `textSelection(.enabled)` — **no channel tag**, the channel is the context). `.defaultScrollAnchor(.bottom)`.
  - "New messages" divider: before the first message with `id > store.markerAtSelection`, only when `store.markerAtSelection > 0` — an `HStack` of two `Divider`s around `Text("New").font(.rcMonoSmall).foregroundStyle(.rcAccent)`.
  - At-latest reporting: `.onScrollGeometryChange(for: Bool.self, of: { geometry in geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24 }, action: { _, isAtBottom in if store.isAtLatest != isAtBottom { store.send(.binding(.set(\.isAtLatest, isAtBottom))) } })` (24pt tolerance; any small constant is fine, it's a hit-slop not a layout value).
  - Arrival re-arm: `.onChange(of: store.channelMessages.messages.last?.id) { store.send(.latestMessageChanged) }`.
- Compose bar: `safeAreaInset(edge: .bottom)` — `TextField("Message \(channel)", text: $store.composeText)` + send button (`arrow.up.circle.fill`), `.onSubmit { store.send(.sendButtonTapped) }`; disabled with a `.rcMonoSmall` hint line when `!store.canSend` ("No active FTL relay" / "No active replicant").
- Sheet: `.sheet(item: Binding(get: { store.newChannelDraft }, set: { if $0 == nil { store.send(.newChannelDismissed) } }))` presenting `NewChannelSheet` — name field (mono), first-message field, Cancel/Create buttons (Create disabled unless `BobnetChannelName.normalize(name) != nil` and message non-empty → sends `.newChannelSubmitted`). This is the plain-value presentation dialect: never `isPresented:`.
- Error surface: `.overlay(alignment: .bottom)` toast or inline `Text(store.errorMessage)` with a dismiss button sending `.dismissError` — match how `MessagesView` shows `errorMessage` (check and mirror it).
- `BobnetPreviews.swift`: two `#Preview`s (channels pane, detail pane) built over `try! prepareDependencies { try $0.bootstrapDatabase(seed:) }` with a handful of seeded messages/channels — mirror an existing feature's preview bootstrap (e.g. MessagesFeature/DevicesFeature previews) exactly.

- [ ] **Step 1: Write all six view files** per the guidelines above. Views are `public`, stores `@Bindable var store: StoreOf<BobnetFeature>`, inits `public init(store: StoreOf<BobnetFeature>) { self.store = store }`.

- [ ] **Step 2: Build + full test run**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: builds; all suites green.

- [ ] **Step 3: LSP sanity pass** — `documentSymbol` each new view file; `findReferences` on `BobnetChannelsView`/`BobnetChannelDetailView` (0 refs yet — Task 9 wires them); `hover` any token you weren't sure existed.

- [ ] **Step 4: Commit**

```bash
git add BobnetFeature/Sources
git commit -m "Add Bobnet views: channels pane, channel detail, compose, new-channel sheet"
```

---

### Task 9: Shell integration + DevicesFeature extraction

**Files:**
- Modify: `app/Modules/SidebarFeature/Sources/SidebarItem.swift` (`hasDetail`: remove `.bobnet` from the content-only list)
- Modify: `app/macOS/MainFeature.swift` (state/action/scope + panes)
- Modify: `app/macOS/ReplicantApp.swift` (extend the `"bobnet"` logout cleanup to wipe `BobnetChannel`)
- Delete: `app/Modules/DevicesFeature/Sources/BobnetView.swift`, `app/Modules/DevicesFeature/Sources/BobnetRow.swift`

- [ ] **Step 1: SidebarItem** — change `hasDetail`:

```swift
    /// Some categories show content only — no detail pane (Galaxy Map and the
    /// live Operations Log ledger).
    public var hasDetail: Bool {
        switch self {
        case .operationsLog, .stars: false
        default: true
        }
    }
```

- [ ] **Step 2: MainFeature.swift** — five edits, each mirroring the `messages` precedent exactly:
1. `import BobnetFeature` (alphabetical, after `BlueprintsFeature`).
2. State: `/// Bobnet — the galactic chat: channels + per-channel history.` `var bobnet: BobnetFeature.State` and `self.bobnet = BobnetFeature.State()` in `init`.
3. Action: `case bobnet(BobnetFeature.Action)`; add `.bobnet` to the fall-through `return .none` case list.
4. Body: `Scope(state: \.bobnet, action: \.bobnet) { BobnetFeature() }`.
5. View: store accessor
```swift
    /// The Bobnet store, scoped from the main session.
    private var bobnetStore: StoreOf<BobnetFeature> {
        store.scope(state: \.bobnet, action: \.bobnet)
    }
```
   content branch: replace `} else if store.sidebar.category == .bobnet { BobnetView() }` with `} else if store.sidebar.category == .bobnet { BobnetChannelsView(store: bobnetStore) }`; detail: add `} else if store.sidebar.category == .bobnet { BobnetChannelDetailView(store: bobnetStore) }` alongside the other detail branches.

- [ ] **Step 3: ReplicantApp.swift** — extend the existing `"bobnet"` logout handler (read markers are account-scoped):

```swift
        accountManager.registerHandler(
            SessionLifecycleHandler(id: "bobnet", onLogout: {
                @Dependency(\.defaultDatabase) var database
                try? await database.write { db in
                    try BobnetMessage.delete().execute(db)
                    try BobnetChannel.delete().execute(db)
                }
            })
        )
```

- [ ] **Step 4: Delete the old files**

```bash
git rm ../macOS/../Modules/DevicesFeature/Sources/BobnetView.swift ../Modules/DevicesFeature/Sources/BobnetRow.swift 2>/dev/null \
  || git rm DevicesFeature/Sources/BobnetView.swift DevicesFeature/Sources/BobnetRow.swift
```

(Adjust the relative path to wherever your shell sits; the targets are the two files.)

- [ ] **Step 5: Verify the package**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: builds + green. `grep -rn "BobnetView\|BobnetRow" --include="*.swift" . | grep -v ".build"` → no hits inside `Modules`.

Note: the **app target** (`macOS/*.swift`) will not build until the user links the `BobnetFeature` product to it in Xcode — pbxproj edits are blocked by project protocol. That step is called out in the final report; everything inside `Modules/` verifies now.

- [ ] **Step 6: LSP pass** — `findReferences` on `BobnetChannelsView` and `BobnetChannelDetailView` (used from `MainFeature.swift` — grep is acceptable for that app-target sliver); `findReferences` on the deleted types → 0 hits.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Wire Bobnet 3-panel feature into the shell; retire DevicesFeature's BobnetView"
```

---

### Task 10: Docs, memory, final verification

**Files:**
- Modify: `app/.claude/memory/MEMORY.md` (+ new note file `app/.claude/memory/bobnet-feature.md`)
- Modify: `app/README.md` (module map — add BobnetFeature if the map lists feature modules)

- [ ] **Step 1: Memory note** (`app/.claude/memory/bobnet-feature.md`):

```markdown
# Bobnet feature

BobnetFeature module (2026-07-22): 3-panel channels/messages chat, extracted
from DevicesFeature. Local-first: `BobnetMessage` (SSE-fed) + `BobnetChannel`
(name PK, relay `lastActive`, `lastReadMessageID` marker). Catch-up from the
first *relaying* `ftl_relay`: channel directory + forward cursor walk from max
local id (cursor pages ascending; `latest=true` seeds empty tables; 5-page
cap). Send = `POST replicants/{code}/message` as the active replicant — also
the channel-creation primitive (auto-subscribes). Read marker: 3s linger at
newest message (TestClock-proven) or own send; "New" divider anchors to
`markerAtSelection` snapshot. No relaying relay → read-only + banner.
App-target link of the module product is manual (user, Xcode).
```

Index line in `MEMORY.md` (near the other feature notes):

```markdown
- [Bobnet feature](bobnet-feature.md) — BobnetFeature 3-panel channels/messages; BobnetChannel markers; relay catch-up (forward cursor); send via active replicant; 3s linger read rule.
```

- [ ] **Step 2: README map** — if `app/README.md` has a module table/map, add `BobnetFeature` with a one-liner ("Bobnet channels + messages, read markers, relay catch-up"). Skip if no such map exists.

- [ ] **Step 3: Final verification**

Run (from `app/Modules`): `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -4`
Expected: clean build, every suite green. Re-read the original request and confirm each ask maps to shipped behavior: extraction ✓, 3-panel ✓, sending ✓, read marker w/ 3s linger ✓, channel creation ✓, relay channel query + catch-up ✓, no-relay indicator ✓.

- [ ] **Step 4: Commit**

```bash
git add ../.claude/memory ../README.md ../docs
git commit -m "Record Bobnet feature notes; finish Bobnet build-out"
```
