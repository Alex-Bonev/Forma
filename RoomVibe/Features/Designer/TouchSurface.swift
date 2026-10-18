import SwiftUI
import UIKit

/// Transparent layer over the RealityView that owns all Designer touches with UIKit recognizers.
/// SwiftUI gestures attached to RealityView competed with RealityKit's own touch handling (objects
/// couldn't be dragged on device); UIKit also gives release velocity and clean 1 <-> 2 finger handoffs.
struct TouchSurface: UIViewRepresentable {
    enum Phase { case began, changed, ended }

    struct Handlers {
        var touchDown: () -> Void = {}
        var touchUp: () -> Void = {}
        /// One finger: location, movement since last call, release velocity (on `.ended`).
        var oneFinger: (Phase, CGPoint, _ delta: CGSize, _ velocity: CGPoint) -> Void = { _, _, _, _ in }
        var twoFingerPan: (CGSize) -> Void = { _ in }
        var pinch: (Phase, CGFloat) -> Void = { _, _ in }
        var twist: (Phase, CGFloat) -> Void = { _, _ in }
        var tap: (CGPoint) -> Void = { _ in }
        /// Held still for 0.4 s. The tap that ends the same touch is not reported.
        var longPress: (CGPoint) -> Void = { _ in }
    }

    var handlers: Handlers
    var accessibilityValue: String?

    func makeUIView(context: Context) -> UIView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "designer-canvas"
        view.accessibilityLabel = "Room 3D view"
        view.onTouchDown = { context.coordinator.held = false; context.coordinator.handlers.touchDown() }
        view.onTouchUp = { context.coordinator.handlers.touchUp() }
        let c = context.coordinator
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let twist = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.twist(_:)))
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.4
        for r in [pan, pinch, twist, tap, hold] as [UIGestureRecognizer] {
            r.delegate = c
            view.addGestureRecognizer(r)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.handlers = handlers
        uiView.accessibilityValue = accessibilityValue
    }

    func makeCoordinator() -> Coordinator { Coordinator(handlers: handlers) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var handlers: Handlers
        private var touches = 0
        /// A long press fired during the current touch: its lift is not also a tap.
        var held = false
        private var wasMultiTouch = false   // after two fingers, a lifted finger shouldn't start orbiting

        init(handlers: Handlers) { self.handlers = handlers }

        @objc func pan(_ r: UIPanGestureRecognizer) {
            let view = r.view!
            let n = r.numberOfTouches
            switch r.state {
            case .began:
                touches = n
                wasMultiTouch = n > 1
                // Pan only begins after ~10 pt of movement: hit-test where the finger first landed instead.
                let start = (view as? TouchView)?.downLocation ?? r.location(in: view)
                if n == 1 { handlers.oneFinger(.began, start, .zero, .zero) }
            case .changed:
                // Finger count changed mid-gesture: the centroid jumps, so restart the delta from here.
                if n != touches {
                    if touches == 1 { handlers.oneFinger(.ended, r.location(in: view), .zero, .zero) }
                    touches = n
                    wasMultiTouch = wasMultiTouch || n > 1
                    r.setTranslation(.zero, in: view)
                    return
                }
                let t = r.translation(in: view)
                r.setTranslation(.zero, in: view)
                let delta = CGSize(width: t.x, height: t.y)
                if n > 1 { handlers.twoFingerPan(delta) }
                else if !wasMultiTouch { handlers.oneFinger(.changed, r.location(in: view), delta, .zero) }
            case .ended, .cancelled, .failed:
                if touches == 1 && !wasMultiTouch { handlers.oneFinger(.ended, r.location(in: view), .zero, r.velocity(in: view)) }
                touches = 0
                wasMultiTouch = false
            default: break
            }
        }

        @objc func pinch(_ r: UIPinchGestureRecognizer) {
            switch r.state {
            case .began: handlers.pinch(.began, r.scale)
            case .changed: handlers.pinch(.changed, r.scale)
            case .ended, .cancelled, .failed: handlers.pinch(.ended, r.scale)
            default: break
            }
        }

        @objc func twist(_ r: UIRotationGestureRecognizer) {
            switch r.state {
            case .began, .changed:
                handlers.twist(r.state == .began ? .began : .changed, r.rotation)
                r.rotation = 0   // report deltas
            case .ended, .cancelled, .failed: handlers.twist(.ended, 0)
            default: break
            }
        }

        @objc func tap(_ r: UITapGestureRecognizer) { if !held { handlers.tap(r.location(in: r.view)) } }

        @objc func hold(_ r: UILongPressGestureRecognizer) {
            guard r.state == .began else { return }
            held = true
            handlers.longPress(r.location(in: r.view))
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(g is UITapGestureRecognizer || other is UITapGestureRecognizer)
        }

        /// iOS 26 swipe-back works from anywhere in the content and turned rightward orbits into "go back".
        /// Make it wait for our pan to fail (it never does on a drag); the edge swipe and Back button still work.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard #available(iOS 26, *), g is UIPanGestureRecognizer else { return false }
            var r: UIResponder? = g.view
            while let cur = r, !(cur is UINavigationController) { r = cur.next }
            return other === (r as? UINavigationController)?.interactiveContentPopGestureRecognizer
        }
    }

    /// Reports the first finger down instantly (stops momentum on touch, before any recognizer fires).
    private final class TouchView: UIView {
        var onTouchDown: () -> Void = {}
        var onTouchUp: () -> Void = {}
        private(set) var downLocation: CGPoint?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            // First finger on this view (fingers resting elsewhere, e.g. on the panel, don't count).
            if event?.touches(for: self)?.count == touches.count { downLocation = touches.first?.location(in: self) }
            onTouchDown()
            super.touchesBegan(touches, with: event)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            liftIfDone(touches, event)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            liftIfDone(touches, event)
        }
        private func liftIfDone(_ touches: Set<UITouch>, _ event: UIEvent?) {
            let remaining = (event?.touches(for: self) ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
            if remaining.isEmpty { onTouchUp() }
        }
    }
}
