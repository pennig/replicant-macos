//
//  CommandClient+Printing.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The printing family: `enqueue_print` (enqueued — completes via a later
//  stream event) and `dequeue_print` (remove a queued job by position).
//

import API
import Foundation

extension CommandClient {
    static func printBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let deviceType = params.deviceType else { throw CommandError.missingParameter("device_type") }
        return .json(.enqueuePrint(.init(command: "enqueue_print", deviceType: deviceType)))
    }

    static func dequeuePrintBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let index = params.index else { throw CommandError.missingParameter("index") }
        return .json(.dequeuePrint(.init(command: "dequeue_print", index: index)))
    }
}
