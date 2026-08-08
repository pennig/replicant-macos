//
//  JumpToLatestPill.swift
//  Replicould — Bobnet feature
//
//  The floating affordance back to the newest message.
//

import ComposableArchitecture
import SwiftUI
import UI

struct JumpToLatestPill: View {
    @Bindable var store: StoreOf<BobnetFeature>

    private enum Presentation {
        case hidden
        case arrow
        case count(Int)
    }

    private var presentation: Presentation {
        if store.newWhileAway > 0 { return .count(store.newWhileAway) }
        return !store.isAtLatest && !store.pendingBottomScroll ? .arrow : .hidden
    }

    var body: some View {
        let presentation = self.presentation
        switch presentation {
        case .hidden:
            EmptyView()
        case .arrow, .count:
            Button {
                store.send(.jumpToLatestTapped)
            } label: {
                HStack(spacing: Space.xs) {
                    if case .count(let n) = presentation {
                        Text("\(n) new")
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcAccent)
                    }
                    Image(systemName: "arrow.down")
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcAccent)
                }
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xs)
                .background(Capsule().fill(.bar))
                .overlay(Capsule().stroke(.rcAccent.opacity(0.4), lineWidth: Hairline.thin))
            }
            .buttonStyle(.plain)
            .padding(.bottom, Space.s)
        }
    }
}
