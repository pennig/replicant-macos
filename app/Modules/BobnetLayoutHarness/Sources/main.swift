//
//  main.swift — throwaway layout harness for the Bobnet channel switch.
//
//  Hosts the real detail pane -- bare, or wrapped in the shipping three-column
//  NavigationSplitView -- in a real NSWindow, switches channels, and reports the
//  backing NSScrollView's geometry so undersized-content placement can be read
//  as numbers rather than guessed from a screenshot.
//
//  Usage: swift run BobnetLayoutHarness [bare|split] [windowHeight]
//

import AppKit
import BobnetFeature
import ComposableArchitecture
import GameDatabase
import GameModels
import SQLiteData
import SwiftUI
import UI

// MARK: - Seed

// Live shapes (read from the running app's SQLite): #general 615 msgs/avg 108
// chars, #trade 226/120, #claims 15/29 (max 34) -- one short line each.
let messageCounts = ["#general": 615, "#trade": 226, "#claims": 15]

func bodyText(_ i: Int) -> String {
    let unit = "Relay traffic nominal, cargo manifest reconciled against the forge queue. "
    let repeats = (i % 17 == 0) ? 8 : (i % 5 == 0) ? 2 : 1
    return String(String(repeating: unit, count: repeats).prefix(i % 17 == 0 ? 574 : 40 + (i % 120)))
}

/// Matches live #claims: 25-34 chars, single line, no wrapping.
func claimsBody(_ i: Int) -> String {
    String("Claim \(i) filed, awaiting review, ok".prefix(25 + (i % 10)))
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
                    message: channel == "#claims" ? claimsBody(i) : bodyText(i),
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

// MARK: - Geometry inspection

/// Every NSScrollView anywhere under `view` -- the `split` variant's sidebar and
/// channels columns are each backed by their own List/NSScrollView, so a
/// depth-first "return the first match" grabs the sidebar, not the detail pane.
func allScrollViews(_ view: NSView) -> [NSScrollView] {
    var results: [NSScrollView] = []
    if let scroll = view as? NSScrollView { results.append(scroll) }
    for subview in view.subviews { results.append(contentsOf: allScrollViews(subview)) }
    return results
}

/// The detail column's scroll view: the rightmost one in window coordinates.
/// NavigationSplitView lays its columns out left to right, so this correctly
/// picks the detail pane over the sidebar/channels columns regardless of variant.
func findScrollView(_ view: NSView) -> NSScrollView? {
    allScrollViews(view).max { a, b in
        a.convert(a.bounds, to: nil).minX < b.convert(b.bounds, to: nil).minX
    }
}

func report(_ label: String, _ window: NSWindow) {
    guard let root = window.contentView, let scroll = findScrollView(root) else {
        print("\(label): NO NSSCROLLVIEW FOUND")
        return
    }
    let visible = scroll.contentView.bounds
    let documentHeight = scroll.documentView?.frame.height ?? -1
    let insets = scroll.contentInsets
    // At true-bottom rest, NSClipView.bounds.maxY == documentHeight + insets.bottom,
    // so gapBelow == documentH - (originY + visibleH) == -insets.bottom. That IS the
    // resting-at-bottom signature (not +insets.bottom -- task-1-report.md corrects
    // the original reading guide, which had the sign backwards).
    let gapBelow = documentHeight - (visible.origin.y + visible.height)
    let atBottom = abs(gapBelow + insets.bottom) < 1
    // Undersized content: SwiftUI can absorb the slack into insets.top so the stack
    // still lands against the compose bar. Symptom 1 shows as fillsViewport falling
    // short of visibleH - insets.bottom.
    let fillsViewport = documentHeight + insets.top
    // The document's flipped y=0 (first row's top edge, inside its own .padding)
    // sits `-originY` down from the viewport's own top edge. There is no per-row
    // NSView to walk -- LazyVStack rows are drawn by SwiftUI, not backed by
    // AppKit views -- so this is read off the clip view's origin, not measured
    // independently. If content sits at the TOP with slack below, this is ~0 and
    // insets.top is ~0 too; if content is pushed down to sit at the bottom, both
    // are large and roughly equal.
    let firstRowOffset = -visible.origin.y
    print(String(
        format: "%@: originY=%8.1f visibleH=%7.1f documentH=%8.1f insets(t=%.0f,b=%.0f) " +
            "gapBelow=%8.1f atBottom=%@ fillsViewport=%8.1f firstRowOffset=%8.1f",
        label as NSString, visible.origin.y, visible.height,
        documentHeight, insets.top, insets.bottom, gapBelow,
        atBottom ? "Y" : "N", fillsViewport, firstRowOffset
    ))
}

// MARK: - Root

prepareDependencies {
    try! $0.bootstrapDatabase { db in try seed(db) }
}

let store = Store(initialState: BobnetFeature.State()) { BobnetFeature() }

struct Root: View {
    @Bindable var store: StoreOf<BobnetFeature>
    let variant: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if variant == "split" {
                // The shipping arrangement: sidebar + channels pane + detail.
                NavigationSplitView {
                    List { Label("Bobnet", systemImage: SidebarSymbol.bobnet) }
                        .navigationSplitViewColumnWidth(180)
                } content: {
                    BobnetChannelsView(store: store)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
                } detail: {
                    BobnetChannelDetailView(store: store)
                }
            } else {
                BobnetChannelDetailView(store: store)
            }
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Run

let variant = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "bare"
let windowHeight = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 800) : 800
// The live app's front window measures 1241x1054 (3-column NavigationSplitView:
// ~180 sidebar + ~300 channels + ~760 detail). `split` uses the real window width
// and lets NavigationSplitView distribute columns; `bare` fixes the detail
// column's own width so the two variants wrap comparably.
let windowWidth: CGFloat = variant == "split" ? 1241 : 760

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: Root(store: store, variant: variant, width: windowWidth, height: windowHeight)
        )
        window.makeKeyAndOrderFront(nil)

        let config = "[\(variant) h=\(Int(windowHeight))]"

        store.send(.binding(.set(\.selectedChannel, "#general")))
        spin(seconds: 3.0)
        report("\(config) long   (#general, 615)", window)

        store.send(.binding(.set(\.selectedChannel, "#claims")))
        spin(seconds: 3.0)
        report("\(config) short  (#claims,   15)", window)

        store.send(.binding(.set(\.selectedChannel, "#trade")))
        spin(seconds: 3.0)
        report("\(config) long2  (#trade,   226)", window)

        store.send(.binding(.set(\.selectedChannel, "#claims")))
        spin(seconds: 3.0)
        report("\(config) short2 (#claims,   15)", window)

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
