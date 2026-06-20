import SwiftUI

public struct SelectableList<
    Data: RandomAccessCollection,
    ID: Hashable,
    RowContent: View
>: View {

    let items: Data
    let id: KeyPath<Data.Element, ID>

    @Binding var selection: ID?

    @ViewBuilder
    let rowContent: (Data.Element, Bool) -> RowContent

    @FocusState
    private var isFocused: Bool

    init(
        _ items: Data,
        id: KeyPath<Data.Element, ID>,
        selection: Binding<ID?>,
        @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent
    ) {
        self.items = items
        self.id = id
        self._selection = selection
        self.rowContent = rowContent
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {

                    ForEach(Array(items), id: id) { item in
                        let itemID = item[keyPath: id]

                        rowContent(item, selection == itemID)
                            .contentShape(Rectangle())
                            .id(itemID)
                            .onTapGesture {
                                selection = itemID
                                isFocused = true
                            }
                    }
                }
            }
            .onAppear {
                if selection == nil,
                   let first = items.first {
                    selection = first[keyPath: id]
                }
            }
            .onChange(of: selection) { _, newSelection in
                guard let newSelection else { return }

                proxy.scrollTo(newSelection)

                // A selection change here is always driven by interacting
                // with this list (a click or an arrow key), and the
                // programmatic scroll above can resign the wrapper's first
                // responder on macOS — which is why arrow keys worked only
                // once. Re-claim focus on the next runloop tick so the keys
                // keep working without a re-click.
                Task { isFocused = true }
            }
        }
        // Host focus on the container *around* the scroll view so that
        // programmatic scrolling and row re-renders can't knock the
        // scroll view out of first-responder after the first key press.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            moveSelection(.up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(.down)
            return .handled
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let ids = items.map { $0[keyPath: id] }

        guard !ids.isEmpty else { return }

        guard let selected = selection,
              let index = ids.firstIndex(of: selected)
        else {
            selection = ids.first
            return
        }

        switch direction {
        case .up:
            if index > 0 {
                selection = ids[index - 1]
            }

        case .down:
            if index < ids.count - 1 {
                selection = ids[index + 1]
            }

        default:
            break
        }
    }
}

public extension SelectableList
where Data.Element: Identifiable,
      ID == Data.Element.ID {

    init(
        _ items: Data,
        selection: Binding<ID?>,
        @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent
    ) {
        self.init(
            items,
            id: \.id,
            selection: selection,
            rowContent: rowContent
        )
    }
}
