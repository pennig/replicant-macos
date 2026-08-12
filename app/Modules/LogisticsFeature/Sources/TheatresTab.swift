//
//  TheatresTab.swift
//  Replicould — Logistics feature
//
//  What exists (the theatres list) and what the brain proposes next (ranked
//  candidate sites), plus the operator's establish action on either.
//

import ComposableArchitecture
import DirectiveEngine
import SwiftUI
import UI

struct TheatresTab: View {
    @Bindable var store: StoreOf<LogisticsFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                theatresSection
                candidatesSection
            }
            .padding(Space.m)
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    store.send(.theatresRefreshTapped)
                }
                .help("Re-rank theatres and proposed sites from the current census")
            }
            ToolbarItem {
                Button("Establish Theatre", systemImage: "plus") {
                    store.send(.establishTapped(system: nil))
                }
            }
        }
        .sheet(item: $store.scope(state: \.establishTheatre, action: \.establishTheatre)) { establishStore in
            EstablishTheatreSheetView(store: establishStore)
        }
    }

    @ViewBuilder
    private var theatresSection: some View {
        RCSectionHeader("Theatres", count: store.theatres.count)
        if store.theatres.isEmpty {
            RCContentUnavailableView(
                "No Theatres Yet",
                systemImage: "building.2",
                description: Text("Establish one, or claim an existing system hub.")
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.theatres.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { Divider().overlay(.rcSeparator) }
                    TheatreRow(model: model)
                }
            }
            .padding(.horizontal, Space.m)
            .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    @ViewBuilder
    private var candidatesSection: some View {
        RCSectionHeader("Proposed Sites", count: store.candidates.count)
        if store.candidates.isEmpty {
            Text("No candidates ranked yet — tap Refresh to rank the census.")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(store.candidates) { candidate in
                    TheatreCandidateRow(candidate: candidate) {
                        store.send(.establishTapped(system: candidate.system))
                    }
                }
            }
        }
    }
}

/// One ranked site: its `reasons` render verbatim, per the ticket's rule —
/// they are the brain's graph facts, not restated prose this view owns.
private struct TheatreCandidateRow: View {
    let candidate: TheatreSiteRanking.Candidate
    let onEstablish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(candidate.system).font(.rcBodyEmphMono).foregroundStyle(.rcTextPrimary)
                if candidate.hasAuthority {
                    Image(systemName: "checkmark.seal")
                        .font(.rcCaption)
                        .foregroundStyle(.rcAccent)
                        .help("Command authority already in place")
                }
                if !candidate.isSurveyed {
                    Image(systemName: "questionmark.diamond")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                        .help("Unsurveyed — belts are discounted, not confirmed absent")
                }
                Spacer(minLength: 0)
                Button("Establish", action: onEstablish)
                    .buttonStyle(RCButtonStyle(.secondary))
            }
            ForEach(candidate.reasons, id: \.self) { reason in
                Text(reason).font(.rcCaption).foregroundStyle(.rcTextSecondary)
            }
        }
        .padding(Space.m)
        .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
        )
    }
}
