//
//  PrintQueuePresentationTests.swift
//  Replicould — PrintQueueFeature
//
//  `jobID` resets the progress bar's end latch per job. Get it wrong and a
//  bench printing the same type twice keeps the second bar pinned at "done".
//

import Foundation
import GameModels
import Testing

@testable import PrintQueueFeature

@Suite("Print job identity")
struct PrintQueuePresentationTests {

    private func printing(_ type: String, startedAt: TimeInterval) -> PrintingSnapshot {
        PrintingSnapshot(
            deviceType: type,
            startedAt: Date(timeIntervalSinceReferenceDate: startedAt),
            completesAt: Date(timeIntervalSinceReferenceDate: startedAt + 600)
        )
    }

    @Test("the same job on the same bench keeps one identity")
    func stableAcrossReads() {
        let job = printing("thermal_lance", startedAt: 1_000)

        #expect(
            PrintQueuePresentation.jobID(deviceCode: "B1", printing: job)
                == PrintQueuePresentation.jobID(deviceCode: "B1", printing: job)
        )
    }

    /// The case the device-code-plus-type key missed: a bench working the
    /// second unit of a batch is on a new job, and its bar must start over.
    @Test("a repeat print of the same type is a new job")
    func repeatPrintIsANewJob() {
        #expect(
            PrintQueuePresentation.jobID(deviceCode: "B1", printing: printing("thermal_lance", startedAt: 1_000))
                != PrintQueuePresentation.jobID(deviceCode: "B1", printing: printing("thermal_lance", startedAt: 1_600))
        )
    }

    @Test("two benches printing the same type at once stay distinct")
    func benchesStayDistinct() {
        let job = printing("thermal_lance", startedAt: 1_000)

        #expect(
            PrintQueuePresentation.jobID(deviceCode: "B1", printing: job)
                != PrintQueuePresentation.jobID(deviceCode: "B2", printing: job)
        )
    }

    @Test("a different device type is a different job")
    func differentTypeIsADifferentJob() {
        #expect(
            PrintQueuePresentation.jobID(deviceCode: "B1", printing: printing("thermal_lance", startedAt: 1_000))
                != PrintQueuePresentation.jobID(deviceCode: "B1", printing: printing("atmo_processor", startedAt: 1_000))
        )
    }
}
