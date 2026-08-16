import Foundation
import Testing
@testable import GameModels

@Suite("Haul Run directive vocabulary")
struct HaulRunVocabularyTests {

    @Test func theKindHasATitle() {
        #expect(DirectiveKind.haulRun.rawValue == "haulRun")
        #expect(DirectiveKind.haulRun.title == "Haul Run")
    }

    /// Every kind must render a title — a missing arm shows the raw case name to
    /// the user, which is the bug this pins.
    @Test func everyKindRendersATitle() {
        for kind in DirectiveKind.allCases {
            #expect(!kind.title.isEmpty)
        }
    }

    @Test func theStallReasonNamesItsFixWithoutImplyingTheEngineActs() {
        let reason = DirectiveAttentionReason.noHaulControllerTagged
        #expect(reason.rawValue == "noHaulControllerTagged")
        #expect(reason.displayName == "No haul controller tagged")
        #expect(reason.guidance.contains("auto:haul"))
    }

    /// Same completeness rule for the stall matrix: a reason with no guidance
    /// leaves the stall panel with nothing actionable in it.
    @Test func everyReasonRendersDisplayNameAndGuidance() {
        for reason in DirectiveAttentionReason.allCases {
            #expect(!reason.displayName.isEmpty)
            #expect(!reason.guidance.isEmpty)
        }
    }

    @Test func commandFailedIsAnAutoRetriedTransient() {
        let reason = DirectiveAttentionReason.commandFailed
        #expect(reason.displayName == "Command failed")
        #expect(reason.guidance == "The server or the connection failed while sending the last command. It was retried three times. Retry once the service is reachable, or skip this target.")
        #expect(reason.brainDisposition == .retry)
    }
}

@Suite("Mine directive vocabulary")
struct MineDirectiveVocabularyTests {
    @Test("the two mine kinds carry list-row titles")
    func titles() {
        #expect(DirectiveKind.mineFleetPrint.title == "Mine Fleet Print")
        #expect(DirectiveKind.mineRun.title == "Mine Run")
    }

    @Test("an incomplete mine fleet escalates rather than auto-retrying")
    func disposition() {
        #expect(DirectiveAttentionReason.mineFleetIncomplete.brainDisposition == .escalate)
    }
}
