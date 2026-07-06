import Foundation
import SwiftUI
import UI
import Utils

struct JSONTreeNode: Identifiable {
    enum Key: CustomStringConvertible {
        case index(Int)
        case property(String)
        
        var description: String {
            switch self {
            case .index(let index):
                String(index)
            case .property(let property):
                property
            }
        }
    }
    
    let id = UUID()
    let key: Key?
    let value: JSONValue
    
    // Built once at init so identities stay stable across re-renders. A
    // computed property would mint fresh UUIDs on every access and break
    // List diffing/expansion state.
    let children: [JSONTreeNode]?

    init(key: Key? = nil, value: JSONValue) {
        self.key = key
        self.value = value

        switch value {
        case .null, .bool, .number, .string:
            self.children = nil
        case .array(let array):
            self.children = array.enumerated().map {
                JSONTreeNode(key: .index($0), value: $1)
            }
        case .object(let dict):
            self.children = dict.sorted { $0.key < $1.key }.map {
                JSONTreeNode(key: .property($0.key), value: $0.value)
            }
        }
    }
}

extension EnvironmentValues {
    /// The expansion state every `JSONTreeRow` adopts on first render.
    /// Propagates through the whole subtree, so the tree starts either fully
    /// expanded or fully collapsed; thereafter each row tracks its own taps.
    @Entry var jsonInitiallyExpanded: Bool = false
}

/// Per-node expansion overrides, kept at the root so a row's state survives its
/// subtree being torn down when an ancestor collapses. Keyed by the node's
/// stable `id`; absence means "use the initial default".
@Observable final class JSONExpansionStore {
    var overrides: [UUID: Bool] = [:]
}

/// One rendered line in the flattened tree. A container contributes a
/// `.content` line (its label/opening bracket) and, when expanded, a matching
/// `.closing` line after all of its descendants; scalars contribute only a
/// `.content` line. Flattening to a linear list lets a single `LazyVStack`
/// materialize just the rows on screen, instead of the whole recursive view
/// tree being built up front.
private struct JSONFlatRow: Identifiable {
    enum Kind: Hashable {
        case content
        case closing
    }

    let node: JSONTreeNode
    let depth: Int
    let isRoot: Bool
    let kind: Kind

    // Node id alone isn't unique: a container's opening and closing lines share
    // it, so pair it with the kind for a stable per-line identity.
    struct RowID: Hashable {
        let node: UUID
        let kind: Kind
    }
    var id: RowID { RowID(node: node.id, kind: kind) }
}

struct JSONTreeView: View {
    let node: JSONTreeNode
    @State private var expansion = JSONExpansionStore()

    /// The initial expansion state the whole tree adopts (matches the
    /// `jsonInitiallyExpanded` environment value seeded below). Kept in sync so
    /// `flatten` and each row's chevron agree on what "no override" means.
    private static let initiallyExpanded = true

    /// Walk the tree in render order, emitting only the currently-visible rows.
    /// Reading `expansion.overrides` here makes `body` recompute (and the list
    /// re-diff) whenever a row is toggled. Skipping collapsed subtrees is what
    /// keeps large, mostly-collapsed responses cheap.
    private var visibleRows: [JSONFlatRow] {
        var rows: [JSONFlatRow] = []
        func walk(_ node: JSONTreeNode, depth: Int, isRoot: Bool) {
            rows.append(.init(node: node, depth: depth, isRoot: isRoot, kind: .content))
            let hasChildren = node.children?.isEmpty == false
            let expanded = isRoot ? true : (expansion.overrides[node.id] ?? Self.initiallyExpanded)
            if expanded, hasChildren, let children = node.children {
                for child in children {
                    walk(child, depth: depth + 1, isRoot: false)
                }
                rows.append(.init(node: node, depth: depth, isRoot: isRoot, kind: .closing))
            }
        }
        walk(node, depth: 0, isRoot: true)
        return rows
    }

    var body: some View {
        // A plain scroll container at the root. We deliberately avoid `List`
        // for the tree: nesting a List inside each row produces an inconsistent
        // outline tree that crashes SwiftUI's macOS OutlineListCoordinator, and
        // `List(_:children:)` won't let each row own its expansion state. A flat
        // `LazyVStack` over the precomputed visible rows sidesteps both while
        // materializing only the rows currently on screen.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleRows) { row in
                    JSONTreeRow(node: row.node, depth: row.depth, isRoot: row.isRoot, kind: row.kind)
                }
            }
            .environment(\.jsonInitiallyExpanded, Self.initiallyExpanded)
            .environment(expansion)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s)
        }
    }
}

