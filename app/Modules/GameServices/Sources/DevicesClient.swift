//
//  DevicesClient.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  Talks to the device endpoints through the shared generated client (so calls
//  inherit bearer auth, rate limiting, and logging). Lives here, beside the
//  `Device` table, because it's cross-feature infrastructure the ingestion
//  service (`GameSync`) and the future Devices feature both use, rather than
//  belonging to any one feature. Exposed via `@Dependency(\.devicesClient)`.
//
//  Phase 2 needs only the single-device read — the authoritative snapshot a
//  stream event invalidates into. The account-wide paged list walk arrives with
//  the Devices feature (Phase 5).
//

import API
import Dependencies
import Foundation
import GameModels
import GameSession
import OSLog
import Utils

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Devices")

public struct DevicesClient: Sendable {
    /// Read one device's authoritative snapshot (`GET /v1/devices/{code}`),
    /// stamped with the request-issue time as its synthesized event-time (§4.1),
    /// so out-of-order responses reconcile by initiation order.
    public var read: @Sendable (_ deviceCode: String) async throws -> Device

    /// Cold-load the whole account fleet (`GET /v1/devices`, paged). Each device
    /// is stamped with its page's request-issue time; callers reconcile them so
    /// local provenance (`firstSeenAt`) is preserved.
    public var fetchAll: @Sendable () async throws -> [Device]

    /// Every device the server considers present in a location scope
    /// (`GET /v1/devices?location=`, paged). A star designation scopes to the
    /// whole system, so one request returns a vessel, its controller and its
    /// drones together — and **in-transit devices are included**: a travelling
    /// device reports `location: null` yet is still matched by the filter
    /// (verified live 2026-07-27), which is what makes this usable for watching
    /// a recall.
    ///
    /// The point is rate limit, not convenience: reading a system costs one
    /// request where the equivalent per-device reads cost one each, and it stops
    /// scaling with the size of the fleet.
    ///
    /// **This is NOT the authoritative full fleet.** Callers reconcile what it
    /// returns and must never follow it with `Reconciler.pruneDevices` — every
    /// device outside the scope is absent by construction, and treating those
    /// absences as "gone" would delete the fleet.
    public var fetchAtLocation: @Sendable (_ designation: String) async throws -> [Device]

    /// Every device carrying `tag` (`GET /v1/devices/tags/{tag}`, paged).
    ///
    /// This is the one scope that reports the TAGGED fleet correctly regardless
    /// of stow or travel state. `fetchAtLocation` answers PRESENCE and cannot
    /// see a stowed device — stowing clears `location`, which drops the row out
    /// of the location index (six drones stowed aboard a vessel returned
    /// exactly one row, the vessel, probed live 2026-07-29). A tag filter
    /// touches location not at all, so every tagged device comes back
    /// regardless of state: probed live 2026-07-30, a whole tagged fleet caught
    /// mid-flight came back with `location: null` across the board — the
    /// vessel because it was travelling, the rest because stowing clears it —
    /// and each stowed device still carried its `stowedInDeviceCode` intact.
    ///
    /// **Not the authoritative full fleet.** Only devices carrying `tag` are
    /// visible here — every untagged device is absent by construction — so
    /// callers reconcile what it returns and must never follow it with
    /// `Reconciler.pruneDevices`.
    public var fetchByTag: @Sendable (_ tag: String) async throws -> [Device]

    /// Read the diversion defense state at a location (`GET /v1/locations/{code}`),
    /// mapping its `object` block to a `DiversionSnapshot`. A `diverting` device
    /// exposes no activity block of its own — the impact target, ETA, and
    /// deflection progress all live on the object it's attached to. Nil when the
    /// location carries no divertible object (or isn't readable).
    public var diversion: @Sendable (_ locationDesignation: String) async throws -> DiversionSnapshot?

    /// Resolve the live FTL mesh for a set of relay devices by reading each one's
    /// network view (`GET /v1/devices/{code}/network`). Every reported connection
    /// becomes an undirected link between the relay's own star and the peer's
    /// star; reciprocal reports collapse under `FTLLink`'s canonical ordering. A
    /// relay whose network read fails (or a beacon that doesn't support the view)
    /// is skipped rather than failing the whole mesh.
    public var relayLinks: @Sendable (_ relays: [RelayNode]) async throws -> [FTLLink]

