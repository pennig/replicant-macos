//  Pins the mine-command response shape against the strict generated decoder.
//  `app_schemas_devices_DeviceCommandResponseSchema` is `additionalProperties: false`,
//  so an undeclared key throws rather than being ignored.

import Foundation
import Testing
import API

struct DeviceCommandResponseDecodingTests {
    private typealias Response = Components.Schemas.AppSchemasDevicesDeviceCommandResponseSchema

    private func decode(_ json: String) throws -> Response {
        try JSONDecoder().decode(Response.self, from: Data(json.utf8))
    }

    @Test func decodesBeltMineStart() throws {
        let response = try decode(
            """
            {
              "availability": "moderate",
              "belt": "OMEROPE-BELT-1",
              "cycle_time_seconds": 37,
              "density": "dense",
              "designation": "OMEROPE-BELT-1-SITE-0",
              "device_code": "8FA61A04",
              "location": "OMEROPE-BELT-1",
              "location_type": "belt",
              "resource_type": "conductive",
              "salvage_type": null,
              "site": "OMEROPE-BELT-1-SITE-0",
              "status": "mining_started"
            }
            """)

        #expect(response.status == "mining_started")
        #expect(response.locationType == "belt")
        #expect(response.site == "OMEROPE-BELT-1-SITE-0")
        #expect(response.designation == "OMEROPE-BELT-1-SITE-0")
        #expect(response.salvageType == nil)
    }

    // A salvage site carries `salvage_type` and reports no belt density/availability.
    @Test func decodesSalvageMineStart() throws {
        let response = try decode(
            """
            {
              "availability": null,
              "density": null,
              "device_code": "8FA61A04",
              "location_type": "salvage",
              "salvage_type": "derelict_probe",
              "site": "OMEROPE-1-SITE-0",
              "status": "mining_started"
            }
            """)

        #expect(response.locationType == "salvage")
        #expect(response.salvageType == "derelict_probe")
        #expect(response.density == nil)
        #expect(response.availability == nil)
    }
}
