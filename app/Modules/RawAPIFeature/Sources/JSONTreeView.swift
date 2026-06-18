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
    /// The expansion state every `JSONTreeDisclosure` adopts on first render.
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

struct JSONTreeView: View {
    let node: JSONTreeNode
    @State private var expansion = JSONExpansionStore()

    var body: some View {
        // A plain scroll container at the root. We deliberately avoid `List`
        // for the recursive tree: nesting a List inside each row produces an
        // inconsistent outline tree that crashes SwiftUI's macOS
        // OutlineListCoordinator. Recursive DisclosureGroups are safe here and,
        // unlike `List(_:children:)`, let each row own its expansion state.
        ScrollView {
            JSONTreeDisclosure(node: node)
                .environment(\.jsonInitiallyExpanded, true)
                .environment(expansion)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .scrollBounceBehavior(.automatic)
    }
}

private struct JSONTreeDisclosure: View {
    let node: JSONTreeNode
    var depth: Int = 0
    @State private var isHovered = false
    @Environment(\.jsonInitiallyExpanded) private var initiallyExpanded
    @Environment(JSONExpansionStore.self) private var expansion

    /// Width reserved for the chevron so leaf rows align with container labels.
    private static let chevronColumn = Space.m

    // Empty containers ([] / {}) carry a non-nil but empty `children`, so they
    // render as leaves: no chevron, no tap, and the label shows the empty pair.
    private var hasChildren: Bool { node.children?.isEmpty == false }

    // The store override (set once the user taps) wins; otherwise fall back to
    // the environment's initial state. Lives at the root, so it survives this
    // row being torn down and rebuilt when an ancestor collapses.
    private var isExpanded: Bool { expansion.overrides[node.id] ?? initiallyExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExpanded, let children = node.children {
                ForEach(children) { child in
                    JSONTreeDisclosure(node: child, depth: depth + 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var row: some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            chevron
            JSONTreeRow(node: node, expanded: isExpanded)
        }
        .padding(.leading, CGFloat(depth) * Space.l + Space.xs)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)

        if hasChildren {
            // Expandable rows highlight on hover and toggle on a tap anywhere
            // across the full width.
            content
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Color.rcSurfaceRaised)
                        .opacity(isHovered ? 1 : 0)
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.2)) {
                        expansion.overrides[node.id] = !isExpanded
                    }
                }
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
                .foregroundStyle(Color.rcTextTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: Self.chevronColumn)
        } else {
            // Empty column keeps leaf rows aligned with their siblings' labels.
            Color.clear.frame(width: Self.chevronColumn, height: 0)
        }
    }
}

private struct JSONTreeRow: View {
    let node: JSONTreeNode
    let expanded: Bool

    var body: some View {
        HStack(spacing: Space.xs) {
            if let key = node.key {
                if case .index = key {
                    Text(key.description).foregroundStyle(Color.rcTextTertiary)
                } else {
                    Text(key.description).foregroundStyle(Color.rcJSONKey)
                }
                Text(":")
                    .foregroundStyle(Color.rcTextTertiary)
            }
            value
        }
        .font(.rcMono)
    }

    @ViewBuilder
    private var value: some View {
        switch node.value {
        case .null:
            scalar(Text("null").italic(), color: Color.rcTextTertiary)
        case .bool(let bool):
            scalar(Text(bool ? "true" : "false"), color: Color.rcTextSecondary)
        case .number(let number):
            scalar(Text(Self.numberText(number)), color: Color.rcJSONNumber)
        case .string(let string):
            // Quotes are separate, non-selectable Texts so a drag selects only
            // the content between them.
            HStack(spacing: 0) {
                Text(verbatim: "\"")
                Text(string).textSelection(.enabled)
                Text(verbatim: "\"")
            }
            .foregroundStyle(Color.rcJSONString)
            .fontWeight(.semibold)
        case .array(let array):
            ContainerLabel(containerType: .array, count: array.count, expanded: expanded)
        case .object(let object):
            ContainerLabel(containerType: .object, count: object.count, expanded: expanded)
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

private extension JSONTreeRow {
    enum ContainerType {
        case array
        case object
    }
    
    private struct ContainerLabel: View {
        let containerType: ContainerType
        let count: Int
        let expanded: Bool
        
        var bookends: (String, String) {
            switch containerType {
            case .array: ("[", "]")
            case .object: ("{", "}")
            }
        }
        
        var body: some View {
            if count == 0 {
                // Empty containers are leaves: show the bare pair, no badge.
                Text("\(bookends.0)\(bookends.1)")
                    .foregroundStyle(Color.rcTextSecondary)
            } else {
                HStack(spacing: Space.xs) {
                    Text(expanded ? bookends.0 : "\(bookends.0) … \(bookends.1)")
                        .foregroundStyle(Color.rcTextSecondary)
                    CountBadge(containerType: containerType, count: count)
                }
            }
        }
    }
    
    private struct CountBadge: View {
        let containerType: ContainerType
        let count: Int

        private var label: LocalizedStringKey {
            switch containerType {
            case .array: "^[\(count) item](inflect: true)"
            case .object:  "^[\(count) key](inflect: true)"
            }
        }

        var body: some View {
            Text(label)
                .font(.rcMonoSmall)
                .foregroundStyle(Color.rcTextTertiary)
                .padding(.vertical, 1)
                .padding(.horizontal, Space.xs)
                .background(
                    Color.rcSurfaceRaisedStrong,
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
    ]))).background(Color.rcWindowBackground)
}
