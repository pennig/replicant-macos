//
//  CivilisationDetailView.swift
//  Replicould — Civilisations feature
//
//  The civilisation dossier for the split view's detail column: header,
//  first-contact greeting, description, an attribute readout (government,
//  homeworld, tech affinity, trait, star regions), and the account's reputation
//  standing. Read-only — reputation is earned through location events surfaced
//  elsewhere. Observes the `Civilisation` table, so a refresh re-renders the
//  pane automatically.
//

import ComposableArchitecture
import GameDatabase
import GameModels
import SQLiteData
import SwiftUI
import UI

public struct CivilisationDetailView: View {
    let store: StoreOf<CivilisationsFeature>
    @FetchAll(Civilisation.all) private var civilisations

    public init(store: StoreOf<CivilisationsFeature>) {
        self.store = store
    }

    private var civilisation: Civilisation? {
        guard let speciesKey = store.selectedSpeciesKey else { return nil }
        return civilisations.first { $0.speciesKey == speciesKey }
    }

    public var body: some View {
        if let civilisation {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header(civilisation)
                    greeting(civilisation)
                    description(civilisation)
                    attributes(civilisation)
                    reputation(civilisation)
                }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(civilisation.name)
        } else {
            RCContentUnavailableView(
                "No Civilisation Selected",
                systemImage: SidebarSymbol.civilisations,
                description: Text("Select a civilisation to inspect it.")
            )
        }
    }

    // MARK: Header

    private func header(_ civilisation: Civilisation) -> some View {
        HStack(spacing: Space.m) {
            RCGlyphTile(Image(systemName: SidebarSymbol.civilisations), size: TileSize.large)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(civilisation.name)
                    .font(.rcTitle)
                    .foregroundStyle(.rcTextPrimary)
                Text(civilisation.speciesKey)
                    .font(.rcMono)
                    .foregroundStyle(.rcTextTertiary)
            }
            Spacer(minLength: 0)

            if let standing = civilisation.totalReputation {
                VStack(alignment: .trailing, spacing: Space.xs) {
                    Text("REP \(standing.formatted())")
                        .font(.rcMono)
                        .foregroundStyle(.rcTextPrimary)
                    Text("Reputation")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
            } else {
                Text("Not yet encountered")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
    }

    // MARK: Greeting

    /// The species' first-contact transmission, set off as quoted flavor text.
    private func greeting(_ civilisation: Civilisation) -> some View {
        Text(civilisation.greeting)
            .font(.rcBody)
            .italic()
            .foregroundStyle(.rcTextSecondary)
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
            )
    }

    // MARK: Description

    private func description(_ civilisation: Civilisation) -> some View {
        Text(civilisation.speciesDescription)
            .font(.rcBody)
            .foregroundStyle(.rcTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Attributes

    private func attributes(_ civilisation: Civilisation) -> some View {
        Section(label: "Profile") {
            VStack(spacing: Space.s) {
                attributeRow("Government", civilisation.government)
                attributeRow("Homeworld", BlueprintPresentation.displayName(civilisation.homeworldType))
                attributeRow("Tech affinity", BlueprintPresentation.displayName(civilisation.techAffinity))
                attributeRow("Trait", BlueprintPresentation.displayName(civilisation.trait))
                if !civilisation.starRegions.isEmpty {
                    attributeRow(
                        "Star regions",
                        civilisation.starRegions.map(BlueprintPresentation.displayName).joined(separator: ", ")
                    )
                }
            }
        }
    }

    private func attributeRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.rcBody)
                .foregroundStyle(.rcTextSecondary)
            Spacer()
            Text(value)
                .font(.rcBody)
                .foregroundStyle(.rcTextPrimary)
        }
    }

    // MARK: Reputation

    private func reputation(_ civilisation: Civilisation) -> some View {
        Section(label: "Reputation") {
            if let standing = civilisation.totalReputation {
                HStack {
                    Text("Standing")
                        .font(.rcBody)
                        .foregroundStyle(.rcTextSecondary)
                    Spacer()
                    Text(standing.formatted())
                        .font(.rcMono)
                        .foregroundStyle(.rcTextPrimary)
                }
            } else {
                Text("No standing yet — completing this species' location events earns reputation.")
                    .font(.rcBody)
                    .foregroundStyle(.rcTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Section container

/// A titled section with the design system's uppercase section label.
private struct Section<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            RCSectionHeader(label)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#Preview {
    let _ = prepareDependencies {
        try! $0.bootstrapDatabase { db in
            try db.seed {
                Civilisation.previewCatalog.map { civilisation in
                    var seeded = civilisation
                    seeded.totalReputation = Civilisation.previewReputations
                        .first { $0.speciesKey == civilisation.speciesKey }?
                        .totalReputation
                    return seeded
                }
            }
        }
    }
    CivilisationDetailView(
        store: Store(initialState: CivilisationsFeature.State(selectedSpeciesKey: "humans")) {
            CivilisationsFeature()
        }
    )
    .frame(width: 640, height: 760)
}
