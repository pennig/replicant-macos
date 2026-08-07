//
//  main.swift — throwaway measurement harness for the Bobnet channel switch.
//
//  Renders the real detail pane (or a variant of it) in a real NSWindow, settles,
//  then performs ONE channel switch and reports the main-thread CPU time burned
//  in a fixed window afterwards. Variant chosen by argv[1].
//

import AppKit
import BobnetFeature
import ComposableArchitecture
import GameDatabase
import GameModels
import SQLiteData
import SwiftUI
import UI

// MARK: - Timing

func threadCPUSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let u = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    let s = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return u + s
}

// MARK: - Seed

let generalCount = ProcessInfo.processInfo.environment["RC_MSGS"].flatMap(Int.init) ?? 611
let messageCounts = ["#general": generalCount, "#trade": 225, "#claims": 15]

/// Realistic message bodies: mean ~108 chars, max ~574 (matches the live table).
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
    // Live markers sit near the end of each channel (#general is 175 behind),
    // which is what makes `firstUnreadID` clear its `> 0` guard and actually scan.
    for (channel, _) in messageCounts {
        let maxID = rows.filter { $0.channel == channel }.map(\.id).max() ?? 0
        try BobnetChannel.upsert {
            BobnetChannel(
                name: channel,
                lastActive: Date(timeIntervalSinceNow: -60),
                lastReadMessageID: max(0, maxID - 175)
            )
        }.execute(db)
    }
}

// MARK: - Variant flags

struct Flags {
    var hoistUnread = false      // compute firstUnreadID once, not per row
    var textSelection = true     // .textSelection(.enabled) on the body Text
    var bottomAnchor = true      // .defaultScrollAnchor(.bottom)
    var relativeDate = true      // Text(date, format: .relative) vs a static string
}

// MARK: - Replica of BobnetChannelDetailView's message list

nonisolated(unsafe) var rowBodyEvaluations = 0
nonisolated(unsafe) var unreadScans = 0

struct ReplicaRow: View {
    let message: BobnetMessage
    let flags: Flags

    var body: some View {
        let _ = { rowBodyEvaluations += 1 }()
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(message.replicantName)
                    .font(.rcBodyEmph)
                    .foregroundStyle(.rcTextPrimary)
                if let star = message.currentStar {
                    Text(star)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                }
                Spacer(minLength: Space.s)
                Group {
                    if flags.relativeDate {
                        Text(message.time, format: .relative(presentation: .named))
                    } else {
                        Text("2h ago")
                    }
                }
                .font(.rcMonoSmall)
                .foregroundStyle(.rcTextTertiary)
                .fixedSize()
            }
            Text(message.message)
                .font(.rcBody)
                .foregroundStyle(.rcTextSecondary)
                .modifier(Selectable(enabled: flags.textSelection))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ReplicaDetail: View {
    @Bindable var store: StoreOf<BobnetFeature>
    let flags: Flags

    private var firstUnreadID: Int? {
        unreadScans += 1
        guard store.markerAtSelection > 0 else { return nil }
        return store.channelMessages.messages
            .first { $0.id > store.markerAtSelection }?.id
    }

    var body: some View {
        if let channel = store.selectedChannel {
            list(channel)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func list(_ channel: String) -> some View {
        // Hoisted: one scan for the whole list instead of one scan per row.
        let hoisted = flags.hoistUnread ? firstUnreadID : nil
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s) {
                ForEach(store.channelMessages.messages) { message in
                    if message.id == (flags.hoistUnread ? hoisted : firstUnreadID) {
                        Divider().overlay(.rcAccent)
                    }
                    ReplicaRow(message: message, flags: flags)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(channel)
        .modifier(BottomAnchor(enabled: flags.bottomAnchor))
        .background(.rcContentBackground)
    }
}

struct Selectable: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}

struct BottomAnchor: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.defaultScrollAnchor(.bottom) } else { content }
    }
}

// MARK: - Root

struct Root: View {
    let store: StoreOf<BobnetFeature>
    let variant: String

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
            } else if variant == "real" {
                BobnetChannelDetailView(store: store)
            } else {
                ReplicaDetail(store: store, flags: flagsFor(variant))
            }
        }
        .frame(width: 1200, height: 800)
    }
}

