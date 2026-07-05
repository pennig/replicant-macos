import SwiftUI

/// The visual treatment of a ``SelectableList`` and its rows.
public enum SelectableListStyle: Sendable {
    /// An inset, rounded selection card whose accent indicator bleeds into the
    /// leading gutter. This is the default.
    case sidebar
    /// A full-bleed selection band flush with the container's edges, with the
    /// accent bar running the full height of the row on the leading edge.
    case inline
}

struct SelectableListStyleKey: EnvironmentKey {
    static let defaultValue: SelectableListStyle = .sidebar
}

extension EnvironmentValues {
    var selectableListStyle: SelectableListStyle {
        get { self[SelectableListStyleKey.self] }
        set { self[SelectableListStyleKey.self] = newValue }
    }
}

/// Whether the row is currently pressed (pointer down, before the click commits
/// its selection) — published by `SelectableRow`'s button so the inline style can
/// show a pre-selection highlight.
struct SelectableRowPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var selectableRowIsPressed: Bool {
        get { self[SelectableRowPressedKey.self] }
        set { self[SelectableRowPressedKey.self] = newValue }
    }
}

extension View {
    public func rcSidebarRow(isSelected: Bool) -> some View {
        modifier(RCSidebarRowStyle(isSelected: isSelected))
    }
}

public struct RCSidebarRowStyle: ViewModifier {
    let isSelected: Bool

    @Environment(\.selectableListStyle)
    private var listStyle

    @Environment(\.selectableRowIsPressed)
    private var isPressed

    @ViewBuilder
    public func body(content: Content) -> some View {
        switch listStyle {
        case .sidebar: sidebarBody(content)
        case .inline:  inlineBody(content)
        }
    }

    /// The default treatment: an inset, rounded selection card whose accent
    /// capsule bleeds into the leading gutter.
    private func sidebarBody(_ content: Content) -> some View {
        content
            .padding(Space.xs)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isSelected ? Color.rcAccentMuted : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(isSelected ? Color.rcAccentBorder : .clear, lineWidth: 0.5)
                    )
            )
            // the leading indicator, bleeding into the gutter
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Color.rcAccent)
                        .frame(width: 3)
                        .padding(.vertical, Space.s)
                        .offset(x: -7)
                        .shadow(color: .rcAccent.opacity(0.7), radius: 4)
                }
            }
            .contentShape(Rectangle())
            .padding(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 4))
    }

    /// The inline treatment: a full-bleed selection band flush with the
    /// container's edges, with the accent bar running the row's full height on
    /// the leading edge.
    private func inlineBody(_ content: Content) -> some View {
        content
            .padding(.vertical, Space.s)
            .padding(.horizontal, Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Muted-accent fill for both the committed selection and the
            // transient pressed state; the leading capsule stays selection-only.
            .background(isSelected || isPressed ? Color.rcAccentMuted : .clear)
            // hairline divider between rows, spanning the full width
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.rcSeparator)
                    .frame(height: 1)
            }
            // the leading indicator, flush on the container's leading edge
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Color.rcAccent)
                        .frame(width: 3)
                        .padding(.vertical, Space.s)
                        .shadow(color: .rcAccent.opacity(0.7), radius: 4)
                }
            }
            .contentShape(Rectangle())
    }
}
