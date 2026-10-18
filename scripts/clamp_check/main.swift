// swiftc RoomVibe/Features/Designer/FloorClamp.swift scripts/clamp_check/main.swift -o build/clamp_check && build/clamp_check
import simd
// L-shaped room: 4x4 with the top-right 2x2 cut out.
let L: [SIMD2<Float>] = [[0, 0], [4, 0], [4, 2], [2, 2], [2, 4], [0, 4]]
assert(FloorClamp.clamp([1, 1], to: L, inset: 0.3) == [1, 1], "inside stays")
let notch = FloorClamp.clamp([3, 3], to: L, inset: 0.3)
assert(FloorClamp.contains(notch, L), "point in the notch moves inside: \(notch)")
assert(simd_distance(notch, [3, 3]) < 1.5, "moves to the nearby edge, not far away: \(notch)")
let out = FloorClamp.clamp([-1, 1], to: L, inset: 0.3)
assert(FloorClamp.contains(out, L) && out.x > 0 && out.x < 0.5, "outside left wall clamps just inside: \(out)")
print("clamp_check ok", notch, out)
