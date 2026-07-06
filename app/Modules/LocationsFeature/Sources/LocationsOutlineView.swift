//
//  LocationsOutlineView.swift
//  LocationsFeature
//
//  The catalog list's renderer: an `NSTableView` wrapped for SwiftUI. macOS
//  forces a choice in pure SwiftUI between cell recycling (`List`/`Table`) and
//  row insert/remove animation (`LazyVStack`) — `List` won't animate row diffs.
//  `NSTableView` does both natively, which is why the list drops to AppKit here
//  (sanctioned by CLAUDE.md for UX-critical cases).
//
//  The store stays the source of truth: this view is a pure renderer over the
//  flattened `[LocationFlatRow]` (`LocationTree.flatten`), a `selection` binding,
//  and an `onToggle` callback. Expansion, selection, sort/filter, and hydration
//  all still live in `LocationsFeature`.
//
//  Interaction split:
//    - The hosted SwiftUI row passes clicks through (`hitTest` → nil), so the
//      table owns selection + keyboard navigation.
//    - `mouseDown` toggles expansion when the click lands in the chevron's
//      x-region (derived from the row's depth); anything else selects.
//    - Row insert/remove animates via a by-id diff of old vs new rows; wholesale
//      changes (filter/sort) fall back to `reloadData`.
//

import AppKit
import SwiftUI
import UI
import UniverseModels

// MARK: - Shared geometry

/// Row metrics shared by the hosted SwiftUI content and the chevron hit-test, so
/// the drawn chevron and the tappable region stay aligned. `leadingInset` mirrors
/// the `.inline` `rcSidebarRow` horizontal padding; `indentStep`/`chevronColumn`
/// mirror `LocationRow`'s layout.
enum LocationRowMetrics {
    static let leadingInset = SelectableListMetrics.leadingPadding
    static let indentStep = Space.l
    static let chevronColumn = Space.l
    static let rowHeight: CGFloat = 44

    /// The chevron's horizontal span for a row at `depth`, in the table's
    /// coordinate space (x from the left edge of the full-bleed row).
    static func chevronRange(depth: Int) -> ClosedRange<CGFloat> {
        let minX = leadingInset + CGFloat(depth) * indentStep
        return minX...(minX + chevronColumn)
    }
}

// MARK: - Hosted row content (non-interactive)

/// The row's visuals, hosted per cell. Deliberately non-interactive — selection
/// and the chevron toggle are handled by the table — so it just reflects `row`
/// and `isSelected`. Uses the explicit `.inline` style since there's no
/// `SelectableList` environment in the AppKit host.
struct LocationOutlineRowContent: View {
    let row: LocationFlatRow
    let isSelected: Bool
    let isPressed: Bool

    var body: some View {
        HStack(spacing: 0) {
            if row.depth > 0 {
                Color.clear.frame(width: CGFloat(row.depth) * LocationRowMetrics.indentStep, height: 4)
            }
            chevron
            LocationRow(node: row.node)
        }
        .rcSidebarRow(isSelected: isSelected, isPressed: isPressed, style: .inline)
    }

    @ViewBuilder
    private var chevron: some View {
        if row.hasChildren {
            Image(systemName: "chevron.right")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .animation(.snappy(duration: 0.2), value: row.isExpanded)
                .frame(width: LocationRowMetrics.chevronColumn)
        } else {
            Color.clear.frame(width: LocationRowMetrics.chevronColumn, height: 1)
        }
    }
}

// MARK: - Click-through hosting view

/// An `NSHostingView` that never captures clicks, so mouse events reach the
/// table row beneath it (which owns selection). The chevron toggle is resolved
/// by the table's `mouseDown`, not by the hosted content.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The reusable cell: a single click-through hosting view pinned to its edges.
private final class LocationHostingCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("LocationHostingCell")

    private let hosting = ClickThroughHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func host<V: View>(_ view: V) {
        hosting.rootView = AnyView(view)
    }
}

// MARK: - Table view (chevron hit-testing)

