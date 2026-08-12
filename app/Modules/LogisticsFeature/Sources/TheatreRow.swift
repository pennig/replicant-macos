//
//  TheatreRow.swift
//  Replicould — Logistics feature
//
//  No `#Preview` in this file — the Xcode 26 preview JIT crashes when a list-row
//  struct sits beside one (.claude/memory/list-row-preview-crash.md).
//

import DirectiveEngine
import GameModels
import SwiftUI
import UI

/// A `Theatre` plus facts only `WorldView`/the directive table can answer.
/// Top-level, not nested in `TheatreRow` — a nested type on a SwiftUI `View`
/// traps `swift test` (see `.claude/memory/swiftui-view-statics-trap-in-tests.md`).
public struct TheatreRowModel: Equatable, Identifiable {
    public let theatre: Theatre
    /// Systems sharing this theatre's mesh component, itself included; nil
    /// when the theatre's own system is not on the mesh at all.
    public let componentSize: Int?
    /// Non-deleted directives `Brain.adoptTheatres` has stamped as this depot's.
    public let directiveCount: Int

    public var id: String { theatre.id }

    public init(theatre: Theatre, componentSize: Int? = nil, directiveCount: Int = 0) {
        self.theatre = theatre
        self.componentSize = componentSize
        self.directiveCount = directiveCount
    }

    public init(theatre: Theatre, view: WorldView, directives: [Directive]) {
        self.theatre = theatre
        let component = view.components[theatre.system]
        self.componentSize = component.map { label in view.components.values.count { $0 == label } }
        self.directiveCount = directives.count { $0.theatreDepot == theatre.depot }
    }

    public var originLabel: String {
        switch theatre.origin {
        case .pinned: "Pinned"
        case .systemHub: "Hub-claimed"
        case .derived: "Derived"
        }
    }

    public var readinessLabel: String { theatre.isOperational ? "Operational" : "Claimed" }

    public var readinessTone: StatusTone {
        DeviceStatus.tone(for: theatre.isOperational ? "ready" : "waiting_for_resources")
    }

    /// One line per shortfall, in the operator's own words — this IS the
    /// to-do list for standing the theatre up, so it is never collapsed.
    public var shortfallLines: [String] {
        guard case let .claimed(missing) = theatre.readiness else { return [] }
        return Theatre.Shortfall.allCases.filter(missing.contains).map(\.operatorDescription)
    }
}

extension Theatre.Shortfall {
    var operatorDescription: String {
        switch self {
        case .noPrintCapableDevice: "no autofactory here"
        case .noStock: "no stock"
        case .offMesh: "off mesh"
        }
    }
}

struct TheatreRow: View {
    let model: TheatreRowModel

    private var theatre: Theatre { model.theatre }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(theatre.depot).font(.rcBodyEmphMono).foregroundStyle(.rcTextPrimary)
                Text(model.originLabel)
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextSecondary)
                    .rcPill(theatre.origin == .pinned ? .accent : .neutral)
                Spacer(minLength: 0)
                readinessBadge
            }
            HStack(spacing: Space.m) {
                Text("\(theatre.stock) units").font(.rcCaption).foregroundStyle(.rcTextTertiary)
                if let componentSize = model.componentSize {
                    Text("\(componentSize) system\(componentSize == 1 ? "" : "s") meshed")
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextTertiary)
                }
                Text("\(model.directiveCount) directive\(model.directiveCount == 1 ? "" : "s")")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
                Spacer(minLength: 0)
            }
            if !model.shortfallLines.isEmpty {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(model.shortfallLines, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.circle")
                            .font(.rcCaption)
                            .foregroundStyle(.rcWarning)
                    }
                }
            }
        }
        .padding(.vertical, Space.xs)
    }

    private var readinessBadge: some View {
        HStack(spacing: Space.xs) {
            Circle()
                .fill(model.readinessTone.color)
                .frame(width: MarkerSize.attentionDot, height: MarkerSize.attentionDot)
            Text(model.readinessLabel).font(.rcCaption).foregroundStyle(model.readinessTone.color)
        }
    }
}
