import SwiftUI
import UI

// The tappable SwiftUI layer that floats an inbound/outbound travel card over the top of
// each dotted riser the renderer draws out of the orbital plane. A DEDICATED view (not
// inlined into `NewStarMapView`) on purpose: its `body` reads `projection.callouts`, which
// the renderer mutates every frame — keeping it separate means only this view re-renders
// per frame, never the map view (whose `body` builds the whole star terrain). Empty areas
// capture no hits, so clicks fall through to the Metal map exactly like the ship icons.
//
// Chrome is deliberately glass-free (solid fill + hairline, no heavy shadow): an
// `.ultraThinMaterial` card with a big shadow hitches the main-thread MTKView camera fly.

/// Floats a small "Traveling from/to …" card over each transit riser, tracking it per-frame.
struct TransitCalloutLayer: View {
    let projection: TransitProjectionModel
    /// deviceCode → deviceType, so each card can resolve its `device.<type>` glyph.
    let deviceTypes: [String: String]
    let selectedDeviceCode: String?
    let onSelect: (String) -> Void

    /// The backing store's pixel density, so we can snap each card to whole physical pixels.
    @Environment(\.displayScale) private var displayScale

    /// Points to raise the card above its riser top, ~half a two-line card, so the dotted
    /// line connects to the card's lower edge rather than piercing its centre.
    private let cardLift: CGFloat = 18

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(projection.callouts) { callout in
                TransitCard(
                    symbolName: "device.\(deviceTypes[callout.deviceCode] ?? "")",
                    direction: callout.direction,
                    endpointCode: callout.endpointCode,
                    viaCode: callout.viaCode,
                    eventAt: callout.eventAt,
                    isSelected: callout.deviceCode == selectedDeviceCode,
                    action: { onSelect(callout.deviceCode) }
                )
                // Sit the card above the riser top so the dotted line meets its lower edge.
                .position(snapped(CGPoint(x: callout.point.x, y: callout.point.y - cardLift)))
                .opacity(callout.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Snap a projected point to the physical pixel grid — the anchor streams in at
    /// continuously-fractional points; landing the flattened card bitmap on exact pixels
    /// keeps it crisp. Sub-point stepping (one physical pixel) is imperceptible.
    private func snapped(_ point: CGPoint) -> CGPoint {
        let scale = max(displayScale, 1)
        return CGPoint(x: (point.x * scale).rounded() / scale,
                       y: (point.y * scale).rounded() / scale)
    }
}

/// One transit callout: a ship glyph + two lines naming where the trip comes from / goes
/// to. Location codes render in a mono token per the system-name rule.
private struct TransitCard: View {
    let symbolName: String
    let direction: ProjectedTransit.Direction
    let endpointCode: String
    let viaCode: String?
    let eventAt: Date
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    private var verb: String { direction == .inbound ? "Traveling from" : "Traveling to" }

    /// What the countdown measures, relative to the view you're looking at: when
    /// the device shows up here, or when it leaves. Deliberately NOT the trip's
    /// final arrival — that's on the device detail's Active Task card and the
    /// sidebar progress bar, and it isn't what this riser marks.
    private var countdownLabel: String { direction == .inbound ? "enters in" : "leaves in" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image.rcSymbol(symbolName)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: IconSize.m, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.rcAccent : .rcTextPrimary)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Space.xs) {
                        Text(verb)
                            .font(.rcCaption)
                            .foregroundStyle(.rcTextSecondary)
                        Text(endpointCode)
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextPrimary)
                    }
                    if let viaCode {
                        HStack(spacing: Space.xs) {
                            Text("via")
                                .font(.rcCaption)
                                .foregroundStyle(.rcTextSecondary)
                            Text(viaCode)
                                .font(.rcMonoSmall)
                                .foregroundStyle(.rcTextPrimary)
                        }
                    }
                    // Live countdown to this view's boundary crossing — self-updating,
                    // so it ticks without the renderer re-pushing the projection each
                    // second.
                    if eventAt > .now {
                        HStack(spacing: Space.xs) {
                            Text(countdownLabel)
                                .font(.rcCaption)
                                .foregroundStyle(.rcTextSecondary)
                            Text(timerInterval: .now...eventAt, countsDown: true)
                                .font(.rcMonoSmall)
                                .monospacedDigit()
                                .foregroundStyle(.rcAccent)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(.rcSurfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(
                        isSelected ? Color.rcAccent : .white.opacity(hovered ? 0.35 : 0.12),
                        lineWidth: isSelected ? 1.5 : Hairline.thin)
            )
            // NOTE: no `.drawingGroup()` here (unlike `ShipIcon`) — it would rasterize a
            // snapshot and freeze the live `arrives in …` timer.
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("View device")
    }
}
