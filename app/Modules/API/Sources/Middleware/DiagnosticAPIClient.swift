//
//  DiagnosticAPIClient.swift
//  API
//
//  A transparent `APIProtocol` decorator that routes EVERY generated operation
//  through `DecodingDiagnostics.capture`, so a response-body decode failure
//  (server/spec drift) is logged with its exact coding path from ONE place —
//  something a `ClientMiddleware` can't do (decode happens after middleware
//  returns). Call sites stay clean: `GameClient.make()` vends `any APIProtocol`,
//  so domain clients call operations exactly as before and this wrapper catches,
//  logs, and rethrows unchanged.
//
//  GENERATED, then committed: regenerate with `scripts/gen-diagnostic-client.py`
//  (or by hand) if the API surface changes — it mirrors `APIProtocol`'s
//  requirements 1:1, so a stale copy simply fails to compile against the protocol.
//

import OpenAPIRuntime

public struct DiagnosticAPIClient: APIProtocol {
    public let wrapped: any APIProtocol
    public init(wrapped: any APIProtocol) { self.wrapped = wrapped }

    public func postV1Accounts(_ input: Operations.PostV1Accounts.Input) async throws -> Operations.PostV1Accounts.Output {
        try await DecodingDiagnostics.capture("postV1Accounts") { try await wrapped.postV1Accounts(input) }
    }
    public func postV1AccountsRecover(_ input: Operations.PostV1AccountsRecover.Input) async throws -> Operations.PostV1AccountsRecover.Output {
        try await DecodingDiagnostics.capture("postV1AccountsRecover") { try await wrapped.postV1AccountsRecover(input) }
    }
    public func getV1AccountsVerifyToken(_ input: Operations.GetV1AccountsVerifyToken.Input) async throws -> Operations.GetV1AccountsVerifyToken.Output {
        try await DecodingDiagnostics.capture("getV1AccountsVerifyToken") { try await wrapped.getV1AccountsVerifyToken(input) }
    }
    public func getV1AccountsMe(_ input: Operations.GetV1AccountsMe.Input) async throws -> Operations.GetV1AccountsMe.Output {
        try await DecodingDiagnostics.capture("getV1AccountsMe") { try await wrapped.getV1AccountsMe(input) }
    }
    public func patchV1AccountsMe(_ input: Operations.PatchV1AccountsMe.Input) async throws -> Operations.PatchV1AccountsMe.Output {
        try await DecodingDiagnostics.capture("patchV1AccountsMe") { try await wrapped.patchV1AccountsMe(input) }
    }
    public func deleteV1AccountsMe(_ input: Operations.DeleteV1AccountsMe.Input) async throws -> Operations.DeleteV1AccountsMe.Output {
        try await DecodingDiagnostics.capture("deleteV1AccountsMe") { try await wrapped.deleteV1AccountsMe(input) }
    }
    public func getV1AccountsAchievements(_ input: Operations.GetV1AccountsAchievements.Input) async throws -> Operations.GetV1AccountsAchievements.Output {
        try await DecodingDiagnostics.capture("getV1AccountsAchievements") { try await wrapped.getV1AccountsAchievements(input) }
    }
    public func getV1AccountsSimulations(_ input: Operations.GetV1AccountsSimulations.Input) async throws -> Operations.GetV1AccountsSimulations.Output {
        try await DecodingDiagnostics.capture("getV1AccountsSimulations") { try await wrapped.getV1AccountsSimulations(input) }
    }
    public func getV1AccountsWebhook(_ input: Operations.GetV1AccountsWebhook.Input) async throws -> Operations.GetV1AccountsWebhook.Output {
        try await DecodingDiagnostics.capture("getV1AccountsWebhook") { try await wrapped.getV1AccountsWebhook(input) }
    }
    public func postV1AccountsWebhook(_ input: Operations.PostV1AccountsWebhook.Input) async throws -> Operations.PostV1AccountsWebhook.Output {
        try await DecodingDiagnostics.capture("postV1AccountsWebhook") { try await wrapped.postV1AccountsWebhook(input) }
    }
    public func deleteV1AccountsWebhook(_ input: Operations.DeleteV1AccountsWebhook.Input) async throws -> Operations.DeleteV1AccountsWebhook.Output {
        try await DecodingDiagnostics.capture("deleteV1AccountsWebhook") { try await wrapped.deleteV1AccountsWebhook(input) }
    }
    public func getV1Achievements(_ input: Operations.GetV1Achievements.Input) async throws -> Operations.GetV1Achievements.Output {
        try await DecodingDiagnostics.capture("getV1Achievements") { try await wrapped.getV1Achievements(input) }
    }
    public func getV1AchievementsAchievementKey(_ input: Operations.GetV1AchievementsAchievementKey.Input) async throws -> Operations.GetV1AchievementsAchievementKey.Output {
        try await DecodingDiagnostics.capture("getV1AchievementsAchievementKey") { try await wrapped.getV1AchievementsAchievementKey(input) }
    }
    public func getV1Replicants(_ input: Operations.GetV1Replicants.Input) async throws -> Operations.GetV1Replicants.Output {
        try await DecodingDiagnostics.capture("getV1Replicants") { try await wrapped.getV1Replicants(input) }
    }
    public func getV1ReplicantsReplicantCode(_ input: Operations.GetV1ReplicantsReplicantCode.Input) async throws -> Operations.GetV1ReplicantsReplicantCode.Output {
        try await DecodingDiagnostics.capture("getV1ReplicantsReplicantCode") { try await wrapped.getV1ReplicantsReplicantCode(input) }
    }
    public func patchV1ReplicantsReplicantCode(_ input: Operations.PatchV1ReplicantsReplicantCode.Input) async throws -> Operations.PatchV1ReplicantsReplicantCode.Output {
        try await DecodingDiagnostics.capture("patchV1ReplicantsReplicantCode") { try await wrapped.patchV1ReplicantsReplicantCode(input) }
    }
    public func postV1ReplicantsReplicantCodeTeleport(_ input: Operations.PostV1ReplicantsReplicantCodeTeleport.Input) async throws -> Operations.PostV1ReplicantsReplicantCodeTeleport.Output {
        try await DecodingDiagnostics.capture("postV1ReplicantsReplicantCodeTeleport") { try await wrapped.postV1ReplicantsReplicantCodeTeleport(input) }
    }
    public func postV1ReplicantsReplicantCodeMessage(_ input: Operations.PostV1ReplicantsReplicantCodeMessage.Input) async throws -> Operations.PostV1ReplicantsReplicantCodeMessage.Output {
        try await DecodingDiagnostics.capture("postV1ReplicantsReplicantCodeMessage") { try await wrapped.postV1ReplicantsReplicantCodeMessage(input) }
    }
    public func postV1ReplicantsReplicantCodeTransfer(_ input: Operations.PostV1ReplicantsReplicantCodeTransfer.Input) async throws -> Operations.PostV1ReplicantsReplicantCodeTransfer.Output {
        try await DecodingDiagnostics.capture("postV1ReplicantsReplicantCodeTransfer") { try await wrapped.postV1ReplicantsReplicantCodeTransfer(input) }
    }
    public func getV1ReplicantsReplicantCodeStars(_ input: Operations.GetV1ReplicantsReplicantCodeStars.Input) async throws -> Operations.GetV1ReplicantsReplicantCodeStars.Output {
        try await DecodingDiagnostics.capture("getV1ReplicantsReplicantCodeStars") { try await wrapped.getV1ReplicantsReplicantCodeStars(input) }
    }
    public func getV1ReplicantsReplicantCodeStarsStarDesignation(_ input: Operations.GetV1ReplicantsReplicantCodeStarsStarDesignation.Input) async throws -> Operations.GetV1ReplicantsReplicantCodeStarsStarDesignation.Output {
        try await DecodingDiagnostics.capture("getV1ReplicantsReplicantCodeStarsStarDesignation") { try await wrapped.getV1ReplicantsReplicantCodeStarsStarDesignation(input) }
    }
    public func postV1ReplicantsReplicantCodeTravel(_ input: Operations.PostV1ReplicantsReplicantCodeTravel.Input) async throws -> Operations.PostV1ReplicantsReplicantCodeTravel.Output {
        try await DecodingDiagnostics.capture("postV1ReplicantsReplicantCodeTravel") { try await wrapped.postV1ReplicantsReplicantCodeTravel(input) }
    }
    public func deleteV1ReplicantsReplicantCodeTravel(_ input: Operations.DeleteV1ReplicantsReplicantCodeTravel.Input) async throws -> Operations.DeleteV1ReplicantsReplicantCodeTravel.Output {
        try await DecodingDiagnostics.capture("deleteV1ReplicantsReplicantCodeTravel") { try await wrapped.deleteV1ReplicantsReplicantCodeTravel(input) }
    }
    public func postV1ReplicantsReplicantCodeScan(_ input: Operations.PostV1ReplicantsReplicantCodeScan.Input) async throws -> Operations.PostV1ReplicantsReplicantCodeScan.Output {
        try await DecodingDiagnostics.capture("postV1ReplicantsReplicantCodeScan") { try await wrapped.postV1ReplicantsReplicantCodeScan(input) }
    }
    public func getV1ReplicantsReplicantCodeScanDevices(_ input: Operations.GetV1ReplicantsReplicantCodeScanDevices.Input) async throws -> Operations.GetV1ReplicantsReplicantCodeScanDevices.Output {
        try await DecodingDiagnostics.capture("getV1ReplicantsReplicantCodeScanDevices") { try await wrapped.getV1ReplicantsReplicantCodeScanDevices(input) }
    }
    public func getV1ReplicantsReplicantCodeDevices(_ input: Operations.GetV1ReplicantsReplicantCodeDevices.Input) async throws -> Operations.GetV1ReplicantsReplicantCodeDevices.Output {
        try await DecodingDiagnostics.capture("getV1ReplicantsReplicantCodeDevices") { try await wrapped.getV1ReplicantsReplicantCodeDevices(input) }
    }
    public func getV1DevicesDeviceCode(_ input: Operations.GetV1DevicesDeviceCode.Input) async throws -> Operations.GetV1DevicesDeviceCode.Output {
        try await DecodingDiagnostics.capture("getV1DevicesDeviceCode") { try await wrapped.getV1DevicesDeviceCode(input) }
    }
    public func postV1DevicesDeviceCode(_ input: Operations.PostV1DevicesDeviceCode.Input) async throws -> Operations.PostV1DevicesDeviceCode.Output {
        try await DecodingDiagnostics.capture("postV1DevicesDeviceCode") { try await wrapped.postV1DevicesDeviceCode(input) }
    }
    public func patchV1DevicesDeviceCode(_ input: Operations.PatchV1DevicesDeviceCode.Input) async throws -> Operations.PatchV1DevicesDeviceCode.Output {
        try await DecodingDiagnostics.capture("patchV1DevicesDeviceCode") { try await wrapped.patchV1DevicesDeviceCode(input) }
    }
    public func getV1DevicesTagsTag(_ input: Operations.GetV1DevicesTagsTag.Input) async throws -> Operations.GetV1DevicesTagsTag.Output {
        try await DecodingDiagnostics.capture("getV1DevicesTagsTag") { try await wrapped.getV1DevicesTagsTag(input) }
    }
    public func getV1Devices(_ input: Operations.GetV1Devices.Input) async throws -> Operations.GetV1Devices.Output {
        try await DecodingDiagnostics.capture("getV1Devices") { try await wrapped.getV1Devices(input) }
    }
    public func getV1DevicesDeviceCodeLogs(_ input: Operations.GetV1DevicesDeviceCodeLogs.Input) async throws -> Operations.GetV1DevicesDeviceCodeLogs.Output {
        try await DecodingDiagnostics.capture("getV1DevicesDeviceCodeLogs") { try await wrapped.getV1DevicesDeviceCodeLogs(input) }
    }
    public func getV1DevicesDeviceCodeNetwork(_ input: Operations.GetV1DevicesDeviceCodeNetwork.Input) async throws -> Operations.GetV1DevicesDeviceCodeNetwork.Output {
        try await DecodingDiagnostics.capture("getV1DevicesDeviceCodeNetwork") { try await wrapped.getV1DevicesDeviceCodeNetwork(input) }
    }
    public func getV1DevicesDeviceCodeChannels(_ input: Operations.GetV1DevicesDeviceCodeChannels.Input) async throws -> Operations.GetV1DevicesDeviceCodeChannels.Output {
        try await DecodingDiagnostics.capture("getV1DevicesDeviceCodeChannels") { try await wrapped.getV1DevicesDeviceCodeChannels(input) }
    }
    public func getV1DevicesDeviceCodeMessages(_ input: Operations.GetV1DevicesDeviceCodeMessages.Input) async throws -> Operations.GetV1DevicesDeviceCodeMessages.Output {
        try await DecodingDiagnostics.capture("getV1DevicesDeviceCodeMessages") { try await wrapped.getV1DevicesDeviceCodeMessages(input) }
    }
    public func getV1DevicesDeviceCodePermissions(_ input: Operations.GetV1DevicesDeviceCodePermissions.Input) async throws -> Operations.GetV1DevicesDeviceCodePermissions.Output {
        try await DecodingDiagnostics.capture("getV1DevicesDeviceCodePermissions") { try await wrapped.getV1DevicesDeviceCodePermissions(input) }
    }
    public func postV1DevicesDeviceCodePermissions(_ input: Operations.PostV1DevicesDeviceCodePermissions.Input) async throws -> Operations.PostV1DevicesDeviceCodePermissions.Output {
        try await DecodingDiagnostics.capture("postV1DevicesDeviceCodePermissions") { try await wrapped.postV1DevicesDeviceCodePermissions(input) }
    }
    public func deleteV1DevicesDeviceCodePermissions(_ input: Operations.DeleteV1DevicesDeviceCodePermissions.Input) async throws -> Operations.DeleteV1DevicesDeviceCodePermissions.Output {
        try await DecodingDiagnostics.capture("deleteV1DevicesDeviceCodePermissions") { try await wrapped.deleteV1DevicesDeviceCodePermissions(input) }
    }
    public func getV1DevicesDeviceCodeAudit(_ input: Operations.GetV1DevicesDeviceCodeAudit.Input) async throws -> Operations.GetV1DevicesDeviceCodeAudit.Output {
        try await DecodingDiagnostics.capture("getV1DevicesDeviceCodeAudit") { try await wrapped.getV1DevicesDeviceCodeAudit(input) }
    }
    public func getV1DevicesDeviceCodeSimulate(_ input: Operations.GetV1DevicesDeviceCodeSimulate.Input) async throws -> Operations.GetV1DevicesDeviceCodeSimulate.Output {
        try await DecodingDiagnostics.capture("getV1DevicesDeviceCodeSimulate") { try await wrapped.getV1DevicesDeviceCodeSimulate(input) }
    }
    public func postV1DevicesDeviceCodeSimulate(_ input: Operations.PostV1DevicesDeviceCodeSimulate.Input) async throws -> Operations.PostV1DevicesDeviceCodeSimulate.Output {
        try await DecodingDiagnostics.capture("postV1DevicesDeviceCodeSimulate") { try await wrapped.postV1DevicesDeviceCodeSimulate(input) }
    }
    public func getV1DevicesDeviceCodeSimulateActive(_ input: Operations.GetV1DevicesDeviceCodeSimulateActive.Input) async throws -> Operations.GetV1DevicesDeviceCodeSimulateActive.Output {
        try await DecodingDiagnostics.capture("getV1DevicesDeviceCodeSimulateActive") { try await wrapped.getV1DevicesDeviceCodeSimulateActive(input) }
    }
    public func deleteV1DevicesDeviceCodeSimulateSimId(_ input: Operations.DeleteV1DevicesDeviceCodeSimulateSimId.Input) async throws -> Operations.DeleteV1DevicesDeviceCodeSimulateSimId.Output {
        try await DecodingDiagnostics.capture("deleteV1DevicesDeviceCodeSimulateSimId") { try await wrapped.deleteV1DevicesDeviceCodeSimulateSimId(input) }
    }
    public func getV1ReplicantsReplicantCodeInventory(_ input: Operations.GetV1ReplicantsReplicantCodeInventory.Input) async throws -> Operations.GetV1ReplicantsReplicantCodeInventory.Output {
        try await DecodingDiagnostics.capture("getV1ReplicantsReplicantCodeInventory") { try await wrapped.getV1ReplicantsReplicantCodeInventory(input) }
    }
    public func getV1Inventory(_ input: Operations.GetV1Inventory.Input) async throws -> Operations.GetV1Inventory.Output {
        try await DecodingDiagnostics.capture("getV1Inventory") { try await wrapped.getV1Inventory(input) }
    }
    public func postV1ReplicantsReplicantCodePrint(_ input: Operations.PostV1ReplicantsReplicantCodePrint.Input) async throws -> Operations.PostV1ReplicantsReplicantCodePrint.Output {
        try await DecodingDiagnostics.capture("postV1ReplicantsReplicantCodePrint") { try await wrapped.postV1ReplicantsReplicantCodePrint(input) }
    }
    public func getV1Blueprints(_ input: Operations.GetV1Blueprints.Input) async throws -> Operations.GetV1Blueprints.Output {
        try await DecodingDiagnostics.capture("getV1Blueprints") { try await wrapped.getV1Blueprints(input) }
    }
    public func getV1Events(_ input: Operations.GetV1Events.Input) async throws -> Operations.GetV1Events.Output {
        try await DecodingDiagnostics.capture("getV1Events") { try await wrapped.getV1Events(input) }
    }
    public func getV1EventsStream(_ input: Operations.GetV1EventsStream.Input) async throws -> Operations.GetV1EventsStream.Output {
        try await DecodingDiagnostics.capture("getV1EventsStream") { try await wrapped.getV1EventsStream(input) }
    }
    public func getV1ReplicantsReplicantCodeEvents(_ input: Operations.GetV1ReplicantsReplicantCodeEvents.Input) async throws -> Operations.GetV1ReplicantsReplicantCodeEvents.Output {
        try await DecodingDiagnostics.capture("getV1ReplicantsReplicantCodeEvents") { try await wrapped.getV1ReplicantsReplicantCodeEvents(input) }
    }
    public func getV1Messages(_ input: Operations.GetV1Messages.Input) async throws -> Operations.GetV1Messages.Output {
        try await DecodingDiagnostics.capture("getV1Messages") { try await wrapped.getV1Messages(input) }
    }
    public func postV1MessagesRead(_ input: Operations.PostV1MessagesRead.Input) async throws -> Operations.PostV1MessagesRead.Output {
        try await DecodingDiagnostics.capture("postV1MessagesRead") { try await wrapped.postV1MessagesRead(input) }
    }
    public func getV1Locations(_ input: Operations.GetV1Locations.Input) async throws -> Operations.GetV1Locations.Output {
        try await DecodingDiagnostics.capture("getV1Locations") { try await wrapped.getV1Locations(input) }
    }
    public func getV1LocationsDesignation(_ input: Operations.GetV1LocationsDesignation.Input) async throws -> Operations.GetV1LocationsDesignation.Output {
        try await DecodingDiagnostics.capture("getV1LocationsDesignation") { try await wrapped.getV1LocationsDesignation(input) }
    }
    public func postV1LocationsDesignationContribute(_ input: Operations.PostV1LocationsDesignationContribute.Input) async throws -> Operations.PostV1LocationsDesignationContribute.Output {
        try await DecodingDiagnostics.capture("postV1LocationsDesignationContribute") { try await wrapped.postV1LocationsDesignationContribute(input) }
    }
    public func getV1LocationsDesignationInventory(_ input: Operations.GetV1LocationsDesignationInventory.Input) async throws -> Operations.GetV1LocationsDesignationInventory.Output {
        try await DecodingDiagnostics.capture("getV1LocationsDesignationInventory") { try await wrapped.getV1LocationsDesignationInventory(input) }
    }
    public func getV1LocationsStarDesignationStars(_ input: Operations.GetV1LocationsStarDesignationStars.Input) async throws -> Operations.GetV1LocationsStarDesignationStars.Output {
        try await DecodingDiagnostics.capture("getV1LocationsStarDesignationStars") { try await wrapped.getV1LocationsStarDesignationStars(input) }
    }
    public func postV1ReplicantsReplicantCodeMine(_ input: Operations.PostV1ReplicantsReplicantCodeMine.Input) async throws -> Operations.PostV1ReplicantsReplicantCodeMine.Output {
        try await DecodingDiagnostics.capture("postV1ReplicantsReplicantCodeMine") { try await wrapped.postV1ReplicantsReplicantCodeMine(input) }
    }
    public func deleteV1ReplicantsReplicantCodeMine(_ input: Operations.DeleteV1ReplicantsReplicantCodeMine.Input) async throws -> Operations.DeleteV1ReplicantsReplicantCodeMine.Output {
        try await DecodingDiagnostics.capture("deleteV1ReplicantsReplicantCodeMine") { try await wrapped.deleteV1ReplicantsReplicantCodeMine(input) }
    }
    public func getV1Health(_ input: Operations.GetV1Health.Input) async throws -> Operations.GetV1Health.Output {
        try await DecodingDiagnostics.capture("getV1Health") { try await wrapped.getV1Health(input) }
    }
    public func getV1Leaderboards(_ input: Operations.GetV1Leaderboards.Input) async throws -> Operations.GetV1Leaderboards.Output {
        try await DecodingDiagnostics.capture("getV1Leaderboards") { try await wrapped.getV1Leaderboards(input) }
    }
    public func getV1LeaderboardsXp(_ input: Operations.GetV1LeaderboardsXp.Input) async throws -> Operations.GetV1LeaderboardsXp.Output {
        try await DecodingDiagnostics.capture("getV1LeaderboardsXp") { try await wrapped.getV1LeaderboardsXp(input) }
    }
    public func getV1LeaderboardsFleet(_ input: Operations.GetV1LeaderboardsFleet.Input) async throws -> Operations.GetV1LeaderboardsFleet.Output {
        try await DecodingDiagnostics.capture("getV1LeaderboardsFleet") { try await wrapped.getV1LeaderboardsFleet(input) }
    }
    public func getV1LeaderboardsTrades(_ input: Operations.GetV1LeaderboardsTrades.Input) async throws -> Operations.GetV1LeaderboardsTrades.Output {
        try await DecodingDiagnostics.capture("getV1LeaderboardsTrades") { try await wrapped.getV1LeaderboardsTrades(input) }
    }
    public func getV1LeaderboardsDistance(_ input: Operations.GetV1LeaderboardsDistance.Input) async throws -> Operations.GetV1LeaderboardsDistance.Output {
        try await DecodingDiagnostics.capture("getV1LeaderboardsDistance") { try await wrapped.getV1LeaderboardsDistance(input) }
    }
    public func getV1LeaderboardsReputation(_ input: Operations.GetV1LeaderboardsReputation.Input) async throws -> Operations.GetV1LeaderboardsReputation.Output {
        try await DecodingDiagnostics.capture("getV1LeaderboardsReputation") { try await wrapped.getV1LeaderboardsReputation(input) }
    }
    public func getV1LeaderboardsMegastructure(_ input: Operations.GetV1LeaderboardsMegastructure.Input) async throws -> Operations.GetV1LeaderboardsMegastructure.Output {
        try await DecodingDiagnostics.capture("getV1LeaderboardsMegastructure") { try await wrapped.getV1LeaderboardsMegastructure(input) }
    }
    public func getV1LeaderboardsSimulations(_ input: Operations.GetV1LeaderboardsSimulations.Input) async throws -> Operations.GetV1LeaderboardsSimulations.Output {
        try await DecodingDiagnostics.capture("getV1LeaderboardsSimulations") { try await wrapped.getV1LeaderboardsSimulations(input) }
    }
    public func getV1LeaderboardsSimulationsScenarioCode(_ input: Operations.GetV1LeaderboardsSimulationsScenarioCode.Input) async throws -> Operations.GetV1LeaderboardsSimulationsScenarioCode.Output {
        try await DecodingDiagnostics.capture("getV1LeaderboardsSimulationsScenarioCode") { try await wrapped.getV1LeaderboardsSimulationsScenarioCode(input) }
    }
    public func getV1AccountsEvents(_ input: Operations.GetV1AccountsEvents.Input) async throws -> Operations.GetV1AccountsEvents.Output {
        try await DecodingDiagnostics.capture("getV1AccountsEvents") { try await wrapped.getV1AccountsEvents(input) }
    }
    public func getV1LocationsLocationCodeEvents(_ input: Operations.GetV1LocationsLocationCodeEvents.Input) async throws -> Operations.GetV1LocationsLocationCodeEvents.Output {
        try await DecodingDiagnostics.capture("getV1LocationsLocationCodeEvents") { try await wrapped.getV1LocationsLocationCodeEvents(input) }
    }
    public func postV1LocationsLocationCodeEventsDesignation(_ input: Operations.PostV1LocationsLocationCodeEventsDesignation.Input) async throws -> Operations.PostV1LocationsLocationCodeEventsDesignation.Output {
        try await DecodingDiagnostics.capture("postV1LocationsLocationCodeEventsDesignation") { try await wrapped.postV1LocationsLocationCodeEventsDesignation(input) }
    }
    public func getV1Species(_ input: Operations.GetV1Species.Input) async throws -> Operations.GetV1Species.Output {
        try await DecodingDiagnostics.capture("getV1Species") { try await wrapped.getV1Species(input) }
    }
    public func getV1AccountsReputation(_ input: Operations.GetV1AccountsReputation.Input) async throws -> Operations.GetV1AccountsReputation.Output {
        try await DecodingDiagnostics.capture("getV1AccountsReputation") { try await wrapped.getV1AccountsReputation(input) }
    }
    public func getV1ReplicantsReplicantCodeReputation(_ input: Operations.GetV1ReplicantsReplicantCodeReputation.Input) async throws -> Operations.GetV1ReplicantsReplicantCodeReputation.Output {
        try await DecodingDiagnostics.capture("getV1ReplicantsReplicantCodeReputation") { try await wrapped.getV1ReplicantsReplicantCodeReputation(input) }
    }
    public func getV1DevicesDeviceCodeTrades(_ input: Operations.GetV1DevicesDeviceCodeTrades.Input) async throws -> Operations.GetV1DevicesDeviceCodeTrades.Output {
        try await DecodingDiagnostics.capture("getV1DevicesDeviceCodeTrades") { try await wrapped.getV1DevicesDeviceCodeTrades(input) }
    }
    public func postV1DevicesDeviceCodeTrades(_ input: Operations.PostV1DevicesDeviceCodeTrades.Input) async throws -> Operations.PostV1DevicesDeviceCodeTrades.Output {
        try await DecodingDiagnostics.capture("postV1DevicesDeviceCodeTrades") { try await wrapped.postV1DevicesDeviceCodeTrades(input) }
    }
    public func postV1DevicesDeviceCodeTradesTradeCode(_ input: Operations.PostV1DevicesDeviceCodeTradesTradeCode.Input) async throws -> Operations.PostV1DevicesDeviceCodeTradesTradeCode.Output {
        try await DecodingDiagnostics.capture("postV1DevicesDeviceCodeTradesTradeCode") { try await wrapped.postV1DevicesDeviceCodeTradesTradeCode(input) }
    }
    public func deleteV1DevicesDeviceCodeTradesTradeCode(_ input: Operations.DeleteV1DevicesDeviceCodeTradesTradeCode.Input) async throws -> Operations.DeleteV1DevicesDeviceCodeTradesTradeCode.Output {
        try await DecodingDiagnostics.capture("deleteV1DevicesDeviceCodeTradesTradeCode") { try await wrapped.deleteV1DevicesDeviceCodeTradesTradeCode(input) }
    }
    public func getV1ReplicantsReplicantCodeTraders(_ input: Operations.GetV1ReplicantsReplicantCodeTraders.Input) async throws -> Operations.GetV1ReplicantsReplicantCodeTraders.Output {
        try await DecodingDiagnostics.capture("getV1ReplicantsReplicantCodeTraders") { try await wrapped.getV1ReplicantsReplicantCodeTraders(input) }
    }
    public func getV1Stars(_ input: Operations.GetV1Stars.Input) async throws -> Operations.GetV1Stars.Output {
        try await DecodingDiagnostics.capture("getV1Stars") { try await wrapped.getV1Stars(input) }
    }
    public func postV1Feedback(_ input: Operations.PostV1Feedback.Input) async throws -> Operations.PostV1Feedback.Output {
        try await DecodingDiagnostics.capture("postV1Feedback") { try await wrapped.postV1Feedback(input) }
    }
    public func postV1AdminMessage(_ input: Operations.PostV1AdminMessage.Input) async throws -> Operations.PostV1AdminMessage.Output {
        try await DecodingDiagnostics.capture("postV1AdminMessage") { try await wrapped.postV1AdminMessage(input) }
    }
    public func postV1AdminStoryAdvance(_ input: Operations.PostV1AdminStoryAdvance.Input) async throws -> Operations.PostV1AdminStoryAdvance.Output {
        try await DecodingDiagnostics.capture("postV1AdminStoryAdvance") { try await wrapped.postV1AdminStoryAdvance(input) }
    }
}
