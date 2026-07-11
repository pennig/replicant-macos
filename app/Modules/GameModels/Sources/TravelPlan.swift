//
//  TravelPlan.swift
//  Replicould — shared dependency clients
//
//  The itinerary a `travel` command returns when invoked with `dry_run: true`:
//  the route the server *would* plot (each leg, its distance and time) and the
//  totals, without dispatching the device. Surfaced as a confirmation preview
//  before the user commits to the real travel command. Decoded from the shared
//  device-command response (whose route legs are otherwise untyped), so the
//  fields mirror the server's snake_case payload.
//

import Foundation

/// A previewed travel itinerary — the legs and totals from a `dry_run` travel.
public struct TravelPlan: Sendable, Equatable, Codable {
    /// The ultimate destination code the route resolves to.
    public var finalDestination: String?
    public var finalDestinationName: String?
    /// The destination's kind (e.g. `planet`, `lagrange`, `star`).
    public var destinationType: String?
    /// Total elapsed time across every leg, in seconds.
    public var totalTimeSeconds: Double?
    /// Total interstellar distance across the route, in light-years (0 for an
    /// intra-system hop).
    public var totalDistanceLy: Double?
    /// The route, in order.
    public var route: [Leg]

    public init(
        finalDestination: String? = nil,
        finalDestinationName: String? = nil,
        destinationType: String? = nil,
        totalTimeSeconds: Double? = nil,
        totalDistanceLy: Double? = nil,
        route: [Leg] = []
    ) {
        self.finalDestination = finalDestination
        self.finalDestinationName = finalDestinationName
        self.destinationType = destinationType
        self.totalTimeSeconds = totalTimeSeconds
        self.totalDistanceLy = totalDistanceLy
        self.route = route
    }

    /// One leg of a route — an intra-system cruise (reports `distance_au`) or an
    /// interstellar surge/jump (reports `distance_ly`).
    public struct Leg: Sendable, Equatable, Codable, Identifiable {
        public var leg: Int?
        public var from: String?
        public var fromName: String?
        public var to: String?
        public var toName: String?
        /// The travel mode for this leg (e.g. `cruise`, `surge`, `jump`).
        public var type: String?
        public var distanceAu: Double?
        public var distanceLy: Double?
        public var timeSeconds: Double?

        /// Stable within a route — legs are numbered from 1.
        public var id: Int { leg ?? 0 }

        public init(
            leg: Int? = nil,
            from: String? = nil,
            fromName: String? = nil,
            to: String? = nil,
            toName: String? = nil,
            type: String? = nil,
            distanceAu: Double? = nil,
            distanceLy: Double? = nil,
            timeSeconds: Double? = nil
        ) {
            self.leg = leg
            self.from = from
            self.fromName = fromName
            self.to = to
            self.toName = toName
            self.type = type
            self.distanceAu = distanceAu
            self.distanceLy = distanceLy
            self.timeSeconds = timeSeconds
        }

        enum CodingKeys: String, CodingKey {
            case leg, from, to, type
            case fromName = "from_name"
            case toName = "to_name"
            case distanceAu = "distance_au"
            case distanceLy = "distance_ly"
            case timeSeconds = "time_seconds"
        }
    }

    enum CodingKeys: String, CodingKey {
        case route
        case finalDestination = "final_destination"
        case finalDestinationName = "final_destination_name"
        case destinationType = "destination_type"
        case totalTimeSeconds = "total_time_seconds"
        case totalDistanceLy = "total_distance_ly"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        finalDestination = try container.decodeIfPresent(String.self, forKey: .finalDestination)
        finalDestinationName = try container.decodeIfPresent(String.self, forKey: .finalDestinationName)
        destinationType = try container.decodeIfPresent(String.self, forKey: .destinationType)
        totalTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .totalTimeSeconds)
        totalDistanceLy = try container.decodeIfPresent(Double.self, forKey: .totalDistanceLy)
        route = try container.decodeIfPresent([Leg].self, forKey: .route) ?? []
    }
}

/// The in-flight or loaded dry-run travel preview backing the confirmation
/// sheet: which device is going where, and the current phase of the request.
/// Shared by the Devices inspector and the star map (both plot the same
/// `travel` command), so the confirmation sheet can read a plain value rather
/// than any feature's store — parallel to `PrintPreview`.
public struct TravelPreview: Equatable, Identifiable, Sendable {
    public let deviceCode: String
    public let destination: String
    public var phase: Phase

    public var id: String { "\(deviceCode)→\(destination)" }

    public enum Phase: Equatable, Sendable {
        case loading
        case loaded(TravelPlan)
        case failed(String)
    }

    public init(deviceCode: String, destination: String, phase: Phase = .loading) {
        self.deviceCode = deviceCode
        self.destination = destination
        self.phase = phase
    }
}

/// The result of a `dry_run` travel preview. `plan` is the itinerary; `rejected`
/// is a server 4xx (e.g. unreachable destination, with the server's message);
/// `failed` is a transport/decoding error.
public enum TravelPreviewOutcome: Sendable, Equatable {
    case plan(TravelPlan)
    case rejected(String)
    case failed(String)

    /// The user-facing message for a non-plan outcome, if any.
    public var failureMessage: String? {
        switch self {
        case .plan: return nil
        case let .rejected(message), let .failed(message): return message
        }
    }
}
