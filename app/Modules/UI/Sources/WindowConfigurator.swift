import SwiftUI

public struct WindowConfigurator: NSViewRepresentable {
    public init() {}
    
    public func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            if let window = view.window {
                window.backgroundColor = NSColor(Color.rcWindowBackground)
            }
        }

        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
