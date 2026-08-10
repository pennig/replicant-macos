//
//  Device.swift
//  Replicould — shared dependency clients
//
//  The locally-persisted device record, upserted into SQLite so the fleet reads
//  instantly and stays live off the event stream. Storage is stable typed columns
//  for the universal fields (observed via `@FetchAll`) plus one `detail` JSON blob
//  holding the whole variable per-`device_type` tail verbatim, decoded on demand —
//  so a new device type or field needs no migration.
//

import API
import Foundation
import SQLiteData
import Utils

/// A single device owned by the signed-in account.
@Table
public struct Device: Identifiable, Equatable, Sendable {
    @Column(primaryKey: true) public var deviceCode: String
    public var deviceType: String
    public var replicantCode: String
    public var status: String
    /// Location code; null when undeployed or in deep space.
    public var location: String?
    public var locationName: String?
    public var operationalCapacity: Double
    /// The queue's *capacity*, not the number of jobs waiting — for that use
    /// `queuedJobCount`.
    public var queueSize: Int
    public var stowedInDeviceCode: String?
    public var controllerDeviceCode: String?
    public var attachedToDeviceCode: String?
    public var createdAt: Date
    @Column(as: [String].JSONRepresentation.self) public var availableCommands: [String]
    @Column(as: [String].JSONRepresentation.self) public var features: [String]
    @Column(as: [String].JSONRepresentation.self) public var tags: [String]
    /// The entire variable per-type tail, verbatim (snake_case keys, as on the
    /// wire), with the core-column keys stripped. Decoded on demand.
    @Column(as: JSONValue.JSONRepresentation.self) public var detail: JSONValue
    /// The read's *request-issue* time, not the server's — the payload carries no
    /// modified-time. Captured before the round-trip, so snapshots order by when
    /// each read began and a slow earlier read cannot clobber a newer one.
    public var updatedAt: Date
    /// Local-only provenance, preserved across upserts.
    public var firstSeenAt: Date

    public var id: String { deviceCode }

    public init(
        deviceCode: String,
        deviceType: String,
        replicantCode: String,
        status: String,
        location: String?,
        locationName: String?,
        operationalCapacity: Double,
        queueSize: Int,
        stowedInDeviceCode: String?,
        controllerDeviceCode: String?,
        attachedToDeviceCode: String?,
        createdAt: Date,
        availableCommands: [String],
        features: [String],
        tags: [String],
        detail: JSONValue,
        updatedAt: Date,
        firstSeenAt: Date
    ) {
        self.deviceCode = deviceCode
        self.deviceType = deviceType
        self.replicantCode = replicantCode
        self.status = status
        self.location = location
        self.locationName = locationName
        self.operationalCapacity = operationalCapacity
        self.queueSize = queueSize
        self.stowedInDeviceCode = stowedInDeviceCode
        self.controllerDeviceCode = controllerDeviceCode
        self.attachedToDeviceCode = attachedToDeviceCode
        self.createdAt = createdAt
        self.availableCommands = availableCommands
        self.features = features
        self.tags = tags
        self.detail = detail
        self.updatedAt = updatedAt
        self.firstSeenAt = firstSeenAt
    }
}

// MARK: - Mapping

extension Device {
    /// Map a generated device snapshot onto the local record. `fetchedAt` is the
    /// synthesized event-time (the read's request-issue time) and seeds
    /// `firstSeenAt` on first insert; the reconciliation guard preserves the
    /// stored `firstSeenAt` thereafter.
    public init(
        schema: Components.Schemas.AppSchemasDevicesDeviceStatusSchema,
        fetchedAt: Date
    ) {
        self.init(
            deviceCode: schema.deviceCode ?? "",
            deviceType: schema.deviceType ?? "",
            replicantCode: schema.replicantCode ?? "",
            status: schema.status ?? "",
            location: schema.location,
            locationName: schema.locationName,
            operationalCapacity: schema.operationalCapacity ?? 0,
            queueSize: schema.queueSize ?? 0,
            stowedInDeviceCode: schema.stowedInDeviceCode,
            controllerDeviceCode: schema.controllerDeviceCode,
            attachedToDeviceCode: schema.attachedToDeviceCode,
            createdAt: schema.createdAt ?? Date(timeIntervalSince1970: 0),
            availableCommands: schema.availableCommands ?? [],
            features: schema.features ?? [],
            tags: schema.tags ?? [],
            detail: Self.detailJSON(from: schema),
            updatedAt: fetchedAt,
            firstSeenAt: fetchedAt
        )
    }

