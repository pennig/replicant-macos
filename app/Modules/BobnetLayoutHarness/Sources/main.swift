//
//  main.swift — throwaway layout harness for the Bobnet channel switch.
//
//  Hosts the real detail pane in a real NSWindow, switches channels, and reports
//  the backing NSScrollView's geometry so undersized-content placement can be
//  read as numbers rather than guessed from a screenshot.
//

import AppKit
import BobnetFeature
import ComposableArchitecture
import GameDatabase
import GameModels
import SQLiteData
import SwiftUI
import UI

let messageCounts = ["#general": 800, "#trade": 225, "#claims": 12]

func bodyText(_ i: Int) -> String {
    let unit = "Relay traffic nominal, cargo manifest reconciled against the forge queue. "
    let repeats = (i % 17 == 0) ? 8 : (i % 5 == 0) ? 2 : 1
    return String(String(repeating: unit, count: repeats).prefix(i % 17 == 0 ? 574 : 40 + (i % 120)))
}

func seed(_ db: Database) throws {
    var id = 5345
    var rows: [BobnetMessage] = []
    for (channel, count) in messageCounts.sorted(by: { $0.key < $1.key }) {
        for i in 0..<count {
            rows.append(
                BobnetMessage(
                    id: id,
                    replicantName: "Replicant-\(i % 23)",
                    replicantCode: "RPL-\(i % 23)",
                    currentStar: i % 3 == 0 ? nil : "TAU-\(i % 9)",
                    channel: channel,
                    message: bodyText(i),
                    time: Date(timeIntervalSinceNow: -Double(count - i) * 60)
                )
            )
            id += 1
        }
    }
    for row in rows { try BobnetMessage.upsert { row }.execute(db) }
    // Markers sit behind the end so the unread divider actually renders.
    for (channel, _) in messageCounts {
        let maxID = rows.filter { $0.channel == channel }.map(\.id).max() ?? 0
        try BobnetChannel.upsert {
            BobnetChannel(
                name: channel,
                lastActive: Date(timeIntervalSinceNow: -60),
                lastReadMessageID: max(0, maxID - 5)
            )
        }.execute(db)
    }
}

/// Depth-first search for the NSScrollView backing the SwiftUI ScrollView.
func findScrollView(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for subview in view.subviews {
        if let found = findScrollView(subview) { return found }
    }
    return nil
}

func report(_ label: String, _ window: NSWindow) {
    guard let root = window.contentView, let scroll = findScrollView(root) else {
        print("\(label): NO NSSCROLLVIEW FOUND")
        return
    }
    let visible = scroll.contentView.bounds
    let documentHeight = scroll.documentView?.frame.height ?? -1
    let insets = scroll.contentInsets
    // gapBelow = how much content sits below the visible bottom edge. At a true
    // resting bottom this equals insets.bottom; undersized content should be 0.
    let gapBelow = documentHeight - (visible.origin.y + visible.height)
    print(String(
        format: "%@: originY=%8.1f visibleH=%7.1f documentH=%8.1f insets(t=%.0f,b=%.0f) gapBelow=%8.1f",
        label as NSString, visible.origin.y, visible.height,
        documentHeight, insets.top, insets.bottom, gapBelow
    ))
}

prepareDependencies {
    try! $0.bootstrapDatabase { db in try seed(db) }
}

let store = Store(initialState: BobnetFeature.State()) { BobnetFeature() }

struct Root: View {
    @Bindable var store: StoreOf<BobnetFeature>
    var body: some View {
        BobnetChannelDetailView(store: store).frame(width: 700, height: 800)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: Root(store: store))
        window.makeKeyAndOrderFront(nil)

        store.send(.binding(.set(\.selectedChannel, "#general")))
        spin(seconds: 3.0)
        report("long   (#general, 800)", window)

        store.send(.binding(.set(\.selectedChannel, "#claims")))
        spin(seconds: 3.0)
        report("short  (#claims,  12)", window)

        store.send(.binding(.set(\.selectedChannel, "#trade")))
        spin(seconds: 3.0)
        report("long2  (#trade,  225)", window)

        store.send(.binding(.set(\.selectedChannel, "#claims")))
        spin(seconds: 3.0)
        report("short2 (#claims,  12)", window)

        exit(0)
    }

    func spin(seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
            if let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
