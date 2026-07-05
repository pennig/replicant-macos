import SwiftUI

/// A keyboard-navigable, single-selection list.
///
/// There are two ways to drive the content:
///
/// 1. **Flat data** — pass a collection and a row builder (see the convenience
///    initializers below). The list builds a `ForEach` for you.
/// 2. **Custom content** — pass `orderedIDs` plus a `@ViewBuilder` and compose
///    the rows yourself using `ForEach`, `Section`, headers, etc. Wrap each
///    selectable row in a ``SelectableRow`` so it participates in selection,
///    tap handling, and scroll-to-selection. `orderedIDs` is the flat,
///    top-to-bottom order of the selectable rows and drives arrow-key
///    navigation and the initial selection.
public struct SelectableList<
    ID: Hashable & Sendable,
    Content: View
>: View {

    let orderedIDs: [ID]
    let pinnedViews: PinnedScrollableViews

    @Binding var selection: ID?

    @ViewBuilder
    let content: () -> Content

    @FocusState
    private var isFocused: Bool

    public init(
        selection: Binding<ID?>,
        orderedIDs: [ID],
        pinnedViews: PinnedScrollableViews = [],
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._selection = selection
        self.orderedIDs = orderedIDs
        self.pinnedViews = pinnedViews
        self.content = content
    }

    public var body: some View {
        // Capture bindings (not `self`) so the row-tap closure handed to the
        // environment can mutate selection/focus without capturing the view.
        let selectionBinding = $selection
        let focusBinding = $isFocused

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: pinnedViews) {
                    content()
                }
            }
            .environment(
                \.selectableRowContext,
                SelectableRowContext(
                    selectedID: selection.map(AnyHashable.init),
                    select: { anyID in
                        selectionBinding.wrappedValue = anyID.base as? ID
                        focusBinding.wrappedValue = true
                    }
                )
            )
            .onAppear {
                if selection == nil,
                   let first = orderedIDs.first {
                    selection = first
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
        guard !orderedIDs.isEmpty else { return }

        guard let selected = selection,
              let index = orderedIDs.firstIndex(of: selected)
        else {
            selection = orderedIDs.first
            return
        }

        switch direction {
        case .up:
            if index > 0 {
                selection = orderedIDs[index - 1]
            }

        case .down:
            if index < orderedIDs.count - 1 {
                selection = orderedIDs[index + 1]
            }

        default:
            break
        }
    }
}

// MARK: - Selectable row

/// Wraps a single row so it participates in a ``SelectableList``'s selection,
/// tap handling, and scroll-to-selection. The builder receives whether the row
/// is currently selected so it can style itself.
///
/// Use this when composing custom content (sections, headers, etc.):
///
/// ```swift
/// SelectableList(selection: $selection, orderedIDs: items.map(\.id), pinnedViews: [.sectionHeaders]) {
///     ForEach(groups) { group in
///         Section {
///             ForEach(group.items) { item in
///                 SelectableRow(id: item.id) { isSelected in
///                     ItemRow(item: item).rcSidebarRow(isSelected: isSelected)
///                 }
///             }
///         } header: {
///             GroupHeader(group)
///         }
///     }
/// }
/// ```
public struct SelectableRow<ID: Hashable & Sendable, Content: View>: View {

    let id: ID

    @ViewBuilder
    let content: (Bool) -> Content

    @Environment(\.selectableRowContext)
    private var context

    public init(
        id: ID,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.id = id
        self.content = content
    }

    public var body: some View {
        let isSelected = context.selectedID == AnyHashable(id)

        content(isSelected)
            .contentShape(Rectangle())
            .id(id)
            .onTapGesture { context.select(AnyHashable(id)) }
    }
}

// MARK: - Environment plumbing

// Touched only from SwiftUI's main-actor environment/body, hence `@unchecked`.
private struct SelectableRowContext: @unchecked Sendable {
    var selectedID: AnyHashable?
    var select: @MainActor (AnyHashable) -> Void
}

private struct SelectableRowContextKey: EnvironmentKey {
    static let defaultValue = SelectableRowContext(selectedID: nil, select: { _ in })
}

private extension EnvironmentValues {
    var selectableRowContext: SelectableRowContext {
        get { self[SelectableRowContextKey.self] }
        set { self[SelectableRowContextKey.self] = newValue }
    }
}

