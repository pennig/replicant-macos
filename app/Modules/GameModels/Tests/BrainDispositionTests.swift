import Testing
@testable import GameModels

@Suite struct BrainDispositionTests {
    @Test func retryReasonsSelfCorrectOnReRead() {
        let retry: [DirectiveAttentionReason] = [
            .surveyIncomplete, .unreachableDevice, .vesselPositionUnconfirmed,
            .salvageSystemUnresolved, .salvageBodyNotDepleted, .commandRejected,
            .relayActivationFailed, .printStockShort,
        ]
        for r in retry { #expect(r.brainDisposition == .retry, "\(r) should be retry") }
    }

    @Test func escalateReasonsNeedAPowerTheBrainLacks() {
        let escalate: [DirectiveAttentionReason] = [
            .noSurveyControllerAboard, .noSurveyDroneAboard, .noMiningControllerAboard,
            .noMiningDroneAboard, .noRelayCoLocated, .dronesNotRecovered,
            .launchDeployedNothing, .noHaulControllerTagged, .awaitingRelayRestock,
            .repairUnfinished, .serviceBotNotArmed, .serviceBotNotRecovered,
        ]
        for r in escalate { #expect(r.brainDisposition == .escalate, "\(r) should be escalate") }
    }
}
