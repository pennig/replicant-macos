import ComposableArchitecture
import GameModels
import GameServices
import Testing
@testable import NewStarMapFeature

// The galaxy dossier's Travel button reuses the Devices inspector's dry-run
// travel flow: request a plan, review it, then confirm (dispatch) or dismiss.
// These mirror `DevicesFeatureTests`' travel coverage for the star-map reducer.
//
// @MainActor because the module defaults to MainActor isolation.

@MainActor
@Suite struct TravelFlowTests {

    /// Requesting a preview shows the loading sheet, then loads the dry-run plan
    /// returned by the command client.
    @Test func travelPreviewRequestLoadsPlan() async {
        let plan = TravelPlan(
            finalDestination: "IZARUM",
            totalTimeSeconds: 125.5,
            route: [TravelPlan.Leg(leg: 1, from: "SOL", to: "IZARUM", type: "surge")]
        )

        let store = TestStore(initialState: NewStarMapFeature.State()) {
            NewStarMapFeature()
        } withDependencies: {
            $0.commandClient.previewTravel = { _, _ in .plan(plan) }
        }

        await store.send(.travelPreviewRequested(deviceCode: "A", destination: "IZARUM")) {
            $0.travelPreview = TravelPreview(deviceCode: "A", destination: "IZARUM")
        }
        await store.receive(\.travelPreviewResponse) {
            $0.travelPreview?.phase = .loaded(plan)
        }
    }

    /// Confirming the previewed itinerary clears the sheet and dispatches the
    /// real travel command for the previewed device/destination.
    @Test func travelPreviewConfirmedDispatches() async {
        let dispatched = LockIsolated<(OperationKind, String, CommandParams)?>(nil)

        let store = TestStore(
            initialState: {
                var state = NewStarMapFeature.State()
                state.travelPreview = TravelPreview(
                    deviceCode: "A", destination: "IZARUM", phase: .loaded(TravelPlan())
                )
                return state
            }()
        ) {
            NewStarMapFeature()
        } withDependencies: {
            $0.commandClient.dispatch = { kind, code, params in
                dispatched.setValue((kind, code, params))
                return .accepted(operationID: "op")
            }
        }
        store.exhaustivity = .off

        await store.send(.travelPreviewConfirmed) {
            $0.travelPreview = nil
        }
        await store.finish()

        #expect(dispatched.value?.0 == .travel)
        #expect(dispatched.value?.1 == "A")
        #expect(dispatched.value?.2.destination == "IZARUM")
    }

    /// Dismissing clears the sheet without dispatching.
    @Test func travelPreviewDismissedClears() async {
        let store = TestStore(
            initialState: {
                var state = NewStarMapFeature.State()
                state.travelPreview = TravelPreview(deviceCode: "A", destination: "IZARUM")
                return state
            }()
        ) {
            NewStarMapFeature()
        }

        await store.send(.travelPreviewDismissed) {
            $0.travelPreview = nil
        }
    }
}