    /// The keys promoted to typed columns; stripped from `detail` so the blob is
    /// just the variable tail.
    private static let coreKeys: Set<String> = [
        "device_code", "device_type", "replicant_code", "status", "location",
        "location_name", "operational_capacity", "queue_size", "stowed_in_device_code",
        "controller_device_code", "attached_to_device_code", "created_at",
        "available_commands", "features", "tags",
    ]

    private static let detailEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Re-encode the generated snapshot to JSON and keep everything except the
    /// core-column keys. Falls back to an empty object if the round-trip fails,
    /// so a quirk in one device never blocks ingestion.
    static func detailJSON(from schema: Components.Schemas.AppSchemasDevicesDeviceStatusSchema) -> JSONValue {
        guard
            let data = try? detailEncoder.encode(schema),
            case .object(var dict)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .object([:]) }
        for key in coreKeys { dict.removeValue(forKey: key) }
        return .object(dict)
    }
}

// MARK: - Control range

extension Device {
    /// Whether the device is currently within its controller's control range
    /// (`in_control_range`). A device out of range is cut off from its AMI
    /// controller — it keeps running its current activity but can't be issued new
    /// commands until it's back in range. Nil when the field is absent (older
    /// payloads / device types that never report it).
    public var inControlRange: Bool? {
        detail["in_control_range"]?.boolValue
    }

    /// True only when the device explicitly reports it is *out* of control range —
    /// the actionable state worth flagging in the UI (a missing field is not
    /// treated as out of range).
    public var isOutOfControlRange: Bool { inControlRange == false }
}

// MARK: - Mesh & print-hub predicates

public extension Device {
    /// The print hub predicate (06): a device that can accept `enqueue_print`.
    /// Uses availableCommands (capability) rather than a deviceType string match,
    /// which a print-vessel would otherwise miss. `system_hub` (mesh device) is a
    /// DIFFERENT concept and is deliberately not matched here.
    var isPrintHub: Bool { availableCommands.contains("enqueue_print") }

    /// An FTL relay that is presently meshing its system. Capability, not type
    /// (includes an integrated system_hub relay); status matched via statusBase.
    var isActiveRelay: Bool { features.contains("relay") && statusBase == "relaying" }

    /// A hull that can carry a fleet: cradles other devices aboard and surges
    /// between systems. Capability, not a deviceType match — every vessel class
    /// with both features qualifies.
    var isCarrierHull: Bool { features.contains("cradle") && features.contains("surge") }
}

// MARK: - Tags

extension Device {
    /// **The server normalises every tag to lowercase** — send `auto:tendMesh` and
    /// the fleet reads back `auto:tendmesh`, so an exact-match gate refuses the very
    /// vessel the operator just opted in. Compare tags only through here.
    public static func normalizedTag(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether this device carries `tag`. BOTH sides are normalised, not just the
    /// constant: a row written before a sync can still hold whatever was typed.
    public func hasTag(_ tag: String) -> Bool {
        let wanted = Self.normalizedTag(tag)
        return tags.contains { Self.normalizedTag($0) == wanted }
    }
}

// MARK: - Replication source capability

extension Device {
    /// The statuses that mean "not currently running an activity". Everything else
    /// the backend reports is some form of work in progress. Kept here rather than
    /// reusing `DeviceStatus` (which lives in `UI`, a layer this module sits below).
    private static let restingStatuses: Set<String> = ["idle", "ready", "stowed", "inactive"]

    /// Whether the device is mid-activity. Drives "wait for its current task to
    /// finish" messaging, so a resting device must never report `true`.
    public var isBusy: Bool { !Self.restingStatuses.contains(statusBase) }

