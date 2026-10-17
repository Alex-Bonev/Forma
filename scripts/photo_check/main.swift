import Foundation
// Run: swiftc RoomVibe/Core/Models.swift RoomVibe/Features/RoomScan/RoomPhotoMath.swift scripts/photo_check/main.swift -o /tmp/photo_check && /tmp/photo_check
import simd
// Self-check: ARKit projection conventions, facing/behind filters, median wall color, keep-photo rule.
func pose(yaw: Float, _ t: SIMD3<Float>) -> simd_float4x4 {
    var m = simd_float4x4(simd_quatf(angle: yaw, axis: [0, 1, 0])); m.columns.3 = SIMD4(t, 1); return m
}
func photo(_ t: simd_float4x4) -> RoomPhoto {
    // 400x300 landscape image, f = 300 px, principal point at the center.
    RoomPhoto(file: "x.jpg", imageSize: [400, 300], intrinsics: [[300, 0, 0], [0, 300, 0], [200, 150, 1]],
              columns: [t.columns.0, t.columns.1, t.columns.2, t.columns.3])
}
func fill(_ c: SIMD3<UInt8>) -> PhotoPixels {   // half-res sample buffer: exercises the imageSize -> pixels scaling
    PhotoPixels(width: 200, height: 150, rgba: Array((0..<200 * 150).map { _ in [c.x, c.y, c.z, 255] }.joined()))
}
func near(_ a: SIMD2<Float>?, _ b: SIMD2<Float>) -> Bool { a.map { simd_distance($0, b) < 1e-3 } ?? false }

let eye = pose(yaw: 0, [0, 1.5, 0])                       // looking down -Z
let p = photo(eye)
precondition(near(p.project([0, 1.5, -3]), [200, 150]), "center")
precondition(near(p.project([1, 2.5, -3]), [300, 50]), "right+up -> u right, v up (smaller)")
precondition(p.project([0, 1.5, 3]) == nil, "behind camera")
let left = photo(pose(yaw: .pi / 2, [0, 1.5, 0]))          // turned left: looking down -X, right = -Z
precondition(near(left.project([-3, 1.5, -1]), [300, 150]), "rotated camera \(String(describing: left.project([-3, 1.5, -1])))")

// Wall 3 m ahead facing the camera; 4 x 2.5 m.
let wall = RoomModel.Box(label: "wall", dimensions: [4, 2.5, 0], transform: pose(yaw: 0, [0, 1.25, -3]))
let paint: SIMD3<UInt8> = [200, 100, 50]
let shots = [(p, fill(paint)), (p, fill(paint)), (p, fill([0, 0, 255])),        // one outlier photo
             (photo(pose(yaw: .pi, [0, 1.5, 0])), fill([0, 255, 0]))]           // facing away: wall behind it
let c = RoomPhoto.wallRGB(walls: [wall], shots: shots)!
precondition(simd_distance(c * 255, SIMD3<Float>(200, 100, 50)) < 1, "median color \(c * 255)")
// Edge-on wall (normal perpendicular to the view direction) is skipped.
let edge = RoomModel.Box(label: "wall", dimensions: [4, 2.5, 0], transform: pose(yaw: .pi / 2, [0, 1.25, -5]))
precondition(RoomPhoto.wallRGB(walls: [edge], shots: [(p, fill(paint))]) == nil, "edge-on wall sampled")
print("projection + wall color OK", c * 255)

precondition(!RoomPhoto.movedEnough(from: eye, to: pose(yaw: 0.2, [0.3, 1.5, 0])), "small move")
precondition(RoomPhoto.movedEnough(from: eye, to: pose(yaw: 0, [0.6, 1.5, 0])), "0.6 m")
precondition(RoomPhoto.movedEnough(from: eye, to: pose(yaw: 0.5, [0, 1.5, 0])), "29 deg")
print("keep-photo rule OK")
