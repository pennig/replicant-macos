//
//  FindableTextView.swift
//  Replicant — read-only monospaced text with the native macOS find bar.
//
//  SwiftUI's `Text` can't host the system find UX (match highlighting,
//  next/previous, result count), and a read-only `TextEditor` would force line
//  wrapping. For long readouts like raw API responses we want both ⌘F *and*
//  non-wrapping horizontal scroll, so we wrap NSTextView directly.
//

import AppKit
import SwiftUI

/// A read-only, horizontally-scrolling monospaced text view backed by
/// `NSTextView`, wired to the native macOS find bar (⌘F / ⌘G / ⇧⌘G).
///
/// Long lines extend and scroll horizontally rather than wrapping, so structured
/// payloads keep their shape. Text is selectable and copyable but not editable.
public struct FindableTextView: NSViewRepresentable {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        // TextKit 1 stack with an unbounded container so lines never wrap.
        let textContainer = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = FindBarTextView(
            frame: NSRect(origin: .zero, size: scrollView.contentSize),
            textContainer: textContainer
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: Space.s, height: Space.s)

        // Non-wrapping: let the view grow to fit its widest line and scroll.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = []

        apply(text, to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FindBarTextView,
              textView.string != text else { return }
        apply(text, to: textView)
    }

    private func apply(_ text: String, to textView: NSTextView) {
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor(Color.rcTextPrimary)
    }
}

/// `NSTextView` that routes the standard find shortcuts to the find bar even
/// when the app supplies no Edit ▸ Find menu, so ⌘F works wherever this view is
/// visible. `performKeyEquivalent(with:)` is offered to the whole view tree
/// before regular key handling, so the view need not be first responder.
private final class FindBarTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased()

        if flags == .command {
            switch chars {
            case "f": return runFindAction(.showFindInterface)
            case "g": return runFindAction(.nextMatch)
            case "e": return runFindAction(.setSearchString)
            default:  break
            }
        } else if flags == [.command, .shift], chars == "g" {
            return runFindAction(.previousMatch)
        }

        return super.performKeyEquivalent(with: event)
    }

    /// `performTextFinderAction(_:)` reads the action from the sender's `tag`.
    private func runFindAction(_ action: NSTextFinder.Action) -> Bool {
        guard usesFindBar else { return false }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
        return true
    }
}
