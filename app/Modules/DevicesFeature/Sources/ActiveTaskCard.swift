//
//  ActiveTaskCard.swift
//  Replicould — Devices feature
//
//  The device inspector's "Active Task" readout: live progress and ETA for the
//  device's open `Operation`, or one of the specialized in-place readouts —
//  diverting propulsor defense, mining drone cycle/yield, or repairing bot
//  progress — that replaces it when the device is running one of those
//  continuous activities instead of a dispatched op.
//

import GameModels
import SwiftUI
import UI

/// Disambiguate from `Foundation.Operation`.
private typealias Operation = GameModels.Operation

struct ActiveTaskCard: View {
    let operation: GameModels.Operation?
    /// The status parameter the backend appended in parentheses (e.g. the device
    /// type being printed, `"transport_drone"`, or the resource being mined). Shown
    /// beside the task kind instead of crammed into the status badge.
    var parameter: String? = nil
    /// The device's live `travel` block — the fallback route source for a travel
    /// op adopted mid-flight. An op dispatched locally carries its own whole-route
    /// snapshot, frozen at departure, which is preferred.
    var liveTravel: TravelSnapshot? = nil
    /// The defense readout for a `diverting` propulsor, fetched from the object it's
    /// attached to (a diverting device carries no activity block of its own). When
    /// present it replaces the operation readout — diversion isn't a dispatched op.
    var diversion: DiversionSnapshot? = nil
    /// The live mining state for a `mining` drone — resource, cycle, and yield. When
    /// present it replaces the generic operation readout with the cycle-aware card,
    /// since mining is continuous (no deadline) and refreshes in place each cycle.
    var mining: MiningSnapshot? = nil
    /// The live repair state for a `repairing` bot — target device, server progress,
    /// and ETA. When present it replaces the generic operation readout, since repair
    /// carries its state in the device's own `repair` block and refreshes in place.
    var repair: RepairSnapshot? = nil

