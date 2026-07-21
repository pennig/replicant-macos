//
//  CommandClient+Travel.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The travel family: the parameterized `travel` command body and the dry-run
//  preview (`dry_run: true` — the server plots the route without dispatching
//  the device, so the user can confirm the itinerary first).
//

import API
import ComposableArchitecture
import Foundation
import GameModels
import OSLog

private let logger = Logger(subsystem: "name.pennig.replicould", category: "Command")

extension CommandClient {
    static func travelBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let destination = params.destination else { throw CommandError.missingParameter("destination") }
        return .json(.travel(.init(command: "travel", destination: destination)))
    }

    /// The live `previewTravel` implementation: same endpoint, `dry_run: true`.
    /// The server plots the route and returns it with `status: "preview"` and no
    /// `arrives_at` — nothing is dispatched, so we stage no op and take no
    /// device read.
    static func previewTravelLive(deviceCode: String, destination: String) async -> TravelPreviewOutcome {
        @Dependency(\.gameClient) var gameClient

        let body: Operations.PostV1DevicesDeviceCode.Input.Body =
            .json(.travel(.init(command: "travel", destination: destination, dryRun: true)))
        do {
            let output = try await gameClient().postV1DevicesDeviceCode(
                path: .init(deviceCode: deviceCode), body: body
            )
            switch output {
            case let .ok(ok):
                let response = try ok.body.json
                guard let plan = travelPlan(from: response) else {
                    logger.warning("preview travel → \(deviceCode, privacy: .public): unreadable plan")
                    return .failed("Couldn’t read the travel preview.")
                }
                logger.info("preview travel → \(deviceCode, privacy: .public): \(plan.route.count, privacy: .public) leg(s)")
                return .plan(plan)
            case let .badRequest(response):
                let reason = errorMessage(response.body)
                logger.warning("preview travel → \(deviceCode, privacy: .public): rejected (400) — \(reason, privacy: .public)")
                return .rejected(reason)
            case let .forbidden(response):
                let reason = errorMessage(response.body)
                logger.warning("preview travel → \(deviceCode, privacy: .public): rejected (403) — \(reason, privacy: .public)")
                return .rejected(reason)
            case let .notFound(response):
                let reason = errorMessage(response.body)
                logger.warning("preview travel → \(deviceCode, privacy: .public): rejected (404) — \(reason, privacy: .public)")
                return .rejected(reason)
            case let .default(statusCode, _):
                return .failed("Server error (\(statusCode)).")
            case .created:
                return .failed("Unexpected server response.")
            @unknown default:
                return .failed("Unexpected server response.")
            }
        } catch {
            logger.error("preview travel → \(deviceCode, privacy: .public): failed — \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Decode a dry-run travel response into a `TravelPlan`. The generated route
    /// legs are untyped (`additionalProperties`), so we round-trip the response
    /// through JSON — the re-encode preserves the raw leg keys — and decode the
    /// typed plan from that.
    private static func travelPlan(
        from response: Components.Schemas.AppSchemasDevicesDeviceCommandResponseSchema
    ) -> TravelPlan? {
        guard
            let data = try? jsonEncoder.encode(response),
            let plan = try? JSONDecoder().decode(TravelPlan.self, from: data)
        else { return nil }
        return plan
    }
}
