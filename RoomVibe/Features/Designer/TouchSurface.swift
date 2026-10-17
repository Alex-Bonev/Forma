import SwiftUI
import UIKit

/// Transparent layer over the RealityView that owns all Designer touches with UIKit recognizers.
/// SwiftUI gestures attached to RealityView competed with RealityKit's own touch handling (objects
/// couldn't be dragged on device); UIKit also gives release velocity and clean 1 <-> 2 finger handoffs.
struct TouchSurface: UIViewRepresentable {
    enum Phase { case began, changed, ended }

    struct Handlers {
        var touchDown: () -> Void = {}
        /// One finger: location, movement since last call, release velocity (on `.ended`).
        var oneFinger: (Phase, CGPoint, _ delta: CGSize, _ velocity: CGPoint) -> Void = { _, _, _, _ in }
        var twoFingerPan: (CGSize) -> Void = { _ in }
        var pinch: (Phase, CGFloat) -> Void = { _, _ in }
        var twist: (Phase, CGFloat) -> Void = { _, _ in }
        var tap: (CGPoint) -> Void = { _ in }
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
        view.onTouchDown = { context.coordinator.handlers.touchDown() }
        let c = context.coordinator
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let twist = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.twist(_:)))
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        for r in [pan, pinch, twist, tap] as [UIGestureRecognizer] {
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

        init(handlers: Handlers) { self.handlers = handlers }

        @objc func pan(_ r: UIPanGestureRecognizer) {
            let view = r.view!
            let n = r.numberOfTouches
            switch r.state {
            case .began:
                touches = n
                // Pan only begins after ~10 pt of movement: hit-test where the finger first landed instead.
                let start = (view as? TouchView)?.downLocation ?? r.location(in: view)
                if n == 1 { handlers.oneFinger(.began, start, .zero, .zero) }
            case .changed:
                // Finger count changed mid-gesture: the centroid jumps, so restart the delta from here.
                if n != touches {
                    if touches == 1 { handlers.oneFinger(.ended, r.location(in: view), .zero, .zero) }
                    touches = n
                    r.setTranslation(.zero, in: view)
                    return
                }
                let t = r.translation(in: view)
                r.setTranslation(.zero, in: view)
                let delta = CGSize(width: t.x, height: t.y)
                if n == 1 { handlers.oneFinger(.changed, r.location(in: view), delta, .zero) }
                else { handlers.twoFingerPan(delta) }
            case .ended, .cancelled, .failed:
                if touches == 1 { handlers.oneFinger(.ended, r.location(in: view), .zero, r.velocity(in: view)) }
                touches = 0
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

        @objc func tap(_ r: UITapGestureRecognizer) { handlers.tap(r.location(in: r.view)) }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(g is UITapGestureRecognizer || other is UITapGestureRecognizer)
        }
    }

    /// Reports the first finger down instantly (stops momentum on touch, before any recognizer fires).
    private final class TouchView: UIView {
        var onTouchDown: () -> Void = {}
        private(set) var downLocation: CGPoint?
        /// iOS 26 swipe-back works from anywhere in the content, which turned every rightward orbit into
        /// "go back". Disable it while the Designer is on screen; the edge swipe and Back button still work.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard #available(iOS 26, *) else { return }
            var r: UIResponder? = self
            while let next = r?.next, !(next is UINavigationController) { r = next }
            (r?.next as? UINavigationController)?.interactiveContentPopGestureRecognizer?.isEnabled = window == nil
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if event?.allTouches?.count == touches.count { downLocation = touches.first?.location(in: self) }
            onTouchDown()
            super.touchesBegan(touches, with: event)
        }
    }
}
