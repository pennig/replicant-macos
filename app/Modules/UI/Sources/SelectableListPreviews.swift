import SwiftUI

// Previews live in their own file: `#Preview` subjects its whole file to the
// design-time rewriter, which chokes on `SelectableList`'s convenience
// initializers (`self.init` delegation). Keeping them apart sidesteps that.
private struct SelectableListStyleGallery: View {
    let style: SelectableListStyle

    @State private var selection: String?

    private struct Item: Identifiable {
        let id: String
        let name: String
        let status: String
        let tone: Color
    }

    private let items: [Item] = [
        .init(id: "B58FCC78", name: "Mining Drone", status: "Mining · Iron", tone: .rcStatusWorking),
        .init(id: "A1F00C2D", name: "Survey Probe", status: "Prospecting", tone: .rcStatusSensing),
        .init(id: "7C0E9B41", name: "FTL Relay", status: "Relaying", tone: .rcStatusRelay),
    ]

    init(style: SelectableListStyle) {
        self.style = style
        _selection = State(initialValue: "B58FCC78")
    }

    var body: some View {
        SelectableList(items, selection: $selection, style: style) { item, isSelected in
            row(item).rcSidebarRow(isSelected: isSelected)
        }
        .frame(width: 340, height: 240)
        .background(.rcContentBackground)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: Space.m) {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(.rcSurfaceRaised)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "hexagon")
                        .foregroundStyle(item.tone)
                }

            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(item.name)
                        .font(.rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                    Text(item.id)
                        .font(.rcMono)
                        .foregroundStyle(.rcTextTertiary)
                }
                HStack(spacing: Space.s) {
                    Circle()
                        .fill(item.tone)
                        .frame(width: 6, height: 6)
                    Text(item.status)
                        .font(.rcCaption)
                        .foregroundStyle(.rcTextSecondary)
                }
            }

            Spacer()
        }
    }
}

#Preview("Sidebar style") {
    SelectableListStyleGallery(style: .sidebar)
}

#Preview("Inline style") {
    SelectableListStyleGallery(style: .inline)
}
