import ComposableArchitecture
import CStarMapShaderTypes
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
        // fires a re-aim before the dive. Resolve the renderer AT FIRE TIME (not the
        // one captured now): a terrain rebuild during the delay would orphan the
        // captured renderer, so the re-aim would run on a view that no longer draws
        // (dossier appears, camera never moves).
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.renderer else { return }
            self.send?(.starFocused(current.focus(onStarAt: idx)))   // eased re-aim
            self.pendingClick = nil
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
    /// Live overlays (FTL mesh links + ships) the renderer draws over the terrain.
    let overlays: StarMapOverlays
    /// Current scale (galaxy vs a drilled-in system).
    let focus: StarMapFocus
    /// The orrery to show when `focus` is `.system` — built by the view from the
    /// live row. Nil in galaxy mode.
    let systemModel: SystemModel?
    /// The bridge the renderer pushes ship screen positions to each frame, read by
    /// the sibling `ShipOverlayLayer` to float tappable device icons over the pips.
    let shipProjection: ShipProjectionModel

    final class Coordinator {
        var renderer: StarFieldRenderer?
        /// The terrain the current renderer was built on, so we only rebuild when
        /// the survey data actually changes (not on every selection/redraw).
        var loadedStars: [Star] = []
        /// The overlays the current renderer was built on, so a change to the FTL
        /// mesh or the ships in transit rebuilds it (ship *motion* animates in the
        /// renderer from the timestamps, so this only changes on trip start/end).
        var loadedOverlays: StarMapOverlays = .empty
        /// The last recenter token applied, so a bump fires exactly one recenter.
        var lastResetToken = 0
        /// The last search-focus token applied, so a bump fires exactly one re-aim.
        var lastStarFocusToken = 0
        /// The last focus applied, so a drill-in / zoom-out fires exactly once.
        var lastFocus: StarMapFocus = .galaxy
        /// The last orrery model applied, so a hydrate refresh rebuilds in place.
        var lastModel: SystemModel?

        /// Reconciles the renderer with the live terrain + overlays. The renderer is
        /// built EXACTLY ONCE (the first time a non-empty terrain arrives); every
        /// later change — a survey streaming stars in, a moved replicant flipping the
        /// current-location flag, the async FTL links landing, a trip starting or
        /// ending — is applied IN PLACE. Tearing the renderer down per change is what
        /// left the viewport black through the initial survey and made the camera
        /// feel dead on first load (each rebuild cancelled the in-flight camera fly).
        @MainActor func syncTerrain(_ stars: [Star], overlays: StarMapOverlays,
                                    projection: ShipProjectionModel, into view: StarMTKView) {
            if renderer == nil {
                // Empty terrain → nothing to draw yet (stays black until stars arrive).
                guard let renderer = StarFieldRenderer(
                    mtkView: view, stars: stars, overlays: overlays, viewpoint: .shared)
                else { return }
                loadedStars = stars
                loadedOverlays = overlays
                self.renderer = renderer
                view.renderer = renderer
                view.delegate = renderer
                // Push each frame's ship screen points to the overlay model. The
                // renderer draws on the main thread, so the main-actor hop is safe;
                // the `!=` guard keeps an idle fleet (or empty set) from churning
                // SwiftUI. The same renderer object persists across in-place terrain/
                // overlay updates, so this is wired exactly once.
                renderer.onShipsProjected = { [weak projection] ships in
                    MainActor.assumeIsolated {
                        guard let projection, projection.ships != ships else { return }
                        projection.ships = ships
                    }
                }
            } else if stars != loadedStars {
                loadedStars = stars
                loadedOverlays = overlays
                renderer?.updateTerrain(stars, overlays: overlays)
            } else if overlays != loadedOverlays {
                loadedOverlays = overlays
                renderer?.updateOverlays(overlays)
            }
        }

        /// Pushes the declarative HUD controls into the imperative renderer.
        func applyControls(autoRotate: Bool, recenterToken: Int) {
            renderer?.autoRotate = autoRotate
            if recenterToken != lastResetToken {
                lastResetToken = recenterToken
                renderer?.recenterOnPlayer()
            }
        }

        /// Flies the camera to the searched star when the search token bumps —
        /// diving to a close framing (same as a double-click), not just re-aiming.
        /// Resolves the star by designation in the current terrain; a no-op if it
        /// isn't charted (e.g. terrain not yet rebuilt).
        func applyStarFocus(token: Int, designation: String?, stars: [Star]) {
            guard token != lastStarFocusToken else { return }
            lastStarFocusToken = token
            guard let designation,
                  let idx = stars.firstIndex(where: { $0.name == designation })
            else { return }
            renderer?.dive(onStarAt: idx)
        }

        /// Drives the galaxy → system → body fly on a focus change (once per change,
        /// stepping one level), and refreshes the orrery in place when the focused
        /// model updates (e.g. a drill-in hydrate lands with the real roster). The
        /// `model` is whatever the current level renders: the system's `SystemModel`
        /// at `.system`, or the drilled planet's body model at `.body`.
        @MainActor func applyFocus(_ focus: StarMapFocus, model: SystemModel?, stars: [Star], view: StarMTKView) {
            view.focused = { if case .galaxy = focus { return false } else { return true } }()
            if focus == lastFocus {
                if case .galaxy = focus {} else if let model, model != lastModel {
                    lastModel = model
                    renderer?.updateOrrery(model: model)
                }
                return
            }
            let previous = lastFocus
            lastFocus = focus
            lastModel = model

            func index(_ id: String) -> Int? { stars.firstIndex(where: { $0.name == id }) }

            switch (previous, focus) {
            case let (.galaxy, .system(id)):
                if let model, let idx = index(id) { renderer?.enterSystem(starIndex: idx, model: model) }
            case let (.system, .body(bodyID)):
                if let model, let sys = focus.systemDesignation, let idx = index(sys) {
                    renderer?.enterBody(starIndex: idx, planetID: bodyID, model: model)
                }
            case let (.body, .system(id)):
                if let model, let idx = index(id) { renderer?.exitToSystem(starIndex: idx, model: model) }
            case (.system, .galaxy):
                renderer?.exitSystem()
            default:
                // Any non-adjacent jump: land at the target level directly.
                switch focus {
                case .galaxy:
                    renderer?.exitSystem()
                case let .system(id):
                    if let model, let idx = index(id) { renderer?.enterSystem(starIndex: idx, model: model) }
                case let .body(bodyID):
                    if let model, let sys = focus.systemDesignation, let idx = index(sys) {
                        renderer?.enterBody(starIndex: idx, planetID: bodyID, model: model)
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.lastResetToken = store.cameraResetToken   // don't recenter on first appear
        c.lastStarFocusToken = store.starFocusToken // don't re-aim on first appear
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
        context.coordinator.syncTerrain(stars, overlays: overlays, projection: shipProjection, into: view)
        context.coordinator.applyControls(autoRotate: store.autoRotate,
                                          recenterToken: store.cameraResetToken)
        context.coordinator.applyStarFocus(token: store.starFocusToken,
                                           designation: store.selectedStar?.name, stars: stars)
        context.coordinator.applyFocus(focus, model: systemModel, stars: stars, view: view)
        return view
    }

    func updateNSView(_ nsView: StarMTKView, context: Context) {
        context.coordinator.syncTerrain(stars, overlays: overlays, projection: shipProjection, into: nsView)
        context.coordinator.applyControls(autoRotate: store.autoRotate,
                                          recenterToken: store.cameraResetToken)
        context.coordinator.applyStarFocus(token: store.starFocusToken,
                                           designation: store.selectedStar?.name, stars: stars)
        context.coordinator.applyFocus(focus, model: systemModel, stars: stars, view: nsView)
    }
}
