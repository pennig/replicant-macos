import SwiftUI
import Utils

// Previews kept in their own file: an inline `#Preview` alongside the row
// structs it renders can wedge Xcode 26's preview build, so the tree's samples
// live here, apart from `JSONTreeView`'s implementation.

#Preview {
    JSONTreeView(node: .init(documentID: "nested-object", value: .object([
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
    JSONTreeView(node: .init(documentID: "legs", value: .array([
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
        JSONTreeView(node: .init(documentID: "scalar-string", value: .string("Hello, world!")))
        Divider()
        JSONTreeView(node: .init(documentID: "scalar-bool", value: .bool(false)))
        Divider()
        JSONTreeView(node: .init(documentID: "scalar-number", value: .number(12.56)))
        Divider()
        JSONTreeView(node: .init(documentID: "scalar-null", value: .null))
        Divider()
        JSONTreeView(node: .init(documentID: "flat-array", value: .array([.string("foo"), .string("bar")])))
        Divider()
        JSONTreeView(node: .init(documentID: "flat-object", value: .object(["foo": .string("bar"), "bar": .null])))
    }.background(.rcWindowBackground)
}