    /// Whether this device can act as the *source* of a replication. The backend
    /// gates `replicate` on the `matrix` feature, which an `empty_replicant_matrix`
    /// LOSES once replicated into — so a replicant born from replication can never
    /// itself replicate, while the account's original matrix can.
    public var canBeSource: Bool { features.contains("matrix") }
}

// MARK: - Status parsing

extension Device {
    /// The backend appends a parenthetical parameter to some statuses —
    /// `"printing (transport_drone)"`, `"mining (iron)"`. The bare activity word
    /// drives the status badge (tone + label); the parameter is surfaced
    /// separately (e.g. in the active-task card) rather than crammed into the
    /// badge.
    public var statusBase: String { Self.splitStatus(status).base }

    /// The parenthetical parameter appended to the status, if any — typically the
    /// device type being printed or the resource being mined.
    public var statusParameter: String? { Self.splitStatus(status).parameter }

    /// Split a raw status into its bare activity word and optional parenthetical
    /// parameter. `"printing (transport_drone)"` → `("printing", "transport_drone")`;
    /// a status with no parenthetical returns `(status, nil)`.
    static func splitStatus(_ raw: String) -> (base: String, parameter: String?) {
        guard
            let open = raw.firstIndex(of: "("),
            let close = raw.lastIndex(of: ")"),
            open < close
        else {
            return (raw.trimmingCharacters(in: .whitespaces), nil)
        }
        let base = raw[..<open].trimmingCharacters(in: .whitespaces)
        let parameter = raw[raw.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return (base, parameter.isEmpty ? nil : parameter)
    }
}

// MARK: - AMI directives

extension Device {
    /// The AMI directives this device can be set to, from the `available_directives`
    /// tail (e.g. a survey controller's `["survey_system", "belt_search"]` or a
    /// mining controller's gather modes). When the server leaves that empty — it
    /// populates it only for the AMI *controllers*, not the worker devices that
    /// still accept `set_directive` — fall back to a per-type vocabulary so the
    /// command still surfaces. Empty only when neither source knows any.
    public var availableDirectives: [String] {
        let runtime = detail["available_directives"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !runtime.isEmpty { return runtime }
        return Self.fallbackDirectives[deviceType] ?? []
    }

    /// Per-`device_type` directive vocabulary, from the device blueprints.
    /// Consulted only when the runtime list (above) is empty.
    private static let fallbackDirectives: [String: [String]] = [
        "maintenance_drone": ["patrol"],
        "service_bot": ["patrol", "service"],
    ]

    /// The name of the directive currently in force (`ami_directive.name`), or nil
    /// when no directive is set. Drives the inspector's directive readout and seeds
    /// the picker's current selection.
    public var currentDirective: String? {
        detail["ami_directive"]?["name"]?.stringValue
    }

    /// The configuration of the directive currently in force (`ami_directive.config`,
    /// e.g. a survey controller's `{planets, moons, recall}`), or nil when the
    /// active directive carries none. Seeds the config form so re-opening the
    /// picker reflects what's running.
    public var currentDirectiveConfig: JSONValue? {
        detail["ami_directive"]?["config"]
    }

    /// The lifecycle state of the directive currently in force
    /// (`ami_directive_status`, e.g. `"active"` or `"paused"`), or nil when none.
    public var currentDirectiveStatus: String? {
        detail["ami_directive_status"]?.stringValue
    }

    /// One device an AMI controller currently controls, from a `controlled_devices`
    /// entry. Backs the release picker (and lets the adopt picker exclude these).
    public struct ControlledDevice: Equatable, Sendable, Identifiable {
        public let deviceCode: String
        public let deviceType: String
        public let status: String?
        public let location: String?
        public var id: String { deviceCode }
    }

    /// The devices this controller currently controls, from its `controlled_devices`
    /// tail (`[{device_code, device_type, status, location}]`). Empty for a
    /// non-controller or a controller holding nothing.
    public var controlledDevices: [ControlledDevice] {
        detail["controlled_devices"]?.arrayValue?.compactMap { entry in
            guard let code = entry["device_code"]?.stringValue else { return nil }
            return ControlledDevice(
                deviceCode: code,
                deviceType: entry["device_type"]?.stringValue ?? "",
                status: entry["status"]?.stringValue,
                location: entry["location"]?.stringValue
            )
        } ?? []
    }

    /// Just the codes of the controlled devices — lets the adopt picker exclude
    /// devices this controller already owns.
    public var controlledDeviceCodes: [String] { controlledDevices.map(\.deviceCode) }
}

// MARK: - Attachment

extension Device {
    /// How many devices this carrier can hold attached at once (`attach_capacity`),
    /// from the variable tail. 0 when the field is absent (the device can't attach).
    public var attachCapacity: Int {
        detail["attach_capacity"]?.numberValue.map(Int.init) ?? 0
    }

