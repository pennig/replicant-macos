//
//  JSONTreeNodeIdentityTests.swift
//  Replicould — UI
//
//  `JSONTreeView` rebuilds its node tree on every `body` evaluation, so a node's
//  `id` must depend only on the JSON's shape: two trees built from equal values
//  have to be interchangeable to `ForEach`, or every row loses its identity.
//

import Foundation
import Testing
import Utils
@testable import UI

@Suite struct JSONTreeNodeIdentityTests {

    private let payload = JSONValue.object([
        "event": .string("ami.survey.digest"),
        "report": .object([
            "scans": .array([
                .object(["planet": .string("SOL-3"), "moons": .array([.string("SOL-3-1")])]),
                .object(["planet": .string("SOL-4"), "moons": .array([])]),
            ])
        ]),
    ])

    /// Every id in the tree, in render order.
    private func ids(_ node: JSONTreeNode) -> [JSONTreeNode.ID] {
        (node.children ?? []).reduce(into: [node.id]) { $0 += ids($1) }
    }

    @Test func rebuildingTheSameDocumentYieldsTheSameIDs() {
        #expect(
            ids(JSONTreeNode(documentID: "evt-1", value: payload))
                == ids(JSONTreeNode(documentID: "evt-1", value: payload))
        )
    }

    /// Structurally identical documents must not share a keyspace, or one
    /// document's collapsed rows apply to the next one selected.
    @Test func differentDocumentsShareNoIDs() {
        let first = Set(ids(JSONTreeNode(documentID: "evt-1", value: payload)))
        let second = Set(ids(JSONTreeNode(documentID: "evt-2", value: payload)))
        #expect(first.isDisjoint(with: second))
    }

    @Test func idsAreUniqueWithinATree() {
        let all = ids(JSONTreeNode(documentID: "evt-1", value: payload))
        #expect(Set(all).count == all.count)
    }

    @Test func equalSiblingsStillGetDistinctIDs() {
        let children = JSONTreeNode(documentID: "evt-1", value: .array([.string("x"), .string("x")])).children ?? []
        #expect(children.count == 2)
        #expect(children[0].id != children[1].id)
    }
}