/// The two JSON container kinds and the bracket pair that delimits each.
/// Shared by `JSONTreeLabel` (opening bracket + count badge) and `JSONTreeRow`
/// (the closing-bracket line shown beneath an expanded container's children).
private enum JSONContainer {
    case array
    case object

    /// Non-nil only for `.array` / `.object`; scalars have no bookends.
    init?(_ value: JSONValue) {
        switch value {
        case .array: self = .array
        case .object: self = .object
        default: return nil
        }
    }

    var bookends: (open: String, close: String) {
        switch self {
        case .array: ("[", "]")
        case .object: ("{", "}")
        }
    }
}

private struct JSONTreeRow: View {
    let node: JSONTreeNode
    var depth: Int = 0
    // The root row sits flush with no chevron column, and any container at the
    // root is permanently expanded (there's no control to collapse it).
    var isRoot: Bool = false
    // Whether this line is the container's label/opening bracket or its trailing
    // closing bracket. The flattener emits the two separately.
    var kind: JSONFlatRow.Kind = .content
    @State private var isHovered = false
    @Environment(\.jsonInitiallyExpanded) private var initiallyExpanded
    @Environment(JSONExpansionStore.self) private var expansion

    /// Width reserved for the chevron so leaf rows align with container labels.
    private static let chevronColumn = Space.m

    // Animating an expansion inserts every revealed descendant row at once;
    // past this many immediate children we skip the row transition (the chevron
    // still animates) so opening a large container stays snappy.
    private static let animationChildLimit = 50

    // Empty containers ([] / {}) carry a non-nil but empty `children`, so they
    // render as leaves: no chevron, no tap, and the label shows the empty pair.
    private var hasChildren: Bool { node.children?.isEmpty == false }

    // The root has no chevron and can't be collapsed, so its containers stay
    // open. Only non-root rows with children are interactive.
    private var isCollapsible: Bool { hasChildren && !isRoot }

    // The store override (set once the user taps) wins; otherwise fall back to
    // the environment's initial state. Lives at the root, so it survives this
    // row being torn down and rebuilt when an ancestor collapses. Root
    // containers ignore the store and stay expanded.
    private var isExpanded: Bool {
        if isRoot { return true }
        return expansion.overrides[node.id] ?? initiallyExpanded
    }

    var body: some View {
        switch kind {
        case .content: row
        case .closing: closingBracket
        }
    }

    private func toggle() {
        // Animate the reveal only for small containers; large ones would stutter
        // inserting hundreds of rows in one frame.
        let childCount = node.children?.count ?? 0
        if childCount <= Self.animationChildLimit {
            withAnimation(.snappy(duration: 0.2)) {
                expansion.overrides[node.id] = !isExpanded
            }
        } else {
            expansion.overrides[node.id] = !isExpanded
        }
    }

    @ViewBuilder
    private var row: some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            if !isRoot {
                chevron
            }
            JSONTreeLabel(node: node, expanded: isExpanded)
        }
        .padding(.leading, isRoot ? 0 : CGFloat(depth) * Space.l + Space.xs)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)

        if isCollapsible {
            // Expandable rows highlight on hover and toggle on a tap anywhere
            // across the full width.
            content
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(.rcSurfaceRaised)
                        .opacity(isHovered ? 1 : 0)
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .onTapGesture(perform: toggle)
        } else {
            // Leaf rows carry no tap gesture, leaving their values selectable.
            content
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if hasChildren {
            Image(systemName: "chevron.right")
                .font(.rcCaption)
                .foregroundStyle(.rcTextTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.snappy(duration: 0.2), value: isExpanded)
                .frame(width: Self.chevronColumn)
        } else {
            // Empty column keeps leaf rows aligned with their siblings' labels.
            Color.clear.frame(width: Self.chevronColumn, height: 1)
        }
    }
    
    // The closing `]` / `}`, shown on its own line beneath an expanded
    // container's children and aligned under the opening bracket. Only
    // containers reach here (scalars have no children), so the lookup is
    // always non-nil.
    @ViewBuilder
    private var closingBracket: some View {
        if let close = JSONContainer(node.value)?.bookends.close {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                if !isRoot {
                    // Mirror the opening row's chevron column so brackets align.
                    Color.clear.frame(width: Self.chevronColumn, height: 1)
                }
                Text(close)
                    .font(.rcMono)
                    .foregroundStyle(.rcTextSecondary)
            }
            .padding(.leading, isRoot ? 0 : CGFloat(depth) * Space.l + Space.xs)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct JSONTreeLabel: View {
    let node: JSONTreeNode
    let expanded: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            if let key = node.key {
                if case .index = key {
                    Text(key.description).foregroundStyle(.rcTextTertiary)
                } else {
                    Text(key.description).foregroundStyle(.rcJSONKey)
                }
                Text(":")
                    .foregroundStyle(.rcTextTertiary)
            }
            value
        }
        .font(.rcMono)
    }

    @ViewBuilder
    private var value: some View {
        switch node.value {
        case .null:
            scalar(Text("null").italic(), color: .rcTextTertiary)
        case .bool(let bool):
            scalar(Text(bool ? "true" : "false"), color: .rcTextSecondary)
        case .number(let number):
            scalar(Text(Self.numberText(number)), color: .rcJSONNumber)
        case .string(let string):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: "\"")
                Text(string).textSelection(.enabled)
                Text(verbatim: "\"")
            }
            .foregroundStyle(.rcJSONString)
            .fontWeight(.semibold)
        case .array(let array):
            ContainerLabel(container: .array, count: array.count, expanded: expanded)
        case .object(let object):
            ContainerLabel(container: .object, count: object.count, expanded: expanded)
        }
    }

    /// Shared treatment for scalar values: colored, semibold, and selectable.
    private func scalar(_ text: Text, color: Color) -> some View {
        text
            .foregroundStyle(color)
            .fontWeight(.semibold)
            .textSelection(.enabled)
    }

    /// `JSONValue` decodes every number as `Double`, losing the int/double
    /// distinction. Render integral values without a trailing ".0" so IDs and
    /// counts read naturally; fall back to the default formatting otherwise.
    private static func numberText(_ n: Double) -> String {
        if n.rounded() == n, abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(n)
    }
}

