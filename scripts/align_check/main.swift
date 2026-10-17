import Foundation
// Run: swiftc RoomVibe/Core/Models.swift RoomVibe/Features/RoomScan/RoomAlignment.swift scripts/align_check/main.swift -o /tmp/align_check && /tmp/align_check
import simd
// Self-check: a 5x4 room rotated 30° comes back axis-aligned with the right footprint.
func rotY(_ a: Float, _ t: SIMD3<Float>) -> simd_float4x4 {
    var m = simd_float4x4(simd_quatf(angle: a, axis: [0, 1, 0])); m.columns.3 = SIMD4(t, 1); return m
}
let a: Float = .pi / 6
let base: [(Float, SIMD3<Float>, Float)] = [(5, [0, 1.25, -2], 0), (5, [0, 1.25, 2], 0), (4, [2.5, 1.25, 0], .pi/2), (4, [-2.5, 1.25, 0], .pi/2)]
let walls = base.map { w, p, r in
    RoomModel.Box(label: "wall", dimensions: [w, 2.5, 0], transform: rotY(a, .zero) * rotY(r, p))
}
var sofa = RoomModel.Box(label: "sofa", dimensions: [2, 0.8, 1], transform: rotY(a, .zero) * rotY(0, [1, 0.4, 0]))
sofa.attributes = ["SofaType.lShaped"]
let outline: [SIMD3<Float>] = [[-2.5, 0, -2], [2.5, 0, -2], [2.5, 0, 2], [-2.5, 0, 2]].map { simd_quatf(angle: a, axis: [0, 1, 0]).act($0) }
let room = RoomModel(walls: walls, objects: [sofa], floorOutline: outline).axisAligned()
var lo = SIMD3<Float>(repeating: 1e9), hi = -lo
for b in room.walls {
    let c = SIMD3(b.columns[3].x, b.columns[3].y, b.columns[3].z), x = SIMD3(b.columns[0].x, b.columns[0].y, b.columns[0].z) * b.dimensions.x / 2
    for p in [c + x, c - x] { lo = simd_min(lo, p); hi = simd_max(hi, p) }
}
let size = SIMD2(hi.x - lo.x, hi.z - lo.z)
precondition(abs(size.x - 5) < 1e-3 && abs(size.y - 4) < 1e-3, "footprint \(size)")
let s = room.objects[0].columns
precondition(abs(s[0].z) < 1e-4 && abs(s[3].x - 1) < 1e-4 && abs(s[3].z) < 1e-4, "sofa \(s)")
precondition(abs(room.walls[0].columns[3].y - 1.25) < 1e-5, "height kept")
precondition(room.objects[0].attributes == ["SofaType.lShaped"], "attributes kept")
let fo = room.floorOutline!
precondition(abs(fo.map(\.x).max()! - 2.5) < 1e-4 && abs(fo.map(\.z).max()! - 2) < 1e-4, "outline aligned \(fo)")
print("align_check OK", size)

// Marked items: floor-to-tap boxes (floor from wall bottoms).
let marks = RoomModel.markedItems([[1, 0.8, 1]], walls: walls)
precondition(marks.count == 1 && abs(marks[0].dimensions.y - 0.8) < 1e-5 && abs(marks[0].columns[3].y - 0.4) < 1e-5, "marked box \(marks)")
print("marked items OK")
