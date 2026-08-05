//
//  DeviceListLayout.swift
//  Replicould — Devices feature
//
//  How the fleet master list is organised. A pure, SwiftUI-free namespace: the
//  whole of search, containment, collapse, and attention promotion is plain
//  functions over values, so it is unit-tested directly rather than through the
//  view. Deliberately NOT a static on `DevicesListView` — pure logic hung off a
//  SwiftUI `View` traps with signal 5 under `swift test`
//  (.claude/memory/swiftui-view-statics-trap-in-tests.md).
//
//  DO NOT `import SwiftUI` in this file.
//

import Foundation
import GameModels

public enum DeviceListLayout {

    /// Rows deeper than this share the deepest indent. The containment tree is
    /// genuinely two levels (Vessel → AMI controller → drones); anything below
    /// that is a data surprise and should not run the row off the edge.
    static let maxIndentDepth = 2
}
