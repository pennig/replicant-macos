//  Pins the two shapes `GET /v1/devices/{device_code}` returns against the strict
//  generated decoder. `app_schemas_devices_DeviceStatusSchema` is
//  `additionalProperties: false`, so an undeclared key throws rather than being ignored.

import Foundation
import Testing
import API

struct DeviceStatusResponseDecodingTests {
    private typealias Response = Components.Schemas.AppSchemasDevicesDeviceStatusSchema

    private func decode(_ json: String) throws -> Response {
        try JSONDecoder().decode(Response.self, from: Data(json.utf8))
    }

    // A device you own reports its own state and carries no owner block.
    @Test func decodesOwnedDeviceWithCatalogueCopy() throws {
        let response = try decode(
            """
            {
              "available_commands": ["deploy", "stow"],
              "description": "The FTL slingshot is a dense, heat-hungry transmitter.",
              "device_code": "94B00DE8",
              "device_type": "ftl_slingshot",
              "features": ["slingshot", "stow"],
              "linked_device": "1F6A12EB",
              "location": "OMEROPE",
              "operational_capacity": 5,
              "replicant_code": "99380EDF",
              "short_description": "A high-energy subspace transmitter.",
              "status": "out_of_range"
            }
            """)

        #expect(response.status == "out_of_range")
        #expect(response.shortDescription == "A high-energy subspace transmitter.")
        #expect(response.description?.hasPrefix("The FTL slingshot") == true)
        #expect(response.owner == nil)
    }

    // A device someone else owns reports an owner block instead of status/replicant_code.
    @Test func decodesForeignDeviceWithOwner() throws {
        let response = try decode(
            """
            {
              "description": "The FTL slingshot is a dense, heat-hungry transmitter.",
              "device_code": "94B00DE8",
              "device_type": "ftl_slingshot",
              "features": ["slingshot", "stow"],
              "location": "OMEROPE-BELT-1",
              "owner": {
                "name": "pennig-1",
                "replicant_code": "99380EDF"
              },
              "short_description": "A high-energy subspace transmitter."
            }
            """)

        #expect(response.owner?.name == "pennig-1")
        #expect(response.owner?.replicantCode == "99380EDF")
        #expect(response.deviceType == "ftl_slingshot")
        #expect(response.status == nil)
        #expect(response.replicantCode == nil)
    }

    // Most devices send neither copy field; absent is not null.
    @Test func decodesDeviceWithoutCatalogueCopy() throws {
        let response = try decode(
            """
            {
              "device_code": "32658E70",
              "device_type": "mining_drone",
              "status": "idle"
            }
            """)

        #expect(response.shortDescription == nil)
        #expect(response.description == nil)
    }
}
