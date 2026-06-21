import SwiftUI

extension View {
    public func rcSidebarRow(isSelected: Bool) -> some View {
        modifier(RCSidebarRowStyle(isSelected: isSelected))
    }
}

public struct RCSidebarRowStyle: ViewModifier {
    let isSelected: Bool
    public func body(content: Content) -> some View {
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
                            .padding(.vertical, 8)
                            .offset(x: -7)
                            .shadow(color: .rcAccent.opacity(0.7), radius: 4)
                    }
                }
                .contentShape(Rectangle())
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 4))
    }
}