private extension JSONTreeLabel {
    private struct ContainerLabel: View {
        let container: JSONContainer
        let count: Int
        let expanded: Bool

        private var bookends: (open: String, close: String) { container.bookends }

        var body: some View {
            if count == 0 {
                // Empty containers are leaves: show the bare pair, no badge.
                Text("\(bookends.open)\(bookends.close)")
                    .foregroundStyle(.rcTextSecondary)
            } else {
                HStack(spacing: Space.xs) {
                    // Expanded containers show only the opening bracket here; the
                    // closing bracket is rendered as its own row by JSONTreeRow.
                    Text(expanded ? bookends.open : "\(bookends.open) … \(bookends.close)")
                        .foregroundStyle(.rcTextSecondary)
                    CountBadge(container: container, count: count)
                }
            }
        }
    }

    private struct CountBadge: View {
        let container: JSONContainer
        let count: Int

        private var label: LocalizedStringKey {
            switch container {
            case .array: "^[\(count) item](inflect: true)"
            case .object:  "^[\(count) key](inflect: true)"
            }
        }

        var body: some View {
            Text(label)
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextTertiary)
                .padding(.vertical, 2)
                .padding(.horizontal, Space.xs)
                .background(
                    .rcSurfaceRaised,
                    in: RoundedRectangle(cornerRadius: Radius.textBadge, style: .continuous)
                )
        }
    }
}

#Preview {
    JSONTreeView(node: .init(value: .object([
        "foo": .string("bar"),
        "wat": .null,
        "nah": .object([:]),
        "yep": .bool(true),
        "bar": .object([
            "baz": .string("qux"),
            "bam": .null,
            "appol": .string("This is a very long string that will wrap into multiple lines if rendered in a view and we should display it properly."),
            "bat": .array([
                .number(12),
                .number(14),
                .number(25),
                .number(12),
                .number(14),
                .number(25),
                .number(12),
                .number(14),
                .number(25),
                .number(12),
                .number(14),
                .number(25),
                .number(12),
                .number(14),
                .number(25),
                .number(12),
                .number(14),
                .number(25),
            ]),
        ])
    ]))).background(.rcWindowBackground)
}

#Preview {
    JSONTreeView(node: .init(value: .array([
        .object([
            "departed_at": .string("2026-05-29T18:45:12Z"),
            "arrived_at": .string("2026-05-30T07:22:59Z"),
        ]),
        .object([
            "departed_at": .string("2026-05-29T18:45:12Z"),
            "arrived_at": .string("2026-05-30T07:22:59Z"),
        ]),
    ]))).background(.rcWindowBackground)
}

#Preview {
    VStack {
        JSONTreeView(node: .init(value: .string("Hello, world!")))
        Divider()
        JSONTreeView(node: .init(value: .bool(false)))
        Divider()
        JSONTreeView(node: .init(value: .number(12.56)))
        Divider()
        JSONTreeView(node: .init(value: .null))
        Divider()
        JSONTreeView(node: .init(value: .array([.string("foo"), .string("bar")])))
        Divider()
        JSONTreeView(node: .init(value: .object(["foo": .string("bar"), "bar": .null])))
    }.background(.rcWindowBackground)
}