/// `NSTableView` that toggles expansion when a click lands in a row's chevron
/// region and otherwise selects normally (via `super`).
private final class LocationsTableView: NSTableView {
    var rowsProvider: () -> [LocationFlatRow] = { [] }
    var onToggle: (String) -> Void = { _ in }
    /// Publishes the pressed row id (nil to clear) so the hosted content can show
    /// the pre-selection highlight, matching `SelectableList`'s `.inline` style.
    var setPressed: (String?) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let downRow = row(at: point)
        let rows = rowsProvider()
        guard downRow >= 0, downRow < rows.count else {
            super.mouseDown(with: event)
            return
        }
        let node = rows[downRow]

        if node.hasChildren {
            let range = LocationRowMetrics.chevronRange(depth: node.depth)
            // A small slop on each side keeps the small chevron easy to hit.
            if point.x >= range.lowerBound - 4, point.x <= range.upperBound + 4 {
                onToggle(node.id)
                return
            }
        }

        // Own the tracking loop rather than calling `super` (whose drag-select
        // commits selection to wherever the mouse *ends up*). Button-like, matching
        // `SelectableList`: highlight while the pointer is over the mouse-down row,
        // and select only if mouse-up lands back on that same row.
        window?.makeFirstResponder(self)
        var isOverDownRow = true
        setPressed(node.id)
        reloadRow(id: node.id)

        trackingLoop: while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let location = convert(next.locationInWindow, from: nil)
            let overDownRow = row(at: location) == downRow

            switch next.type {
            case .leftMouseDragged:
                if overDownRow != isOverDownRow {
                    isOverDownRow = overDownRow
                    setPressed(overDownRow ? node.id : nil)
                    reloadRow(id: node.id)
                }

            case .leftMouseUp:
                setPressed(nil)
                reloadRow(id: node.id)
                if overDownRow {
                    selectRowIndexes(IndexSet(integer: downRow), byExtendingSelection: false)
                }
                break trackingLoop

            default:
                break
            }
        }
    }

    private func reloadRow(id: String) {
        guard let index = rowsProvider().firstIndex(where: { $0.id == id }) else { return }
        reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }
}

// MARK: - Representable

/// SwiftUI wrapper around the recycling, animating `NSTableView`.
struct LocationsOutlineView: NSViewRepresentable {
    let rows: [LocationFlatRow]
    @Binding var selection: String?
    let onToggle: (String) -> Void

    /// Above this many combined inserts+removes we skip the animation and reload
    /// (filter/sort/search changes touch thousands of rows).
    private static let animationLimit = 400

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let table = LocationsTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = LocationRowMetrics.rowHeight
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("location"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        table.dataSource = coordinator
        table.delegate = coordinator
        table.rowsProvider = { [weak coordinator] in coordinator?.rows ?? [] }
        table.onToggle = onToggle
        table.setPressed = { [weak coordinator] in coordinator?.pressedID = $0 }

        coordinator.tableView = table
        coordinator.rows = rows

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? LocationsTableView else { return }
        let coordinator = context.coordinator
        coordinator.selection = $selection
        table.onToggle = onToggle

        let old = coordinator.rows
        let new = rows
        coordinator.rows = new

        applyRowDiff(table: table, old: old, new: new)
        applySelection(table: table, coordinator: coordinator, new: new)
    }

    // MARK: Row diff / animation