// MARK: - Flat-data convenience

public extension SelectableList {

    /// Builds a flat list from a collection, keyed by an explicit `id` key path.
    init<Data: RandomAccessCollection, RowContent: View>(
        _ items: Data,
        id: KeyPath<Data.Element, ID>,
        selection: Binding<ID?>,
        @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent
    ) where Content == ForEach<Data, ID, SelectableRow<ID, RowContent>> {
        self.init(
            selection: selection,
            orderedIDs: items.map { $0[keyPath: id] }
        ) {
            ForEach(items, id: id) { item in
                SelectableRow(id: item[keyPath: id]) { isSelected in
                    rowContent(item, isSelected)
                }
            }
        }
    }
}

public extension SelectableList {

    /// Builds a flat list from a collection of `Identifiable` elements.
    init<Data: RandomAccessCollection, RowContent: View>(
        _ items: Data,
        selection: Binding<ID?>,
        @ViewBuilder rowContent: @escaping (Data.Element, Bool) -> RowContent
    ) where Data.Element: Identifiable,
            ID == Data.Element.ID,
            Content == ForEach<Data, ID, SelectableRow<ID, RowContent>> {
        self.init(
            items,
            id: \.id,
            selection: selection,
            rowContent: rowContent
        )
    }
}

// MARK: - Sectioned convenience

/// A titled group of items for a sectioned ``SelectableList``. The list renders
/// the header chrome from `title`; you supply only the individual row view.
public struct SelectableSection<SectionID: Hashable, Element>: Identifiable {
    public var id: SectionID
    public var title: String
    public var items: [Element]

    public init(id: SectionID, title: String, items: [Element]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// The section header ``SelectableList`` renders for you — styled with the
/// design system's section-label tokens, aligned to the row gutter.
private struct SelectableSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.rcSectionLabel)
            .kerning(1)
            .foregroundStyle(.rcTextTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .padding(.top, Space.m)
            .padding(.bottom, Space.xs)
    }
}

/// The `Content` produced by ``SelectableList``'s sectioned initializers: a
/// `ForEach` of `Section`s, each with a rendered header and `SelectableRow`s.
public struct SelectableSections<
    SectionID: Hashable,
    Element,
    ID: Hashable & Sendable,
    RowContent: View
>: View {

    let sections: [SelectableSection<SectionID, Element>]
    let rowID: KeyPath<Element, ID>

    @ViewBuilder
    let row: (Element, Bool) -> RowContent

    public var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.items, id: rowID) { item in
                    SelectableRow(id: item[keyPath: rowID]) { isSelected in
                        row(item, isSelected)
                    }
                }
            } header: {
                SelectableSectionHeader(title: section.title)
            }
        }
    }
}

public extension SelectableList {

    /// Builds a sectioned list from `SelectableSection`s, keyed by an explicit
    /// `rowID` key path. The list renders each section's header; you supply a
    /// single row view. Pass `pinnedViews: [.sectionHeaders]` for sticky headers.
    init<SectionID: Hashable, Element, RowContent: View>(
        selection: Binding<ID?>,
        sections: [SelectableSection<SectionID, Element>],
        rowID: KeyPath<Element, ID>,
        pinnedViews: PinnedScrollableViews = [],
        @ViewBuilder row: @escaping (Element, Bool) -> RowContent
    ) where Content == SelectableSections<SectionID, Element, ID, RowContent> {
        self.init(
            selection: selection,
            orderedIDs: sections.flatMap(\.items).map { $0[keyPath: rowID] },
            pinnedViews: pinnedViews
        ) {
            SelectableSections(sections: sections, rowID: rowID, row: row)
        }
    }

    /// Builds a sectioned list whose elements are `Identifiable` — rows are
    /// keyed by `\.id`.
    init<SectionID: Hashable, Element: Identifiable, RowContent: View>(
        selection: Binding<ID?>,
        sections: [SelectableSection<SectionID, Element>],
        pinnedViews: PinnedScrollableViews = [],
        @ViewBuilder row: @escaping (Element, Bool) -> RowContent
    ) where ID == Element.ID,
            Content == SelectableSections<SectionID, Element, ID, RowContent> {
        self.init(
            selection: selection,
            sections: sections,
            rowID: \.id,
            pinnedViews: pinnedViews,
            row: row
        )
    }
}