    /// The itinerary to display for a travel op: the whole route captured at
    /// dispatch when we have it, else the device's remaining-legs snapshot. Nil
    /// for a non-travel op.
    private var itinerary: TravelSnapshot? {
        guard operation?.kind == OperationKind.travel.rawValue else { return nil }
        if let stored = operation?.travelSnapshot, !stored.legs.isEmpty { return stored }
        return liveTravel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RCSectionHeader("Active Task")

            if let diversion {
                diversionReadout(diversion)
            } else if let mining {
                miningReadout(mining)
            } else if let repair {
                repairReadout(repair)
            } else if let operation {
                HStack(spacing: Space.xs) {
                    Text(operation.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.rcHeadline)
                        .foregroundStyle(.rcTextPrimary)
                    if let parameter {
                        Text("·")
                            .font(.rcHeadline)
                            .foregroundStyle(.rcTextTertiary)
                        Text(DevicePresentation.displayName(parameter))
                            .font(.rcHeadline)
                            .foregroundStyle(.rcTextSecondary)
                    }
                }
                .lineLimit(1)

                if let itinerary {
                    routeReadout(itinerary)
                }

                progress(for: operation, itinerary: itinerary)
            } else {
                Text("Idle — no active task.")
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
                )
        )
    }

    /// The progress readout for the operation. A multi-leg travel op gets the
    /// segmented bar; everything else keeps the single interpolated bar. Both are
    /// keyed by op id so the "reached the end" latch resets for a genuinely new
    /// operation (but survives a re-arm of the same one).
    @ViewBuilder
    private func progress(for operation: Operation, itinerary: TravelSnapshot?) -> some View {
        if operation.status == .active, let completesAt = operation.completesAt {
            if let itinerary, !itinerary.legs.isEmpty {
                TravelProgressView(
                    segments: segments(itinerary),
                    barStart: barStart(itinerary, operation: operation, completesAt: completesAt),
                    completesAt: completesAt
                )
                .id(operation.id)
            } else {
                OperationProgressView(startedAt: operation.startedAt, completesAt: completesAt)
                    .id(operation.id)
            }
        } else {
            Text(label(for: operation.status))
                .font(.rcCaption)
                .foregroundStyle(.rcTextSecondary)
        }
    }

    private func segments(_ snapshot: TravelSnapshot) -> [TravelBar.Segment] {
        snapshot.legs.map { leg in
            TravelBar.Segment(
                id: leg.index,
                weight: leg.timeSeconds ?? 0,
                type: leg.type,
                from: leg.from,
                to: leg.to
            )
        }
    }

    /// Anchor the sweep on `completesAt − total leg duration` so the fill spans
    /// exactly the legs we can show — the whole trip for a frozen dispatch route,
    /// just the remaining legs for an adopted one. Falls back to the op's start
    /// when the legs carry no durations.
    private func barStart(_ snapshot: TravelSnapshot, operation: Operation, completesAt: Date) -> Date {
        if let total = snapshot.totalLegSeconds, total > 0 {
            return completesAt.addingTimeInterval(-total)
        }
        return operation.startedAt
    }

    private func label(for status: OperationStatus) -> String {
        switch status {
        case .enqueued:   return "Queued — awaiting start."
        case .optimistic: return "Dispatching…"
        default:          return status.rawValue.capitalized
        }
    }

    /// Origin → destination for a travel task.
    private func routeReadout(_ snapshot: TravelSnapshot) -> some View {
        HStack(spacing: Space.xs) {
            Text(snapshot.originLabel ?? "—")
                .foregroundStyle(.rcTextSecondary)
            Image(systemName: "arrow.right")
                .font(.system(size: IconSize.s, weight: .semibold))
                .foregroundStyle(.rcTextTertiary)
            Text(snapshot.destinationLabel ?? "—")
                .foregroundStyle(.rcTextPrimary)
        }
        .font(.rcMonoSmall)
        .lineLimit(1)
        .textSelection(.enabled)
    }

    // MARK: Diversion readout

    /// The planetary-defense readout for a diverting propulsor: the threat object,
    /// its deflection progress (a server-authoritative percent, not a timed bar),
    /// and the impact it's averting.
    @ViewBuilder
    private func diversionReadout(_ d: DiversionSnapshot) -> some View {
        HStack(spacing: Space.xs) {
            Text("Diverting")
                .font(.rcHeadline)
                .foregroundStyle(.rcTextPrimary)
            Text("·")
                .font(.rcHeadline)
                .foregroundStyle(.rcTextTertiary)
            Text(d.objectDesignation)
                .font(.rcMono)
                .foregroundStyle(.rcTextSecondary)
                .textSelection(.enabled)
        }
        .lineLimit(1)

        if let subtitle = objectSubtitle(d) {
            Text(subtitle)
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
        }

        if let pct = d.progressPct {
            VStack(alignment: .leading, spacing: Space.xs) {
                ProgressView(value: min(max(pct / 100, 0), 1))
                    .tint(StatusTone.working.color)
                Text("\(Self.percent(pct)) deflected")
                    .font(.rcMonoSmall)
                    .foregroundStyle(.rcTextSecondary)
            }
        }

        VStack(alignment: .leading, spacing: Space.xs) {
            if let impact = impactValue(d) {
                taskRow("Impact", impact)
            }
            if let likelihood = d.impactLikelihood {
                taskRow("Likelihood", Self.percent(likelihood), valueColor: likelihoodColor(likelihood))
            }
            if let thrust = thrustValue(d) {
                taskRow("Thrust", thrust)
            }
        }
        .padding(.top, Space.xs)
    }

    // MARK: Mining readout

    /// The live readout for a mining drone: whether it's extracting or seeking (per
    /// the yield tally), a repeating cycle bar, and the belt/availability/yield.
    @ViewBuilder
    private func miningReadout(_ m: MiningSnapshot) -> some View {
        HStack(spacing: Space.xs) {
            Text(m.isProducing ? "Mining" : "Seeking")
                .font(.rcHeadline)
                .foregroundStyle(.rcTextPrimary)
            if let resource = m.resourceType {
                Text("·")
                    .font(.rcHeadline)
                    .foregroundStyle(.rcTextTertiary)
                Text(DevicePresentation.displayName(resource))
                    .font(.rcHeadline)
                    .foregroundStyle(.rcTextSecondary)
            }
        }
        .lineLimit(1)

        Text(m.isProducing ? "Extracting resource" : "Seeking a workable pocket")
            .font(.rcCaption)
            .foregroundStyle(.rcTextTertiary)

        if let started = m.startedAt, let cycle = m.cycleTimeSeconds, cycle > 0 {
            MiningCycleView(startedAt: started, cycleSeconds: cycle)
        }

        VStack(alignment: .leading, spacing: Space.xs) {
            if let belt = beltValue(m) {
                taskRow("Belt", belt)
            }
            if let availability = m.availability {
                taskRow("Resource", DevicePresentation.displayName(availability))
            }
            taskRow("Yield", yieldValue(m))
            if let mined = m.quantityMined, mined > 0 {
                taskRow("Session", "\(Self.number(mined)) unit\(mined == 1 ? "" : "s") mined")
            }
        }
        .padding(.top, Space.xs)
    }

    // MARK: Repair readout

    /// The live readout for a repairing bot: the device it's mending, a progress
    /// bar (live-interpolated from `started_at`/`eta_seconds` when both are known,
    /// else the server's authoritative percent), and the completion percent.
    @ViewBuilder
    private func repairReadout(_ r: RepairSnapshot) -> some View {
        HStack(spacing: Space.xs) {
            Text("Repairing")
                .font(.rcHeadline)
                .foregroundStyle(.rcTextPrimary)
            if let target = r.targetDeviceCode {
                Text("·")
                    .font(.rcHeadline)
                    .foregroundStyle(.rcTextTertiary)
                Text(target)
                    .font(.rcMono)
                    .foregroundStyle(.rcTextSecondary)
                    .textSelection(.enabled)
            }
        }
        .lineLimit(1)

        if let started = r.startedAt, let completesAt = r.completesAt {
            OperationProgressView(startedAt: started, completesAt: completesAt, tint: StatusTone.working.color)
        } else if let pct = r.progressPercent {
            ProgressView(value: min(max(pct / 100, 0), 1))
                .tint(StatusTone.working.color)
        }

        if let pct = r.progressPercent {
            VStack(alignment: .leading, spacing: Space.xs) {
                taskRow("Progress", "\(Self.percent(pct)) complete")
            }
            .padding(.top, Space.xs)
        }
    }

    /// "ATIANFU-BELT-1 · Dense" — where it's mining and how dense the belt is.
    private func beltValue(_ m: MiningSnapshot) -> String? {
        let density = m.density.map(DevicePresentation.displayName)
        switch (m.belt, density) {
        case let (belt?, density?): return "\(belt) · \(density)"
        case let (belt?, nil):      return belt
        case let (nil, density?):   return density
        default:                    return nil
        }
    }

    /// The uncollected haul: "3 units · 1 cycle", or "none this cycle" when the
    /// last cycle came up empty (the seeking signal).
    private func yieldValue(_ m: MiningSnapshot) -> String {
        let quantity = m.pendingQuantity ?? 0
        let cycles = m.pendingCycles ?? 0
        guard quantity > 0 || cycles > 0 else { return "none this cycle" }
        var parts: [String] = ["\(Self.number(quantity)) unit\(quantity == 1 ? "" : "s")"]
        if cycles > 0 { parts.append("\(cycles) cycle\(cycles == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func taskRow(_ label: String, _ value: String, valueColor: Color = .rcTextSecondary) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text(label)
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.rcMonoSmall)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// "Small Incoming Asteroid" from the object's size class and type.
    private func objectSubtitle(_ d: DiversionSnapshot) -> String? {
        let parts = [d.sizeClass, d.objectType].compactMap { $0 }.map(DevicePresentation.displayName)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "ATIANFU-1 · in 7 days" — where the object strikes and how soon.
    private func impactValue(_ d: DiversionSnapshot) -> String? {
        let eta = d.impactEta.map { $0.formatted(.relative(presentation: .named)) }
        switch (d.impactTarget, eta) {
        case let (target?, eta?): return "\(target) · \(eta)"
        case let (target?, nil): return target
        case let (nil, eta?):     return eta
        default:                  return nil
        }
    }

    /// "1/hr · 24 required · 1 plate" — applied thrust vs. the strength needed.
    private func thrustValue(_ d: DiversionSnapshot) -> String? {
        var parts: [String] = []
        if let thrust = d.currentThrustPerHour { parts.append("\(Self.number(thrust))/hr") }
        if let required = d.requiredStrength { parts.append("\(Self.number(required)) required") }
        if let plates = d.activePlates { parts.append(plates == 1 ? "1 plate" : "\(plates) plates") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A near-certain impact reads as danger, a coin-flip as a warning.
    private func likelihoodColor(_ value: Double) -> Color {
        switch value {
        case 75...:   return .rcError
        case 40..<75: return .rcWarning
        default:      return .rcTextSecondary
        }
    }

    private static func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }

    /// Whole numbers stay whole (`24`), fractions keep one place (`1.5`).
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
