//  Pins device-command response shapes against the strict generated decoder.
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

    // `arrival_time` is nullable, matching upstream's own `TravelResponseSchema`.
    @Test func decodesTravelStartWithArrivalTime() throws {
        let response = try decode(
            """
            {
              "arrival_time": "2026-08-14T12:34:56Z",
              "arrives_at": "2026-08-14T12:34:56Z",
              "departed_at": "2026-08-14T12:04:56Z",
              "destination": "OMEROPE-BELT-1",
              "device_code": "8FA61A04",
              "origin": "OMEROPE",
              "status": "travel_started",
              "total_distance_ly": 4.2
            }
            """)

        #expect(response.status == "travel_started")
        #expect(response.arrivalTime == "2026-08-14T12:34:56Z")

        let nullArrival = try decode(#"{"arrival_time": null, "status": "travel_started"}"#)
        #expect(nullArrival.arrivalTime == nil)
    }
}