    /// Replace a device's tag set (`PATCH /v1/devices/{code}`, `configuration.tags`).
    /// The declarative `tags` field replaces every tag at once, so the inspector —
    /// which manages the whole set — reduces both add and remove to sending the new
    /// list. PATCH only: the response carries just `{device_code, tags}`, and the
    /// follow-up confirm-read is the *caller's* job, funneled through
    /// `deviceRefresher` so it stamps the coordinator's TTL like every other
    /// post-command read (B4). Throws `TagUpdateError` carrying the server's
    /// message on a rejection.
    public var updateTags: @Sendable (_ deviceCode: String, _ tags: [String]) async throws -> Void

    /// A rejected tag update, carrying a user-facing message.
    public struct TagUpdateError: Error, Equatable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }
}

// MARK: - Live implementation

extension DevicesClient: DependencyKey {
    /// Page size for the fleet walk. `GET devices` caps at 50 — lower than the
    /// 100 every other paged endpoint allows — and over-asking is silently
    /// clamped rather than rejected, so asking for more just misrepresents the
    /// page size at the call site. Ask for exactly the maximum: fewest requests
    /// against the reads budget, and the number here matches what arrives.
    private static let pageSize = 50

    public static let liveValue = DevicesClient(
        read: { deviceCode in
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.date) var date
            // Stamp the event-time at request *issue*, before the round-trip, so
            // reconciliation orders snapshots by when each read was initiated —
            // not by when its response happened to land. A read that starts later
            // reflects same-or-newer server state, so a slow earlier read can no
            // longer clobber a newer one on arrival (see `Reconciler`'s guard).
            let issuedAt = date.now
            let output = try await gameClient().getV1DevicesDeviceCode(path: .init(deviceCode: deviceCode))
            let schema = try output.ok.body.json
            return Device(schema: schema, fetchedAt: issuedAt)
        },
        fetchAll: {
            let devices = try await Self.walk(location: nil)
            logger.info("cold-load: fetched \(devices.count) devices")
            return devices
        },
        fetchAtLocation: { designation in
            let devices = try await Self.walk(location: designation)
            logger.info("fetched \(devices.count) device(s) at \(designation, privacy: .public) in one scoped walk")
            return devices
        },
        fetchByTag: { tag in
            @Dependency(\.gameClient) var gameClient
            @Dependency(\.date) var date
            // One client for the whole walk, and an issue-time stamp per page —
            // same reasoning as `walk`: a page reconciles by when it was asked
            // for, so a slow page can't regress a newer single-device read.
            let client = gameClient()
            var devices: [Device] = []
            var cursor: Int?
            repeat {
                let issuedAt = date.now
                let output = try await client.getV1DevicesTagsTag(
                    path: .init(tag: tag),
                    query: .init(cursor: cursor, limit: Self.pageSize)
                )
                let body = try output.ok.body.json
                devices.append(contentsOf: (body.devices ?? []).map { Device(schema: $0, fetchedAt: issuedAt) })
                cursor = body.nextCursor
            } while cursor != nil
            logger.info("fetched \(devices.count) device(s) tagged \(tag, privacy: .public)")
            return devices
        },
        diversion: { designation in
            @Dependency(\.gameClient) var gameClient
            let output = try await gameClient().getV1LocationsDesignation(path: .init(designation: designation))
            // The generated client hands the nested blocks back only as an opaque
            // freeform container, so round-trip through JSON to reach the `object`
            // block. A non-OK response (403 unexplored, 404) just means "no card".
            guard case let .ok(ok) = output else { return nil }
            let data = try Self.locationEncoder.encode(try ok.body.json)
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            return DiversionSnapshot(objectBlock: value["object"], fallbackDesignation: designation)
        },
        relayLinks: { relays in
            guard !relays.isEmpty else { return [] }
            @Dependency(\.gameClient) var gameClient
            // Resolve the client once and reuse it across the per-relay reads (the
            // governor is process-shared, but one client per walk is the clean
            // shape — mirrors `fetchAll`).
            let client = gameClient()
            var links: Set<FTLLink> = []
            for relay in relays {
                // A relay may briefly be undeployed / recalled, or the read may be
                // refused (a beacon returns 400 "Device does not support relay").
                // Skip it — a single unreachable relay shouldn't drop the mesh.
                guard let output = try? await client.getV1DevicesDeviceCodeNetwork(
                    path: .init(deviceCode: relay.deviceCode)),
                      case let .ok(ok) = output,
                      let body = try? ok.body.json
                else { continue }
                for connection in body.connections ?? [] {
                    guard let peer = connection.star, !peer.isEmpty else { continue }
                    links.insert(FTLLink(relay.star, peer))
                }
            }
            // Deterministic order so the render terrain's equality is stable
            // across fetches that return the same set.
            return links.sorted { $0.a == $1.a ? $0.b < $1.b : $0.a < $1.a }
        },
        updateTags: { deviceCode, tags in
            @Dependency(\.gameClient) var gameClient
            let output = try await gameClient().patchV1DevicesDeviceCode(
                path: .init(deviceCode: deviceCode),
                body: .json(.init(configuration: .init(tags: tags)))
            )
            switch output {
            case .ok:
                return
            case let .badRequest(response):
                throw TagUpdateError((try? response.body.json.error) ?? "Couldn’t update tags.")
            case let .forbidden(response):
                throw TagUpdateError((try? response.body.json.error) ?? "Not permitted.")
            case let .notFound(response):
                throw TagUpdateError((try? response.body.json.error) ?? "Device not found.")
            case let .unprocessableContent(response):
                throw TagUpdateError((try? response.body.json.message) ?? "Those tags weren’t accepted.")
            case let .default(statusCode, _):
                throw TagUpdateError("Server error (\(statusCode)).")
            }
        }
    )

    /// One paged walk of `GET /v1/devices`, optionally scoped to a location.
    /// Shared by `fetchAll` and `fetchAtLocation` so the cursor handling and the
    /// per-page issue-time stamping have exactly one implementation.
    private static func walk(location: String?) async throws -> [Device] {
        @Dependency(\.gameClient) var gameClient
        @Dependency(\.date) var date
        // Resolve the client once and reuse it across the paged walk (the
        // governor is process-shared, but one client per walk is the clean
        // shape — mirrors `StarsClient.survey`).
        let client = gameClient()
        var devices: [Device] = []
        var cursor: Int?
        repeat {
            // Issue-time per page (before the round-trip), matching `read`: a
            // page's devices reconcile by when the page was requested, so a
            // slow page can't regress a newer single-device read that landed
            // in the meantime.
            let issuedAt = date.now
            let output = try await client.getV1Devices(
                query: .init(location: location, cursor: cursor, limit: Self.pageSize)
            )
            let body = try output.ok.body.json
            devices.append(contentsOf: (body.devices ?? []).map { Device(schema: $0, fetchedAt: issuedAt) })
            cursor = body.nextCursor
        } while cursor != nil
        return devices
    }

    private static let locationEncoder = JSONEncoder()
}

extension DevicesClient: TestDependencyKey {
    /// Unimplemented by default so a test that reaches the network without
    /// stubbing it fails loudly.
    public static let testValue = DevicesClient(
        read: unimplemented("DevicesClient.read"),
        fetchAll: unimplemented("DevicesClient.fetchAll", placeholder: []),
        fetchAtLocation: unimplemented("DevicesClient.fetchAtLocation", placeholder: []),
        fetchByTag: unimplemented("DevicesClient.fetchByTag", placeholder: []),
        diversion: unimplemented("DevicesClient.diversion", placeholder: nil),
        relayLinks: unimplemented("DevicesClient.relayLinks", placeholder: []),
        updateTags: unimplemented("DevicesClient.updateTags")
    )
}

extension DependencyValues {
    public var devicesClient: DevicesClient {
        get { self[DevicesClient.self] }
        set { self[DevicesClient.self] = newValue }
    }
}
