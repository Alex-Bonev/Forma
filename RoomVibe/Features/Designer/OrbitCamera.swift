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

    static let normalLens: Float = 60   // PerspectiveCamera default, vertical degrees
    static let wideLens: Float = 80     // eye-level "Make it real" (interior photos are shot wide)
    func useNormalLens() { entity.camera.fieldOfViewInDegrees = Self.normalLens }
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
        goal.target = [goal.target.x.clamped(to: -h.x...h.x), goal.target.y, goal.target.z.clamped(to: -h.y...h.y)]   // y: eye level looks at 1 m
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

    // MARK: Render angles ("Make it real")

    enum Angle: String, CaseIterable { case overview = "Overview", top = "Top", eye = "Eye level" }

    /// Eases to a preset framing. `side` turns it a quarter around the room (0…3).
    /// Eye level: 1.5 m high toward a corner, looking across the floor's middle with a wide lens; no walls cut away.
    /// `floor`: on the scanned floor (room-centered x/z). `clear`: not inside or right next to furniture.
    func show(_ angle: Angle, side: Int, floor: ((SIMD2<Float>) -> Bool)? = nil, clear: ((SIMD2<Float>) -> Bool)? = nil) {
        spin = .zero
        entity.camera.fieldOfViewInDegrees = angle == .eye ? Self.wideLens : Self.normalLens   // a room photo needs a wide lens
        let turn = Float(side) * .pi / 2
        let s = max(roomSize.x, roomSize.y, 2)
        switch angle {
        case .overview:
            var h = home
            h.azimuth += turn
            goal = h
        case .top:
            goal = Pose(azimuth: home.azimuth + turn, elevation: Self.elevationRange.upperBound - 0.02, distance: s * 1.3 + 1.5)
        case .eye:
            // Sample the real floor (L-rooms aren't their bounding box), aim at its middle, and stand as far toward
            // the requested corner as a spot allows: on open floor, seeing across without crossing a wall, with
            // nothing right in front of the lens.
            let onFloor = floor ?? { _ in true }, isClear = clear ?? { _ in true }
            let h = roomSize / 2 - 0.3
            var grid: [SIMD2<Float>] = []
            for x in stride(from: -h.x, through: h.x, by: 0.25) {
                for z in stride(from: -h.y, through: h.y, by: 0.25) where onFloor([x, z]) { grid.append([x, z]) }
            }
            let middle = grid.isEmpty ? .zero : grid.reduce(.zero, +) / Float(grid.count)
            func look(from eye: SIMD2<Float>) -> SIMD2<Float> {
                let past = middle + (middle - eye) * 0.3   // a little past the middle
                return onFloor(past) ? past : middle
            }
            func good(_ eye: SIMD2<Float>) -> Bool {
                let to = look(from: eye)
                let path = (1...12).map { eye + (to - eye) * Float($0) / 12 }
                let roomy = [SIMD2<Float>(0.4, 0), [-0.4, 0], [0, 0.4], [0, -0.4]].allSatisfy { onFloor(eye + $0) }   // off the walls
                return roomy && isClear(eye) && path.allSatisfy(onFloor) && path.filter { simd_distance($0, eye) < 1.2 }.allSatisfy(isClear)
            }
            let corners: [SIMD2<Float>] = [[-1, -1], [1, -1], [1, 1], [-1, 1]]
            let toward = simd_normalize(corners[side % 4] * roomSize)
            let ranked = grid.sorted { simd_dot($0 - middle, toward) > simd_dot($1 - middle, toward) }
            let eye = ranked.first(where: good) ?? ranked.first(where: isClear) ?? middle
            let target = look(from: eye)
            let rise: Float = 0.5                                          // eye 1.5 m, looking at 1.0 m
            let flat = max(simd_distance(eye, target), 0.5)
            let back = (eye - target) / flat
            goal = Pose(azimuth: atan2(back.x, back.y), elevation: max(atan(rise / flat), Self.elevationRange.lowerBound),
                        distance: (flat * flat + rise * rise).squareRoot(), target: [target.x, 1, target.y])
        }
        // Keep the azimuth near the current one, so the ease takes the short way round.
        goal.azimuth += 2 * .pi * ((current.azimuth - goal.azimuth) / (2 * .pi)).rounded()
    }

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