    /// The codes of the devices currently attached to this carrier
    /// (`attached_devices`), from the variable tail. Entries may be bare codes or
    /// `{device_code, …}` objects (like `stowed_devices`); both are handled. Empty
    /// when none are attached or the field is absent.
    public var attachedDeviceCodes: [String] {
        detail["attached_devices"]?.arrayValue?.compactMap {
            $0["device_code"]?.stringValue ?? $0.stringValue
        } ?? []
    }

    /// A surge plate's carry mode (`taxi_mode` in the variable tail): "taxi"
    /// (any same-owner device may ride) or "manual" (explicit attach only).
    /// Nil when the device doesn't report one. Seeds the `configure` picker.
    public var taxiMode: String? {
        detail["taxi_mode"]?.stringValue
    }
}

// MARK: - Stowage

extension Device {
    /// How many devices this device can hold stowed at once (`stow_capacity`), from
    /// the variable tail. 0 when the field is absent (the device can't stow).
    public var stowCapacity: Int {
        detail["stow_capacity"]?.numberValue.map(Int.init) ?? 0
    }

    /// How many stow slots are currently occupied (`stow_used`), from the variable
    /// tail. Falls back to the count of `stowed_devices` when the field is absent.
    public var stowUsed: Int {
        detail["stow_used"]?.numberValue.map(Int.init) ?? stowedDeviceCodes.count
    }

    /// The stow slots still free — capacity minus used, never negative.
    public var stowRemaining: Int { Swift.max(0, stowCapacity - stowUsed) }

    /// The codes of the devices currently stowed in this device (`stowed_devices`),
    /// from the variable tail. Entries may be bare codes or `{device_code, …}`
    /// objects (like `attached_devices`); both are handled. Empty when none are
    /// stowed or the field is absent.
    public var stowedDeviceCodes: [String] {
        detail["stowed_devices"]?.arrayValue?.compactMap {
            $0["device_code"]?.stringValue ?? $0.stringValue
        } ?? []
    }
}

// MARK: - Cargo

extension Device {
    /// A single resource stack held in a transport device's cargo hold
    /// (`cargo` entry) — a resource type and how many units of it are aboard.
    public struct CargoItem: Equatable, Sendable, Identifiable {
        public let resourceType: String
        public let quantity: Int
        public var id: String { resourceType }
    }

    /// The total cargo hold capacity in units (`cargo_capacity`), from the
    /// variable tail. 0 when the field is absent (the device carries no hold).
    public var cargoCapacity: Int {
        detail["cargo_capacity"]?.numberValue.map(Int.init) ?? 0
    }

    /// How many cargo units are currently aboard (`cargo_used`), from the variable
    /// tail. Falls back to summing the `cargo` stacks when the field is absent.
    public var cargoUsed: Double {
        detail["cargo_used"]?.numberValue ?? Double(cargoItems.reduce(0) { $0 + $1.quantity })
    }

    /// The cargo hold's free capacity — capacity minus used, never negative.
    public var cargoRemaining: Int { Swift.max(0, cargoCapacity - Int(cargoUsed)) }

    /// The resource stacks currently in the cargo hold (`cargo`), from the variable
    /// tail. Empty when the hold is empty or the field is absent.
    public var cargoItems: [CargoItem] {
        detail["cargo"]?.arrayValue?.compactMap { entry in
            guard let resource = entry["resource_type"]?.stringValue else { return nil }
            return CargoItem(
                resourceType: resource,
                quantity: entry["quantity"]?.numberValue.map(Int.init) ?? 0
            )
        } ?? []
    }
}

// MARK: - Operation completion signals

extension Device {
    /// Device statuses that mean it is *not* executing a timed operation. The
    /// stream completion event is the primary signal that an op finished; when
    /// that's lost, the deadline scheduler falls back to this — an op is complete
    /// once its device has settled.
    public static let settledStatuses: Set<String> = ["idle", "stowed", "inactive"]

