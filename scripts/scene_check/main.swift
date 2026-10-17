import Foundation
// Run from the repo root:
// swiftc RoomVibe/Core/Models.swift RoomVibe/Features/RoomScan/RoomPhotoMath.swift RoomVibe/Features/RoomScan/SceneClassifier.swift scripts/scene_check/main.swift -o /tmp/scene_check && /tmp/scene_check
import simd
// Self-check: Vision label -> catalog mapping, brick/wood votes, image orientation, wall/floor crops (pure),
// then Vision itself on the bundled finish textures (Mac).
typealias S = SceneClassifier

// Mapping. Scores are from Mac runs on Commons photos (docs/specs/scan-intelligence.md).
precondition(S.suggestion([("container", 0.88), ("trash_can", 0.88), ("bucket", 0.18)]) == .init(vision: "trash_can", catalog: "trash"))
precondition(S.suggestion([("furniture", 0.46), ("chair", 0.46), ("armchair", 0.46)])?.catalog == "chair", "chair/armchair tie")
precondition(S.suggestion([("light", 0.28), ("lamp", 0.28)])?.catalog == "floor_lamp", "lamp at 0.28")
precondition(S.suggestion([("textile", 0.40), ("cardboard_box", 0.31)])?.catalog == "box", "textile is not a rug")
precondition(S.suggestion([("plant", 0.33), ("cabinet", 0.5)])?.catalog == "cabinet", "highest mapped wins")
precondition(S.suggestion([("cabinet", 0.14)]) == nil, "below threshold")
precondition(S.suggestion([("bell", 0.43), ("musical_instrument", 0.43)]) == nil, "traffic cone: no label")
let catalogSource = try! String(contentsOfFile: "RoomVibe/Features/Designer/Catalog.swift", encoding: .utf8)
for (v, c) in S.catalogMap { precondition(catalogSource.contains("id: \"\(c)\""), "\(v) -> unknown catalog id \(c)") }
print("mapping OK (\(S.catalogMap.count) labels)")

// Votes: brick needs >= 30% of wall crops at >= 0.5; wood >= 30% of floor crops at >= 0.3.
func crops(_ hits: Int, of n: Int, _ label: String, _ c: Float) -> [[(String, Float)]] {
    (0..<n).map { $0 < hits ? [("material", 0.9), (label, c)] : [("material", 0.2)] }
}
precondition(S.isBrick(crops(3, of: 10, "brick", 0.96)))
precondition(!S.isBrick(crops(2, of: 10, "brick", 0.96)), "20% is not enough")
precondition(!S.isBrick(crops(10, of: 10, "brick", 0.49)), "weak brick")
precondition(!S.isBrick([]), "no crops")
precondition(S.isWood(crops(1, of: 3, "wood_natural", 0.3)) && !S.isWood(crops(3, of: 3, "wood_processed", 0.29)))
print("votes OK")

// Orientation: landscape-right is upright; portrait (camera -X is world up) reads .right.
func pose(_ x: SIMD3<Float>, _ y: SIMD3<Float>, _ z: SIMD3<Float>, _ t: SIMD3<Float> = [0, 1.5, 0]) -> simd_float4x4 {
    .init(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(t, 1))
}
precondition(S.orientation(camera: pose([1, 0, 0], [0, 1, 0], [0, 0, 1])) == .up)
precondition(S.orientation(camera: pose([0, -1, 0], [1, 0, 0], [0, 0, 1])) == .right)
precondition(S.orientation(camera: pose([0, 1, 0], [-1, 0, 0], [0, 0, 1])) == .left)

// Crops: 400x300 camera at 1.5 m looking down -Z; 4 x 2.5 m wall 3 m ahead.
func photo(_ t: simd_float4x4) -> RoomPhoto {
    RoomPhoto(file: "", imageSize: [400, 300], intrinsics: [[300, 0, 0], [0, 300, 0], [200, 150, 1]],
              columns: [t.columns.0, t.columns.1, t.columns.2, t.columns.3])
}
let level = photo(pose([1, 0, 0], [0, 1, 0], [0, 0, 1]))
var wallT = matrix_identity_float4x4; wallT.columns.3 = [0, 1.25, -3, 1]
let wall = RoomModel.Box(label: "wall", dimensions: [4, 2.5, 0], transform: wallT)
let r = level.wallCrops([wall])
precondition(r.count == 1 && abs(r[0].midX - 0.5) < 0.01 && abs(r[0].width - 0.7) < 0.01, "facing wall crop \(r)")
var behind = wallT; behind.columns.3.z = 3
precondition(level.wallCrops([RoomModel.Box(label: "wall", dimensions: [4, 2.5, 0], transform: behind)]).isEmpty, "wall behind")
precondition(level.floorCrop == nil, "level camera sees no floor")
let c = Float(0.7071)   // pitched 45° down: camera -Z points forward and down
let down = photo(pose([1, 0, 0], [0, c, -c], [0, c, c]))
precondition(down.floorCrop == CGRect(x: 0, y: 2 / 3.0, width: 1, height: 1 / 3.0), "bottom third")
print("orientation + crops OK")

// Vision on the bundled textures, as photos are classified in the app (decoded to <= 512 px).
let dir = "RoomVibe/Resources/DemoData/Finishes/"
func labels(_ name: String) -> [(String, Float)] {
    S.classify(S.decode(try! Data(contentsOf: URL(fileURLWithPath: dir + name)))!)
}
for name in try! FileManager.default.contentsOfDirectory(atPath: dir).sorted() {
    let l = labels(name)
    let brick = S.isBrick([l]), wood = S.isWood([l])
    print(name, brick ? "BRICK" : "", wood ? "WOOD" : "", l.prefix(4).map { "\($0.0) \(String(format: "%.2f", $0.1))" })
    precondition(brick == name.contains("brick"), "brick: \(name)")
    precondition(!wood || name.contains("wood") || name.contains("plank"), "wood: \(name)")
}
precondition(S.isWood([labels("finish_wood_floor.jpg")]), "wood floor")

// End to end + timing: 40 photos pitched 25° down at a brick wall (2 walls + floor = 3 crops each), as on save.
let sn = Float(sin(25 * Double.pi / 180)), cs = Float(cos(25 * Double.pi / 180))
let tilted = photo(pose([1, 0, 0], [0, cs, -sn], [0, sn, cs]))
precondition(tilted.wallCrops([wall]).count == 1 && tilted.floorCrop != nil, "tilted photo sees wall and floor")
let brickJPEG = try! Data(contentsOf: URL(fileURLWithPath: dir + "finish_red_brick_03.jpg"))
_ = S.classify(S.decode(brickJPEG)!)   // model load
let t0 = Date()
let f = S.finishes(walls: [wall, wall], photos: Array(repeating: (tilted, brickJPEG), count: 40), deadline: 60)
print(String(format: "40 photos, 120 crops: %.0f ms", Date().timeIntervalSince(t0) * 1000))
precondition(f == .init(brickWalls: true, woodFloor: false), "\(f)")
print("scene check OK")
