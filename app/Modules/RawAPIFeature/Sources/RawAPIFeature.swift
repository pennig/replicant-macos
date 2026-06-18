//
//  RawAPIFeature.swift
//  Replicant
//
//  The direct API access feature for power users: compose a request against the
//  Replicant Space API surface and inspect the raw response.
//

import ComposableArchitecture
import SwiftUI
import UI

@Reducer
public struct RawAPIFeature {
    @ObservableState
    public struct State: Equatable {
        public init() {}
    }

    public enum Action {
        case onAppear
    }

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .none
            }
        }
    }
}

public struct RawAPIView: View {
    @Bindable var store: StoreOf<RawAPIFeature>

    public init(store: StoreOf<RawAPIFeature>) {
        self.store = store
    }

    public var body: some View {
        Text("Raw API")
            .onAppear { store.send(.onAppear) }
    }
}
