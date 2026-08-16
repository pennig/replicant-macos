import ComposableArchitecture
import MetalKit
import SwiftUI

/// A location's star, planet, moon, belt or region, drawn through the star map's own
/// shaders. Animates; ignores input.
public struct BodyPortraitView: View {
    private let subject: BodyPortrait
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = true

    @Shared(.appStorage(OrreryMapping.OrreryPlaneOptions.tiltCapKey))
    private var tiltCapDeg: Double = 90
    @Shared(.appStorage(OrreryMapping.OrreryPlaneOptions.decoupleKey))
    private var decoupleMoonPlane: Bool = false

    public init(_ subject: BodyPortrait) {
        self.subject = subject
    }

    public var body: some View {
        MetalBodyPortrait(
            subject: subject,
            options: .init(tiltCapDeg: tiltCapDeg, decoupleMoonPlane: decoupleMoonPlane),
            paused: !visible || scenePhase != .active
        )
        .background(.black)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

private struct MetalBodyPortrait: NSViewRepresentable {
    let subject: BodyPortrait
    let options: OrreryMapping.OrreryPlaneOptions
    let paused: Bool

    func makeCoordinator() -> BodyPortraitRenderer { BodyPortraitRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        context.coordinator.subject = subject
        context.coordinator.options = options
        context.coordinator.configure(view: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.subject = subject
        context.coordinator.options = options
        view.isPaused = paused
    }
}