    private func applyRowDiff(table: LocationsTableView, old: [LocationFlatRow], new: [LocationFlatRow]) {
        let oldIDs = old.map(\.id)
        let newIDs = new.map(\.id)

        // No structural change — reload only rows whose content differs (e.g. a
        // toggled parent's chevron, updated badges).
        if oldIDs == newIDs {
            let changed = changedIndexes(old: old, new: new)
            if !changed.isEmpty {
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            }
            return
        }

        let oldSet = Set(oldIDs)
        let newSet = Set(newIDs)
        let removed = IndexSet(old.indices.filter { !newSet.contains(old[$0].id) })
        let inserted = IndexSet(new.indices.filter { !oldSet.contains(new[$0].id) })

        // Animate only a clean incremental change: the rows common to both keep
        // their relative order (an expand/collapse) and the delta is small.
        let commonOld = oldIDs.filter { newSet.contains($0) }
        let commonNew = newIDs.filter { oldSet.contains($0) }
        let isIncremental = commonOld == commonNew
            && removed.count + inserted.count <= Self.animationLimit

        guard isIncremental else {
            table.reloadData()
            return
        }

        table.beginUpdates()
        if !removed.isEmpty { table.removeRows(at: removed, withAnimation: .slideUp) }
        if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: .slideDown) }
        table.endUpdates()

        // The toggled parent stays (same id) but its `isExpanded` flipped — reload
        // it at its new index so the chevron reflects the new state.
        let changed = changedCommonIndexes(old: old, new: new)
        if !changed.isEmpty {
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        }
    }

    /// Indexes where same-position rows differ (structure unchanged).
    private func changedIndexes(old: [LocationFlatRow], new: [LocationFlatRow]) -> IndexSet {
        var set = IndexSet()
        for (i, pair) in zip(old, new).enumerated() where pair.0 != pair.1 {
            set.insert(i)
        }
        return set
    }

    /// New-space indexes of rows present in both old and new whose value changed.
    private func changedCommonIndexes(old: [LocationFlatRow], new: [LocationFlatRow]) -> IndexSet {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var set = IndexSet()
        for (i, row) in new.enumerated() {
            if let previous = oldByID[row.id], previous != row {
                set.insert(i)
            }
        }
        return set
    }

    // MARK: Selection

    private func applySelection(table: LocationsTableView, coordinator: Coordinator, new: [LocationFlatRow]) {
        coordinator.isApplyingSelection = true
        defer { coordinator.isApplyingSelection = false }

        let targetIndex = selection.flatMap { id in new.firstIndex { $0.id == id } }

        if let targetIndex {
            if table.selectedRow != targetIndex {
                table.selectRowIndexes(IndexSet(integer: targetIndex), byExtendingSelection: false)
                table.scrollRowToVisible(targetIndex)
            }
        } else if table.selectedRow != -1 {
            table.deselectAll(nil)
        }

        // `selectionHighlightStyle = .none` means the hosted content draws the
        // selection, so reload the rows whose selected state flipped.
        if coordinator.renderedSelection != selection {
            var idxs = IndexSet()
            if let previous = coordinator.renderedSelection,
               let i = new.firstIndex(where: { $0.id == previous }) { idxs.insert(i) }
            if let targetIndex { idxs.insert(targetIndex) }
            if !idxs.isEmpty {
                table.reloadData(forRowIndexes: idxs, columnIndexes: IndexSet(integer: 0))
            }
            coordinator.renderedSelection = selection
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [LocationFlatRow] = []
        var selection: Binding<String?>
        weak var tableView: NSTableView?

        /// Guards the selection round-trip: we set the table's selection to match
        /// the store, which fires `selectionDidChange` — ignore it while applying.
        var isApplyingSelection = false
        /// The selection currently reflected in the hosted rows, so we know which
        /// rows to reload when it changes.
        var renderedSelection: String?
        /// The row currently pressed (pointer down, before mouse-up commits the
        /// selection), for the pre-selection highlight.
        var pressedID: String?

        init(selection: Binding<String?>) {
            self.selection = selection
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: LocationHostingCell.reuseID, owner: nil) as? LocationHostingCell
                ?? LocationHostingCell(frame: .zero)
            let node = rows[row]
            cell.host(LocationOutlineRowContent(
                row: node,
                isSelected: node.id == selection.wrappedValue,
                isPressed: node.id == pressedID
            ))
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let index = tableView.selectedRow
            let newSelection = (index >= 0 && index < rows.count) ? rows[index].id : nil
            if selection.wrappedValue != newSelection {
                selection.wrappedValue = newSelection
            }
        }
    }
}
