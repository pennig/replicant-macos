//
//  PrintQueueListView.swift
//  Replicould — Print Queue feature
//
//  The master list for the split view's content column: every device that can
//  print and is currently printing or holding queued jobs. Rows render straight
//  from the `Device` table via `@FetchAll` (filtered to `isPrintingOrQueued`), so
//  a stream update or a dispatched command flows in automatically; the store
//  drives selection and the cold-load / refresh.
//

import ComposableArchitecture
import GameModels
import GameServices
import SwiftUI
import UI

public struct PrintQueueListView: View {
    @Bindable var store: StoreOf<PrintQueueFeature>

    public init(store: StoreOf<PrintQueueFeature>) {
        self.store = store
    }

    public var body: some View {
        SelectableList(
            store.printers,
            id: \.deviceCode,
            selection: $store.selectedDeviceCode,
            style: .inline
        ) { device, isSelected in
            PrintQueueRow(device: device).rcSidebarRow(isSelected: isSelected)
        }
        .background(.rcContentBackground)
        .overlay {
            if store.printers.isEmpty {
                if store.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "Nothing Printing",
                        systemImage: "printer",
                        description: Text("Printers with an active job or a queue will appear here.")
                    )
                }
            }
        }
        .navigationTitle("Print Queue")
        .navigationSubtitle(store.printers.isEmpty ? Text("") : Text("^[\(store.printers.count) printer](inflect: true)").monospacedDigit())
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = store.errorMessage {
                RCErrorBanner(errorMessage) { store.send(.dismissError) }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.send(.refreshButtonTapped)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh fleet")
                .disabled(store.isLoading)
            }
        }
        .task { store.send(.task) }
    }

}

// MARK: - Row

private struct PrintQueueRow: View {
    let device: Device

    private var printing: PrintingSnapshot? { device.printingSnapshot }

    var body: some View {
        HStack(spacing: Space.s) {
            RCGlyphTile(Image.rcSymbol("device.\(device.deviceType)"))
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(PrintQueuePresentation.displayName(device.deviceType))
                        .font(.rcBodyEmph)
                        .foregroundStyle(.rcTextPrimary)
                        .lineLimit(1)
                    Text(device.deviceCode)
                        .font(.rcMonoSmall)
                        .foregroundStyle(.rcTextTertiary)
                    Spacer(minLength: Space.xs)
                    if device.queuedJobCount > 0 {
                        queueBadge(device.queuedJobCount)
                    }
                }

                if let printing, let target = printing.deviceType {
                    // Active job — what's on the platen, plus a compact server-value
                    // progress bar (the live interpolated bar lives in the detail).
                    HStack(spacing: Space.s) {
                        Image(systemName: "printer.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.rcAccent)
                        Text(PrintQueuePresentation.displayName(target))
                            .font(.rcMonoSmall)
                            .foregroundStyle(.rcTextSecondary)
                            .lineLimit(1)
                        Spacer(minLength: Space.xs)
                    }
                    if let pct = printing.progressPercent {
                        ProgressView(value: min(max(pct / 100, 0), 1))
                            .tint(.rcAccent)
                            .controlSize(.small)
                    }
                } else {
                    // No active job, but queued — waiting to start.
                    StatusBadge(device.statusBase)
                }
            }
        }
        .padding(.vertical, Space.xs)
    }

    private func queueBadge(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.rcMonoSmall)
            .foregroundStyle(.rcAccent)
            .rcPill(.accent)
            .help(count == 1 ? "1 job queued" : "\(count) jobs queued")
    }

}
