import RealityKit
import UIKit

/// Dollhouse camera: orbits a target point on the floor, pans that target, zooms.
/// Gestures move `goal`; every frame the camera eases toward it (smooth, and interruptible at any instant)
/// and a flick keeps orbiting with decaying momentum. Plain class on purpose: per-frame state must not
/// invalidate SwiftUI.
@MainActor
final class OrbitCamera {
    struct Pose {
        var azimuth: Float = 0.6      // radians around Y
        var elevation: Float = 0.8    // radians above the floor
        var distance: Float = 8       // meters from target
        var target: SIMD3<Float> = .zero
    }

    let entity = PerspectiveCamera()
    private(set) var goal = Pose()
    private var current = Pose()
    private var spin: SIMD2<Float> = .zero      // orbit momentum, rad/s (azimuth, elevation)
    private var roomSize: SIMD2<Float> = [5, 4]
    private var zoomStart: Float = 8
    var updates: EventSubscription?
    /// Called every frame with the camera's world position (wall cutaway).
    var onFrame: ((SIMD3<Float>) -> Void)?

    static let elevationRange: ClosedRange<Float> = 0.15...1.52   // just under straight-down (look-at singularity)
    private static let orbitSpeed: Float = 0.007                   // radians per point dragged

    var zoomRange: ClosedRange<Float> {
        let s = max(roomSize.x, roomSize.y, 2)
        return 1.2...(s * 3 + 3)
    }

    /// Framed 3/4 view of the whole room.
    var home: Pose { Pose(distance: max(roomSize.x, roomSize.y, 2) * 1.5 + 2) }

    func configure(roomSize: SIMD2<Float>) {
        self.roomSize = roomSize
        goal = home
        current = goal
        apply()
    }

    // MARK: Gesture input (screen points)

    /// Finger down: stop dead where the camera is now (grab-to-stop), and track 1:1 until release.
    func grab() {
        spin = .zero
        goal.azimuth = current.azimuth
        goal.elevation = current.elevation
        tracking = true
    }

    func release() { tracking = false }

    private var tracking = false

    func orbit(by delta: CGSize) {
        goal.azimuth -= Float(delta.width) * Self.orbitSpeed
        goal.elevation = (goal.elevation + Float(delta.height) * Self.orbitSpeed).clamped(to: Self.elevationRange)
    }

    func endOrbit(velocity: CGPoint) {
        let v = SIMD2(-Float(velocity.x), Float(velocity.y)) * Self.orbitSpeed
        spin = simd_length(v) > 0.3 ? v.clamped(lowerBound: [-6, -3], upperBound: [6, 3]) : .zero
    }

    /// Two-finger drag: the floor follows the fingers.
    func pan(by delta: CGSize, viewHeight: CGFloat) {
        let metersPerPoint = 2 * current.distance * tan(fovRadians / 2) / Float(max(viewHeight, 1))
        let right = SIMD3(cos(goal.azimuth), 0, -sin(goal.azimuth))
        let forward = SIMD3(-sin(goal.azimuth), 0, -cos(goal.azimuth))   // camera -> target, on the floor
        // Looking down steeply, vertical finger motion covers more floor.
        let depthScale = 1 / max(sin(goal.elevation), 0.35)
        goal.target -= right * Float(delta.width) * metersPerPoint
        goal.target += forward * Float(delta.height) * metersPerPoint * depthScale
        let h = roomSize / 2 + 0.5
        goal.target = [goal.target.x.clamped(to: -h.x...h.x), 0, goal.target.z.clamped(to: -h.y...h.y)]
    }

    func beginZoom() { zoomStart = goal.distance }
    func zoom(scale: CGFloat) {
        goal.distance = (zoomStart / Float(max(scale, 0.01))).clamped(to: zoomRange)
    }

    func twist(by radians: CGFloat) { goal.azimuth += Float(radians) }   // clockwise twist turns the room clockwise

    /// Back to the framed view along the shortest turn (azimuth is unbounded after flicks).
    func reset() {
        spin = .zero
        var h = home
        h.azimuth += 2 * .pi * ((current.azimuth - h.azimuth) / (2 * .pi)).rounded()
        goal = h
    }

    func toggleTopView() {
        spin = .zero
        goal.elevation = goal.elevation > 1.3 ? home.elevation : Self.elevationRange.upperBound
    }

    var isTopView: Bool { goal.elevation > 1.3 }

    // MARK: Frame update

    func update(dt: Float) {
        let dt = min(dt, 1 / 20)   // no jumps after a hitch
        if spin != .zero {
            goal.azimuth += spin.x * dt
            goal.elevation = (goal.elevation + spin.y * dt).clamped(to: Self.elevationRange)
            spin *= exp(-dt * 4)
            if simd_length(spin) < 0.02 { spin = .zero }
        }
        // Exponential approach ≈ critically damped follow; framerate independent.
        // While a finger is down, follow almost 1:1; otherwise ease (reset, top view, momentum tail).
        let k = 1 - exp(-dt * (tracking ? 60 : 12))
        current.azimuth += (goal.azimuth - current.azimuth) * k
        current.elevation += (goal.elevation - current.elevation) * k
        current.distance += (goal.distance - current.distance) * k
        current.target += (goal.target - current.target) * k
        apply()
    }

    private func apply() {
        let c = current
        let dir = SIMD3(cos(c.elevation) * sin(c.azimuth), sin(c.elevation), cos(c.elevation) * cos(c.azimuth))
        entity.look(at: c.target, from: c.target + dir * c.distance, relativeTo: nil)
        onFrame?(c.target + dir * c.distance)
    }

    private var fovRadians: Float { entity.camera.fieldOfViewInDegrees * .pi / 180 }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
