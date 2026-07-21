//
//  CommandClient+Topology.swift
//  Replicould — GameServices (shared clients + command engine)
//
//  The topology family: `adopt`/`release` (AMI controller ↔ controlled
//  devices) and `attach`/`detach` (carrier ↔ carried devices). These commands
//  move *other* devices onto or off the targeted one, so the family also owns
//  reading the response's affected-device blocks and refreshing each.
//

import API
import Dependencies
import Foundation
import Utils

extension CommandClient {
    private typealias AdoptSchema = Components.Schemas.AppSchemasDeviceCommandsAdoptSchema
    private typealias ReleaseSchema = Components.Schemas.AppSchemasDeviceCommandsReleaseSchema
    private typealias AttachSchema = Components.Schemas.AppSchemasDeviceCommandsAttachSchema
    private typealias DetachSchema = Components.Schemas.AppSchemasDeviceCommandsDetachSchema

    static func adoptBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let devices = params.devices, !devices.isEmpty else { throw CommandError.missingParameter("devices") }
        return .json(.adopt(try devicesSchema(AdoptSchema.self, command: "adopt", devices: devices)))
    }

    static func releaseBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        guard let devices = params.devices, !devices.isEmpty else { throw CommandError.missingParameter("devices") }
        return .json(.release(try devicesSchema(ReleaseSchema.self, command: "release", devices: devices)))
    }

    static func attachBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        // Attach carries its device codes under `targets` (per the API docs),
        // not `devices` like adopt/release. Same untyped-container shape, so
        // reuse the JSON round-trip with the `targets` key.
        guard let devices = params.devices, !devices.isEmpty else { throw CommandError.missingParameter("targets") }
        return .json(.attach(try devicesSchema(AttachSchema.self, command: "attach", devices: devices, key: "targets")))
    }

    static func detachBody(_ params: CommandParams) throws -> Operations.PostV1DevicesDeviceCode.Input.Body {
        // Detach names the target(s) to remove (the server would detach
        // everything if omitted, but the UI always picks a device). Same
        // `targets` shape as attach.
        guard let devices = params.devices, !devices.isEmpty else { throw CommandError.missingParameter("targets") }
        return .json(.detach(try devicesSchema(DetachSchema.self, command: "detach", devices: devices, key: "targets")))
    }

    /// Topology commands move *other* devices onto or off the targeted one —
    /// the response names them in an `attached`/`detached`/`adopted`/`released`
    /// block. Read each so its status/carrier/controller reflects the new
    /// topology now, rather than lagging until the next poll.
    static func refreshAffectedDevices(in responseJSON: JSONValue, excluding deviceCode: String) async {
        @Dependency(\.deviceRefresher) var deviceRefresher
        for code in affectedDeviceCodes(in: responseJSON) where code != deviceCode {
            _ = await deviceRefresher.refresh(code, .high)
        }
    }

    /// The device codes a topology command reports it moved, gathered from the
    /// response's `attached`/`detached`/`adopted`/`released` blocks. Each block is
    /// an array of bare codes or `{device_code, …}` objects (both handled).
    private static func affectedDeviceCodes(in json: JSONValue) -> [String] {
        var codes: [String] = []
        for key in ["attached", "detached", "adopted", "released"] {
            guard let items = json[key]?.arrayValue else { continue }
            for item in items {
                if let code = item["device_code"]?.stringValue ?? item.stringValue {
                    codes.append(code)
                }
            }
        }
        return codes
    }

    /// Build an `adopt`/`release`/`attach`/`detach` body carrying a device-code
    /// array under `key` (`devices` for adopt/release, `targets` for
    /// attach/detach). Those generated schemas type the field as an untyped
    /// `OpenAPIValueContainer` (the spec leaves it schemaless), so round-trip a
    /// `{command, <key>}` object through JSON — the decoder wraps the string
    /// array into the container without hand-bridging.
    private static func devicesSchema<Schema: Decodable>(
        _ type: Schema.Type, command: String, devices: [String], key: String = "devices"
    ) throws -> Schema {
        let json = JSONValue.object([
            "command": .string(command),
            key: .array(devices.map(JSONValue.string)),
        ])
        let data = try jsonEncoder.encode(json)
        return try JSONDecoder().decode(Schema.self, from: data)
    }
}