    /// Whether the device is idle / done with any timed activity.
    public var isSettled: Bool { Self.settledStatuses.contains(status) }

    /// The soonest completion time reported by an in-progress activity block in
    /// `detail` (travel/mining/printing/…), if the device is still mid-activity.
    /// Used to re-arm the deadline when the server's estimate slips past the
    /// original ETA (so the bar stays honest and the scheduler keeps polling
    /// instead of completing the op prematurely). All activity-timing payload
    /// parsing lives here, in one place. Nil when no active block is present.
    public var activityDeadline: Date? {
        let blocks: [(block: String, fields: [String])] = [
            ("mining", ["completes_at", "cycle_completes_at"]),
            ("printing", ["completes_at"]),
            ("scan", ["completes_at"]),
            ("prospect", ["completes_at"]),
            ("repair", ["completes_at"]),
            ("compact", ["completes_at"]),
            ("unfurl", ["completes_at"]),
        ]
        var soonest: Date?
        for (block, fields) in blocks {
            guard case .object = detail[block] else { continue }
            for field in fields {
                if let string = detail[block]?[field]?.stringValue,
                   let date = Self.parseActivityDate(string) {
                    soonest = soonest.map { Swift.min($0, date) } ?? date
                }
            }
        }
        // Travel reports both the active leg's arrival (`arrives_at`) and the
        // whole route's arrival (`final_arrives_at`). Resolved by
        // `travelDeadline` rather than the `min()` table above, which would pick
        // the first leg of a multi-leg route and end the trip early.
        if case .object = detail["travel"],
           let date = Self.travelDeadline(
               routeEnd: detailDate("travel", "final_arrives_at"),
               legEnd: detailDate("travel", "arrives_at")
           ) {
            soonest = soonest.map { Swift.min($0, date) } ?? date
        }
        // The survey `scan`/search block now reports an absolute `completes_at`
        // (picked up by the table above). Only when the server omits it do we fall
        // back to deriving the deadline from the *remaining* `eta_seconds` off the
        // fetch event-time — deriving it alongside a present `completes_at` risks
        // `min()` picking a stale, earlier eta and ending the op a beat early.
        if case .object = detail["scan"], detailDate("scan", "completes_at") == nil,
           let eta = detail["scan"]?["eta_seconds"]?.numberValue {
            let date = updatedAt.addingTimeInterval(eta)
            soonest = soonest.map { Swift.min($0, date) } ?? date
        }
        return soonest
    }

    /// The deadline a `travel` block describes. The ROUTE's end wins when genuinely
    /// later, since keying off the leg ends a multi-leg op a waypoint early — but a
    /// surge plate mid-hop reports a `final_arrives_at` left over from a route it
    /// already finished, and a past deadline makes every op it stamps instantly
    /// overdue. A leg cannot outlast its route, so "the later of the two" is the
    /// whole rule: it keeps multi-leg behaviour and discards only impossible values.
    public static func travelDeadline(routeEnd: Date?, legEnd: Date?) -> Date? {
        switch (routeEnd, legEnd) {
        case let (route?, leg?): Swift.max(route, leg)
        default: routeEnd ?? legEnd
        }
    }

    private static func parseActivityDate(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle()) { return date }
        return nil
    }
}

// MARK: - Derived operations

extension Device {
    /// An open operation derived from an in-progress device snapshot. The
    /// reconcile path adopts this when the device holds no operation of its own —
    /// e.g. a cold-load or relaunch finds the device already printing or
    /// travelling, so its task (and progress bar) would otherwise be invisible
    /// because ops are normally only created by optimistic command dispatch. Nil
    /// when the device is settled or carries no recognized activity block.
    public struct DerivedActivity: Equatable, Sendable {
        public let kind: OperationKind
        public let startedAt: Date?
        public let completesAt: Date?
    }

