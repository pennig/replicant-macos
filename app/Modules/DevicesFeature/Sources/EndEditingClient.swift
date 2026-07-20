//
//  EndEditingClient.swift
//  Replicould — Devices feature
//
//  A dependency that ends the key window's text-editing session, dismissing the
//  field editor and any text-completion popover it's showing. Wrapped so the
//  reducer can trigger it deterministically — and tests/previews can substitute a
//  no-op or a spy — instead of reaching for the `NSApp` global from a view.
//
//  Needed because presenting a sheet while a text field's completion popover
//  (AppKit's `SPCompletionListService`) is still on screen trips an assertion in
//  `-[NSWindow _beginWindowBlockingModalSessionForSheet:]` and the sheet fails
//  to present. Ending editing first tears that popover down.
//

import ComposableArchitecture
#if canImport(AppKit)
import AppKit
#endif

/// Ends the current window's field editing. Resolve via `\.endEditing`.
public struct EndEditingClient: Sendable {
    public var end: @Sendable () async -> Void

    public init(end: @escaping @Sendable () async -> Void) {
        self.end = end
    }

    public func callAsFunction() async {
        await end()
    }
}

extension EndEditingClient: DependencyKey {
    public static var liveValue: EndEditingClient {
        EndEditingClient {
            await MainActor.run {
                #if canImport(AppKit)
                _ = NSApp.keyWindow?.makeFirstResponder(nil)
                #endif
            }
        }
    }

    /// No-op by default under tests and previews; override with a spy to assert it
    /// was invoked.
    public static var testValue: EndEditingClient { EndEditingClient {} }
    public static var previewValue: EndEditingClient { EndEditingClient {} }
}

extension DependencyValues {
    public var endEditing: EndEditingClient {
        get { self[EndEditingClient.self] }
        set { self[EndEditingClient.self] = newValue }
    }
}
