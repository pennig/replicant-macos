import Foundation
import Testing
@testable import GameServices

@Suite struct HaulYieldMachineTests {
    private func digest(
        carried: Int,
        collected: Int = 0,
        delivered: Int = 0,
        device: String? = "F7B455B6",
        deliver: String? = "AINALRAM-BELT-1"
    ) -> TransportDigest {
        TransportDigest(
            controllerCode: "8D53C9B1",
            collect: "ACHERNUR-BELT-1",
            deliver: deliver,
            cargoCarried: carried,
            cargoCapacity: 500,
            collectedCount: collected,
            deliveredCount: delivered,
            activeDeviceCode: device,
            observedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func theFirstDigestOnlySeedsABaseline() {
        #expect(HaulYieldMachine.step(openUnits: nil, digest: digest(carried: 345)) == .none)
    }

    @Test func aRiseIsAPickup() {
        #expect(
            HaulYieldMachine.step(openUnits: 0, digest: digest(carried: 345, collected: 1))
                == .pickup(units: 345, source: "ACHERNUR-BELT-1", deviceCode: "F7B455B6")
        )
    }

    @Test func aFallIsADelivery() {
        #expect(
            HaulYieldMachine.step(openUnits: 345, digest: digest(carried: 0, delivered: 1))
                == .delivery(units: 345, destination: "AINALRAM-BELT-1")
        )
    }

    @Test func anUnchangedCarriedFigureDecidesNothing() {
        #expect(HaulYieldMachine.step(openUnits: 345, digest: digest(carried: 345)) == .none)
    }

    @Test func aSecondStopIsAPickupOfTheIncrementOnly() {
        #expect(
            HaulYieldMachine.step(openUnits: 400, digest: digest(carried: 500, collected: 1))
                == .pickup(units: 100, source: "ACHERNUR-BELT-1", deviceCode: "F7B455B6")
        )
    }

    @Test func aPartialDeliveryReportsOnlyWhatLeftTheHold() {
        #expect(
            HaulYieldMachine.step(openUnits: 500, digest: digest(carried: 100, delivered: 1))
                == .delivery(units: 400, destination: "AINALRAM-BELT-1")
        )
    }

    @Test func aPickupWithNoNamedSourceIsNotRecorded() {
        var d = digest(carried: 345, collected: 1)
        d = TransportDigest(
            controllerCode: d.controllerCode,
            collect: nil,
            deliver: d.deliver,
            cargoCarried: d.cargoCarried,
            cargoCapacity: d.cargoCapacity,
            collectedCount: d.collectedCount,
            deliveredCount: d.deliveredCount,
            activeDeviceCode: d.activeDeviceCode,
            observedAt: d.observedAt
        )
        #expect(HaulYieldMachine.step(openUnits: 0, digest: d) == .none)
    }

    @Test func aPickupWithNoActiveDeviceIsNotRecorded() {
        #expect(
            HaulYieldMachine.step(openUnits: 0, digest: digest(carried: 345, collected: 1, device: nil))
                == .none
        )
    }

    @Test func aDeliveryWithNoNamedDestinationIsNotRecorded() {
        #expect(
            HaulYieldMachine.step(openUnits: 345, digest: digest(carried: 0, delivered: 1, deliver: nil))
                == .none
        )
    }
}