    /// The in-progress activity this snapshot describes, if any. Reads the same
    /// `detail` activity blocks as `activityDeadline`, but identifies the kind so
    /// an op can be reconstructed. Mining is continuous (its cycle deadline is the
    /// soonest completion, not the op's end), so its `completesAt` is best-effort.
    public var derivedActivity: DerivedActivity? {
        guard !isSettled else { return nil }
        if case .object = detail["printing"] {
            return DerivedActivity(
                kind: .print,
                startedAt: detailDate("printing", "started_at"),
                completesAt: detailDate("printing", "completes_at")
            )
        }
        if case .object = detail["travel"] {
            return DerivedActivity(
                kind: .travel,
                startedAt: detailDate("travel", "started_at") ?? detailDate("travel", "departed_at"),
                // The route's end when it is really the end, else the active leg
                // — see `travelDeadline`. Adopting a stale route end here stamps
                // the op overdue at birth.
                completesAt: Self.travelDeadline(
                    routeEnd: detailDate("travel", "final_arrives_at"),
                    legEnd: detailDate("travel", "arrives_at")
                )
            )
        }
        if case .object = detail["mining"] {
            return DerivedActivity(
                kind: .mine,
                startedAt: detailDate("mining", "started_at"),
                completesAt: detailDate("mining", "completes_at") ?? detailDate("mining", "cycle_completes_at")
            )
        }
        // Compacting for transport: a `compact` block with an absolute
        // `completes_at`, so a device found mid-compact (cold-load) adopts a
        // deadline op that the generic progress bar can draw.
        if case .object = detail["compact"] {
            return DerivedActivity(
                kind: .compact,
                startedAt: detailDate("compact", "started_at"),
                completesAt: detailDate("compact", "completes_at")
            )
        }
        // Unfurling from transport: the inverse of compact, an `unfurl` block with
        // an absolute `completes_at`, adopted the same way.
        if case .object = detail["unfurl"] {
            return DerivedActivity(
                kind: .unfurl,
                startedAt: detailDate("unfurl", "started_at"),
                completesAt: detailDate("unfurl", "completes_at")
            )
        }
        // Survey-drone scan/search: a `scan` block with an `eta_seconds` countdown
        // (no absolute completion). The deadline is the fetch event-time plus the
        // remaining ETA — eta_seconds is *remaining*, not total, so anchoring on
        // `updatedAt` (not `started_at`) lands on the real finish. A body `scan` and
        // a belt `search` surface an *identical* block, so the device status is the
        // only discriminator: `scanning` → body scan, otherwise the belt search.
        if case .object = detail["scan"] {
            return DerivedActivity(
                kind: statusBase == "scanning" ? .surveyScan : .search,
                startedAt: detailDate("scan", "started_at"),
                completesAt: detailDate("scan", "completes_at")
                    ?? detail["scan"]?["eta_seconds"]?.numberValue.map { updatedAt.addingTimeInterval($0) }
            )
        }
        return nil
    }

    private func detailDate(_ block: String, _ field: String) -> Date? {
        guard let string = detail[block]?[field]?.stringValue else { return nil }
        return Self.parseActivityDate(string)
    }
}

// MARK: - Travel snapshot

/// A display summary of a travel itinerary: where the device set out from, where
/// it's ultimately bound, and every leg of the route (with its duration, so a
/// segmented progress bar can weight each leg). Parsed from a "travel-ish" JSON
/// object — either the device's live `travel` block or a `travel` command
/// response — since both carry the same field vocabulary. The live block only
/// lists the *remaining* legs (completed ones are dropped server-side and the
/// rest renumber), while a dispatch response captured the *whole* route at
/// departure; callers prefer the frozen dispatch route and fall back to the live
/// block for a device adopted mid-flight.
public struct TravelSnapshot: Equatable, Sendable {
    public var origin: String?
    public var originName: String?
    public var destination: String?
    public var destinationName: String?
    /// The route, in order. Empty when the object carried no `route` array.
    public var legs: [Leg]

    public struct Leg: Equatable, Sendable, Identifiable {
        public var index: Int
        public var from: String?
        public var fromName: String?
        public var to: String?
        public var toName: String?
        /// The travel mode (e.g. `surge`, `cruise`).
        public var type: String?
        /// This leg's duration, driving its share of a segmented bar.
        public var timeSeconds: Double?
        /// Whether the server flags this as the leg currently under way.
        public var active: Bool