func flagsFor(_ variant: String) -> Flags {
    var flags = Flags()
    switch variant {
    case "copy": break
    case "hoisted": flags.hoistUnread = true
    case "nosel": flags.textSelection = false
    case "noanchor": flags.bottomAnchor = false
    case "nodate": flags.relativeDate = false
    case "all":
        flags.hoistUnread = true
        flags.textSelection = false
        flags.bottomAnchor = false
        flags.relativeDate = false
    default: break
    }
    return flags
}

// MARK: - Pure-logic microbench (no SwiftUI)

func microbenchUnreadScan(_ messages: [BobnetMessage], marker: Int) {
    // Exactly what the view does: one `first { }` scan per rendered row.
    var t0 = threadCPUSeconds()
    var sink = 0
    for _ in messages {
        if let id = messages.first(where: { $0.id > marker })?.id { sink &+= id }
    }
    let perRow = threadCPUSeconds() - t0
    t0 = threadCPUSeconds()
    let once = messages.first(where: { $0.id > marker })?.id
    for _ in messages { if let once { sink &+= once } }
    let hoistedCost = threadCPUSeconds() - t0
    print(String(format: "microbench rows=%d perRowScan=%.1fms hoisted=%.3fms sink=%d",
                 messages.count, perRow * 1000, hoistedCost * 1000, sink))
}

// MARK: - Run

let variant = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "real"

prepareDependencies {
    try! $0.bootstrapDatabase { db in try seed(db) }
}

if variant == "micro" {
    @Dependency(\.defaultDatabase) var database
    let rows = try database.read { db in
        try BobnetMessage.where { $0.channel.eq("#general") }.order { ($0.time, $0.id) }.fetchAll(db)
    }
    microbenchUnreadScan(rows, marker: rows[rows.count / 2].id)
    exit(0)
}

if variant == "query" {
    @Dependency(\.defaultDatabase) var database
    for _ in 0..<3 {
        let t0 = threadCPUSeconds()
        let rows = try database.read { db in
            try BobnetMessage.where { $0.channel.eq("#general") }
                .order { ($0.time, $0.id) }.fetchAll(db)
        }
        let detail = threadCPUSeconds() - t0
        let t1 = threadCPUSeconds()
        let list = try database.read { db in try BobnetChannelList().fetch(db) }
        let listCost = threadCPUSeconds() - t1
        print(String(format: "query detailFetch=%.1fms (%d rows)  channelList=%.1fms (%d rows)",
                     detail * 1000, rows.count, listCost * 1000, list.rows.count))
    }
    exit(0)
}

let store = Store(initialState: BobnetFeature.State()) { BobnetFeature() }

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
        window.contentView = NSHostingView(rootView: Root(store: store, variant: variant))
        window.makeKeyAndOrderFront(nil)

        // Settle on #claims (15 messages) so the window, fonts, and SwiftUI
        // machinery are all warm before the measured switch.
        store.send(.binding(.set(\.selectedChannel, "#claims")))
        spin(seconds: 2.0)

        let cpu0 = processCPUSeconds()
        let wall0 = Date()
        store.send(.binding(.set(\.selectedChannel, "#general")))
        // Wall time until the process goes quiet: three consecutive 50ms slices
        // burning under 2ms of CPU each. That is what the user waits through.
        var quietSlices = 0
        var settled: TimeInterval = 0
        while Date().timeIntervalSince(wall0) < 30 {
            let before = processCPUSeconds()
            spin(seconds: 0.05)
            let burned = processCPUSeconds() - before
            quietSlices = burned < 0.002 ? quietSlices + 1 : 0
            if quietSlices >= 3 {
                settled = Date().timeIntervalSince(wall0) - 0.15
                break
            }
        }
        let cpu = processCPUSeconds() - cpu0
        let wall = settled

        // A second window measures the steady-state (post-render) burn.
        let cpu1 = processCPUSeconds()
        spin(seconds: 3.0)
        let idle = processCPUSeconds() - cpu1

        print(String(format: "variant=%-9@ settledAfter=%6.0fms  switchCPU=%6.0fms  idleCPU/3s=%5.0fms  rowBodies=%5d  unreadScans=%6d",
                     variant as NSString, wall * 1000, cpu * 1000, idle * 1000,
                     rowBodyEvaluations, unreadScans))
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
