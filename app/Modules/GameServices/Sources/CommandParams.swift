//
//  CommandParams.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The one parameter bag every command family draws from. Only the fields a
//  given command needs are set; each family's body builder (see the
//  `CommandClient+<Family>` files) validates the fields it requires and fails
//  fast — before any optimistic row is staged.
//

import Foundation
import Utils

/// Command-specific parameters. Only the fields a given command needs are set.
public struct CommandParams: Sendable, Equatable {
    public var destination: String?   // travel
    public var deviceType: String?    // print (enqueue_print)
    public var resourceType: String?  // mine (start_mining) — one of the belt resources
    public var target: String?        // mine — optional resource-site designation
    public var directive: String?     // set_directive — one of the device's available_directives
    /// configure — a surge plate's carry mode: "taxi" or "manual".
    public var mode: String?
    /// message — the BobNet channel to post into, and the message body.
    public var channel: String?
    public var text: String?
    public var index: Int?            // dequeue_print — the queue position to remove
    public var quantity: Int?         // enqueue_print — units to print
    /// enqueue_print — tags applied to the printed device (wire key `tags`).
    public var printTags: [String]?
    /// enqueue_print — print the device already compacted, which only a modular
    /// type can be. nil leaves the key off the wire, where the default is false.
    public var flatpack: Bool?
    /// set_directive — the directive's optional configuration object (e.g. a
    /// survey controller's `{planets, moons, recall}`). Loosely typed since the
    /// shape varies per directive; nil/empty omits it.
    public var configuration: [String: JSONValue]?
    /// adopt — the device codes an AMI controller should take under its control.
    public var devices: [String]?
    /// collect_resources / deposit_resources — a per-type map of how many units of
    /// each resource to load into (or unload from) a transport's cargo hold. For a
    /// deposit, nil/empty means "empty the entire hold at the current location".
    public var resources: [String: Int]?

    public init(
        destination: String? = nil,
        deviceType: String? = nil,
        resourceType: String? = nil,
        target: String? = nil,
        directive: String? = nil,
        mode: String? = nil,
        channel: String? = nil,
        text: String? = nil,
        index: Int? = nil,
        quantity: Int? = nil,
        printTags: [String]? = nil,
        flatpack: Bool? = nil,
        configuration: [String: JSONValue]? = nil,
        devices: [String]? = nil,
        resources: [String: Int]? = nil
    ) {
        self.destination = destination
        self.deviceType = deviceType
        self.resourceType = resourceType
        self.target = target
        self.directive = directive
        self.mode = mode
        self.channel = channel
        self.text = text
        self.index = index
        self.quantity = quantity
        self.printTags = printTags
        self.flatpack = flatpack
        self.configuration = configuration
        self.devices = devices
        self.resources = resources
    }

    var json: JSONValue {
        var dict: [String: JSONValue] = [:]
        if let destination { dict["destination"] = .string(destination) }
        if let deviceType { dict["device_type"] = .string(deviceType) }
        if let resourceType { dict["resource_type"] = .string(resourceType) }
        if let target { dict["target"] = .string(target) }
        if let directive { dict["directive"] = .string(directive) }
        if let mode { dict["mode"] = .string(mode) }
        if let channel { dict["channel"] = .string(channel) }
        if let text { dict["text"] = .string(text) }
        if let index { dict["index"] = .number(Double(index)) }
        if let quantity { dict["quantity"] = .number(Double(quantity)) }
        if let printTags { dict["tags"] = .array(printTags.map(JSONValue.string)) }
        if let flatpack { dict["flatpack"] = .bool(flatpack) }
        if let configuration, !configuration.isEmpty { dict["configuration"] = .object(configuration) }
        if let devices, !devices.isEmpty { dict["devices"] = .array(devices.map(JSONValue.string)) }
        if let resources, !resources.isEmpty {
            dict["resources"] = .object(resources.mapValues { .number(Double($0)) })
        }
        return .object(dict)
    }

    /// Canonical form for de-dup: the SET fields only, keys sorted, no whitespace.
    public var dedupKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(json), as: UTF8.self)) ?? "{}"
    }

    /// The one field worth naming in a timeline summary, whichever this
    /// dispatch set. For `set_directive`, `configuration`'s `collect` (a
    /// pile) beats the directive name, which rarely varies.
    public var summaryDetail: String? {
        if let destination { return destination }
        if let deviceType { return deviceType }
        if let target { return target }
        if let directive {
            if let collect = configuration?["collect"]?.stringValue {
                return "collect \(collect)"
            }
            return directive
        }
        return nil
    }
}
