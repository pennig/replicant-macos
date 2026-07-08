import ComposableArchitecture
import MetalKit
import SwiftUI

// SwiftUI can't give us precise two-finger scroll / magnify deltas, so we drop
// to an MTKView subclass and handle the AppKit events directly. This is the
// trackpad-native input layer: bounded gestures only.
//   two-finger drag        → orbit
//   shift + two-finger drag → pan the pivot
//   pinch                   → logarithmic dolly
//   click                   → pick nearest star, focus the relevance field
//   esc                     → clear focus   ·   H → home
//
// Camera + overlay GPU state stay imperative inside `StarFieldRenderer`; this
// view only forwards the *result* of an interaction (which star got selected,
// which data filter is active) to the store as a `NewStarMapFeature.Action`, so
// the TCA reducer owns the declarative UI state the SwiftUI overlays read.

final class StarMTKView: MTKView {
    weak var renderer: StarFieldRenderer?
    /// Forwards user-facing outcomes into the store. Set by the representable.
    var send: ((NewStarMapFeature.Action) -> Void)?
    /// Whether we're focused into a system (orrery) — gates picking and Esc.
    var focused = false
    private var pendingClick: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }

    deinit { NotificationCenter.default.removeObserver(self) }

    // A tracking area so `mouseMoved` is actually delivered — hovering to line up
    // a click counts as activity, so the field holds still under the cursor.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    // — Sidebar-aware centring —
    // The map is full-bleed under the translucent split-view sidebar; shift the
    // projection so the pivot centres in the region the sidebar leaves clear. The
    // correction self-disables (0) when the view sits beside the sidebar instead.

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSSplitView.didResizeSubviewsNotification, object: nil)
        if window != nil {
            NotificationCenter.default.addObserver(
                self, selector: #selector(splitViewDidResize),
                name: NSSplitView.didResizeSubviewsNotification, object: nil)
        }
        updateLensShift()
    }

    override func layout() {
        super.layout()
        updateLensShift()
    }

    @objc private func splitViewDidResize() { updateLensShift() }

    private func updateLensShift() {
        guard bounds.width > 0 else { return }
        renderer?.camera.lensShiftX = Float(leadingObscuredWidth() / bounds.width)
    }

    /// How much of our leading edge the split view's sidebar covers, in our
    /// coordinates. Zero when we sit beside the sidebar (no overlap to correct).
    private func leadingObscuredWidth() -> CGFloat {
        guard let split = enclosingSplitView,
              let sidebar = split.arrangedSubviews.first,
              sidebar !== self, sidebar.window != nil,
              !sidebar.isHidden, sidebar.frame.width > 0 else { return 0 }
        let trailing = sidebar.convert(
            NSPoint(x: sidebar.bounds.maxX, y: sidebar.bounds.midY), to: self)
        return max(0, min(trailing.x, bounds.width))
    }

    private var enclosingSplitView: NSSplitView? {
        var view: NSView? = superview
        while let current = view {
            if let split = current as? NSSplitView { return split }
            view = current.superview
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        renderer?.registerInteraction()
    }

    override func mouseDragged(with event: NSEvent) {
        renderer?.registerInteraction()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let r = renderer else { return }
        r.registerInteraction()
        let dx = Float(event.scrollingDeltaX)
        let dy = Float(event.scrollingDeltaY)
        if event.modifierFlags.contains(.shift) {
            r.camera.pan(dx: dx, dy: dy)
        } else {
            r.camera.orbit(dAzimuth: dx * 0.005, dElevation: dy * 0.005)
        }
    }

    override func magnify(with event: NSEvent) {
        // Pinch out (magnification > 0) zooms in. Logarithmic via the camera.
        renderer?.registerInteraction()
        renderer?.camera.dolly(Float(event.magnification) * 2.0)
    }

    override func rotate(with event: NSEvent) {
        // Roll intentionally ignored — a turntable keeps a stable galactic up.
    }

    override func mouseDown(with event: NSEvent) {
        guard let r = renderer, !focused else { return }   // the orrery isn't interactive yet
        r.registerInteraction()
        let loc = convert(event.locationInWindow, from: nil)
        // AppKit origin is bottom-left; flip to match the renderer's top-left.
        let p = CGPoint(x: loc.x, y: bounds.height - loc.y)
        guard let idx = r.pickStar(atViewPoint: p, viewSize: bounds.size) else { return }

        if event.clickCount >= 2 {
            // Second click of a double: cancel the deferred single-click and dive.
            pendingClick?.cancel()
            pendingClick = nil
            send?(.starDived(r.dive(onStarAt: idx)))   // fixed close distance, always repositions
            return
        }

        // First click: defer the re-aim by the system double-click interval, so a
        // following second click can preempt it. Otherwise every double-click
        // fires a re-aim before the dive.
        let work = DispatchWorkItem { [weak self] in
            self?.send?(.starFocused(r.focus(onStarAt: idx)))   // eased re-aim
            self?.pendingClick = nil
        }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    override func keyDown(with event: NSEvent) {
        guard let r = renderer else { return }
        switch event.keyCode {
        case 53:                                     // esc → zoom out of a system, else clear focus
            if focused {
                send?(.zoomOutRequested)
            } else {
                r.clearFocus()
                send?(.selectionCleared)
            }
        case 4:                                       // H → eased pull-back to overview
            r.home()
            send?(.homeRequested)
        case 46: r.toggleMesh()                       // M → toggle the FTL mesh overlay
        case 3:  send?(.dataFilterCycled(r.cycleDataFilter()))   // F — cycle data filters
        case 5:  r.toggleSymbols()                    // G — toggle label status symbols
        default: super.keyDown(with: event)
        }
    }
}

/// The `MTKView` host, driven by the store and the live star terrain. Gestures/
/// keys forward actions in; the imperative renderer owns the camera and GPU
/// overlay state. HUD controls (auto-rotate, recenter) are pushed into the
/// renderer here; when the terrain changes (a survey adds systems) the renderer
/// is rebuilt on the new `[Star]`.
struct MetalStarView: NSViewRepresentable {
    let store: StoreOf<NewStarMapFeature>
    /// The live terrain, already mapped from the persisted `Star` table.
    let stars: [Star]
    /// Current scale (galaxy vs a drilled-in system).
    let focus: StarMapFocus
    /// The orrery to show when `focus` is `.system` — built by the view from the
    /// live row. Nil in galaxy mode.
    let systemModel: SystemModel?

    final class Coordinator {
        var renderer: StarFieldRenderer?
        /// The terrain the current renderer was built on, so we only rebuild when
        /// the survey data actually changes (not on every selection/redraw).
        var loadedStars: [Star] = []
        /// The last recenter token applied, so a bump fires exactly one recenter.
        var lastResetToken = 0
        /// The last focus applied, so a drill-in / zoom-out fires exactly once.
        var lastFocus: StarMapFocus = .galaxy
        /// The last orrery model applied, so a hydrate refresh rebuilds in place.
        var lastModel: SystemModel?

        /// (Re)builds the renderer for `stars` if they differ from what's loaded.
        func syncTerrain(_ stars: [Star], into view: StarMTKView) {
            guard stars != loadedStars else { return }
            loadedStars = stars
            let renderer = StarFieldRenderer(mtkView: view, stars: stars)
            self.renderer = renderer
            view.renderer = renderer
            view.delegate = renderer          // nil for an empty terrain → draws black
        }

        /// Pushes the declarative HUD controls into the imperative renderer.
        func applyControls(autoRotate: Bool, recenterToken: Int, transitionDurationScale: Double) {
            renderer?.autoRotate = autoRotate
            renderer?.transitionDurationScale = transitionDurationScale
            if recenterToken != lastResetToken {
                lastResetToken = recenterToken
                renderer?.recenterOnPlayer()
            }
        }

        /// Drives the galaxy↔system fly on a focus change (once per change), and
        /// refreshes the orrery in place when the focused system's model updates
        /// (e.g. the drill-in hydrate lands with the real planet roster).
        func applyFocus(_ focus: StarMapFocus, model: SystemModel?, stars: [Star], view: StarMTKView) {
            view.focused = { if case .system = focus { return true } else { return false } }()
            if focus == lastFocus {
                if case .system = focus, let model, model != lastModel {
                    lastModel = model
                    renderer?.updateOrrery(model: model)
                }
                return
            }
            lastFocus = focus
            lastModel = model
            switch focus {
            case let .system(id):
                guard let model, let index = stars.firstIndex(where: { $0.name == id }) else { return }
                renderer?.enterSystem(starIndex: index, model: model)
            case .galaxy:
                renderer?.exitSystem()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.lastResetToken = store.cameraResetToken   // don't recenter on first appear
        c.lastFocus = store.focus
        return c
    }

    func makeNSView(context: Context) -> StarMTKView {
        let view = StarMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120       // ProMotion-friendly
        view.isPaused = false                      // continuous for slice 1; see note
        view.enableSetNeedsDisplay = false
        view.send = { [store] action in store.send(action) }
        context.coordinator.syncTerrain(stars, into: view)
        context.coordinator.applyControls(autoRotate: store.autoRotate,
                                          recenterToken: store.cameraResetToken,
                                          transitionDurationScale: store.transitionDurationScale)
        context.coordinator.applyFocus(focus, model: systemModel, stars: stars, view: view)
        return view
    }

    func updateNSView(_ nsView: StarMTKView, context: Context) {
        context.coordinator.syncTerrain(stars, into: nsView)
        context.coordinator.applyControls(autoRotate: store.autoRotate,
                                          recenterToken: store.cameraResetToken,
                                          transitionDurationScale: store.transitionDurationScale)
        context.coordinator.applyFocus(focus, model: systemModel, stars: stars, view: nsView)
    }
}