        public var id: Int { index }
    }

    /// Origin label, preferring the human name over the bare code.
    public var originLabel: String? { originName ?? origin }
    /// Destination label, preferring the human name over the bare code.
    public var destinationLabel: String? { destinationName ?? destination }

    /// Sum of every leg's `timeSeconds`, or nil if any leg lacks one. Lets a
    /// caller anchor a progress bar on `completesAt − totalDuration`.
    public var totalLegSeconds: Double? {
        guard !legs.isEmpty, legs.allSatisfy({ $0.timeSeconds != nil }) else { return nil }
        return legs.reduce(0) { $0 + ($1.timeSeconds ?? 0) }
    }

    /// Parse from a travel-ish JSON object. Nil when the value isn't an object or
    /// carries neither a destination nor a route (so it isn't a travel payload).
    public init?(travelObject object: JSONValue?) {
        guard case .object = object else { return nil }
        origin = object?["origin"]?.stringValue
        originName = object?["origin_name"]?.stringValue
        // Prefer the ultimate arrival point over the system-level destination.
        destination = object?["final_destination"]?.stringValue ?? object?["destination"]?.stringValue
        destinationName = object?["final_destination_name"]?.stringValue ?? object?["destination_name"]?.stringValue

        var parsed: [Leg] = []
        if case let .array(items)? = object?["route"] {
            for (offset, item) in items.enumerated() {
                parsed.append(Leg(
                    index: item["leg"]?.numberValue.map(Int.init) ?? offset + 1,
                    from: item["from"]?.stringValue,
                    fromName: item["from_name"]?.stringValue,
                    to: item["to"]?.stringValue,
                    toName: item["to_name"]?.stringValue,
                    type: item["type"]?.stringValue,
                    timeSeconds: item["time_seconds"]?.numberValue,
                    active: item["active"]?.boolValue == true
                ))
            }
        }
        legs = parsed

        if legs.isEmpty && destination == nil { return nil }
    }
}

extension Device {
    /// The device's current travel itinerary, parsed from its live `travel` block
    /// (remaining legs only). Nil when the device carries no travel block.
    public var travelSnapshot: TravelSnapshot? {
        TravelSnapshot(travelObject: detail["travel"])
    }
}

extension Operation {
    /// The travel itinerary captured when this op was dispatched, parsed from the
    /// stored command response (`detail.result`) — the *whole* route, frozen at
    /// departure. Nil for ops adopted from a snapshot (which carry no result) or
    /// non-travel ops.
    public var travelSnapshot: TravelSnapshot? {
        TravelSnapshot(travelObject: detail["result"])
    }
}

// MARK: - Schema

extension Device {
    /// Creates the `devices` table. Kept beside the model so the schema and
    /// the type never drift.
    public static let createDevices = SchemaMigration("Create 'devices' table") { db in
        try #sql(
            """
            CREATE TABLE "devices" (
              "deviceCode" TEXT PRIMARY KEY NOT NULL,
              "deviceType" TEXT NOT NULL DEFAULT '',
              "replicantCode" TEXT NOT NULL DEFAULT '',
              "status" TEXT NOT NULL DEFAULT '',
              "location" TEXT,
              "locationName" TEXT,
              "operationalCapacity" REAL NOT NULL DEFAULT 0,
              "queueSize" INTEGER NOT NULL DEFAULT 0,
              "stowedInDeviceCode" TEXT,
              "controllerDeviceCode" TEXT,
              "attachedToDeviceCode" TEXT,
              "createdAt" TEXT NOT NULL,
              "availableCommands" TEXT NOT NULL DEFAULT '[]',
              "features" TEXT NOT NULL DEFAULT '[]',
              "tags" TEXT NOT NULL DEFAULT '[]',
              "detail" TEXT NOT NULL DEFAULT '{}',
              "updatedAt" TEXT NOT NULL,
              "firstSeenAt" TEXT NOT NULL
            ) STRICT
            """
        )
        .execute(db)
    }
}
