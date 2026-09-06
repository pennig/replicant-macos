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

    // A hub-to-hub travel reply carries `hub_bonus`; undeclared, it threw and the
    // retry was rejected into a device already in transit.
    @Test func decodesTravelStartWithHubBonus() throws {
        let response = try decode(
            """
            {
              "arrives_at": "2026-08-21T15:34:56Z",
              "destination": "AINALRAM",
              "device_code": "F2908E6E",
              "hub_bonus": true,
              "origin": "ENASHIRA",
              "status": "travel_started",
              "travel_type": "surge"
            }
            """)

        #expect(response.status == "travel_started")
        #expect(response.hubBonus == true)

        let absent = try decode(#"{"status": "travel_started"}"#)
        #expect(absent.hubBonus == nil)
    }

    // A sensor array sweeping the outer system reports the belt it swept.
    @Test func decodesDetectObjectStart() throws {
        let response = try decode(
            """
            {
              "completes_at": "2026-09-01T23:03:53+01:00",
              "detect_target": "DELTA-KUIPER",
              "device_code": "F652A584",
              "eta_seconds": 3600,
              "started_at": "2026-09-01T22:03:53+01:00",
              "status": "detect_started"
            }
            """)

        #expect(response.status == "detect_started")
        #expect(response.detectTarget == "DELTA-KUIPER")
        #expect(response.etaSeconds == 3600)
    }

    // A vector charge launching a Kuiper body reports the whole trajectory.
    @Test func decodesDetonateLaunch() throws {
        let response = try decode(
            """
            {
              "approach_angle": 8.7,
              "approach_speed": 0.79,
              "composition": "carbonaceous",
              "destination": "DELTA-3",
              "device_code": "FC838B3F",
              "impact_eta": "2026-09-02T21:03:55.524215",
              "kuiper_object": "DELTA-KUIPER-001",
              "mass_class": "large",
              "object_designation": "DELTA-OBJ-3",
              "status": "launched"
            }
            """)

        #expect(response.status == "launched")
        #expect(response.approachAngle == 8.7)
        #expect(response.approachSpeed == 0.79)
        #expect(response.composition == "carbonaceous")
        #expect(response.kuiperObject == "DELTA-KUIPER-001")
        #expect(response.massClass == "large")
        #expect(response.objectDesignation == "DELTA-OBJ-3")
    }

    // No response property is `required`, so an explicit null decodes to nil and a
    // non-nullable declaration is safe for keys we have never seen arrive null.
    @Test func explicitNullDecodesToNilOnANonNullableKey() throws {
        let response = try decode(#"{"status": "launched", "impact_eta": null}"#)
        #expect(response.impactEta == nil)
    }
}
