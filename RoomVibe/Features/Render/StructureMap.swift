import UIKit
import simd

/// The Designer camera at the moment of the snapshot. B fills it from DesignerView, right next to the capture:
///   RenderCamera(transform: camera.transformMatrix(relativeTo: nil), verticalFOV: camera.camera.fieldOfViewInDegrees,
///                viewSize: viewSize, wallScale: lowWalls ? 0.3 : 1)
/// Must describe the same frame as the snapshot, or the map will not line up.
struct RenderCamera {
    var transform: simd_float4x4   // world space pose, looking down -Z
    var verticalFOV: Float         // degrees
    var viewSize: CGSize           // size of the captured RealityView; only the aspect ratio matters
    var wallScale: Float = 1       // the wallScale passed to RoomBuilder.build (cutaway toggle)
}

/// Flat-color map of the same view as the snapshot, made by casting one ray per pixel against the room's boxes.
/// Each surface type gets its own color; brighter = closer. Gives the image model exact outlines without the
/// shading, labels and rounded corners of the real render.
/// Rebuilds the same boxes as RoomBuilder.build (centering, wall thickness, cutaway); keep the two in sync.
enum StructureMap {
    struct Output { let image: UIImage; let legend: String }

    private struct Solid {
        let inverse: simd_float4x4   // world -> box local (box centered at origin)
        let half: SIMD3<Float>
        let kind: Kind
    }

    enum Kind: CaseIterable {
        case floor, wall, door, window, sofa, chair, table, bed, storage, television, otherFurniture, placedObject

        var color: SIMD3<Float> {
            switch self {
            case .floor: [0.45, 0.45, 0.45]
            case .wall: [1, 1, 1]
            case .door: [0.55, 0.3, 0.1]
            case .window: [0, 0.9, 1]
            case .sofa: [1, 0, 0]
            case .chair: [1, 0.55, 0]
            case .table: [1, 1, 0]
            case .bed: [0, 0.8, 0]
            case .storage: [0.6, 0, 1]
            case .television: [0, 0, 0.35]
            case .otherFurniture: [1, 0, 1]
            case .placedObject: [0, 0.3, 1]
            }
        }

        var colorName: String {
            switch self {
            case .floor: "gray"
            case .wall: "white"
            case .door: "brown"
            case .window: "cyan"
            case .sofa: "red"
            case .chair: "orange"
            case .table: "yellow"
            case .bed: "green"
            case .storage: "purple"
            case .television: "navy"
            case .otherFurniture: "magenta"
            case .placedObject: "blue"
            }
        }

        var noun: String {
            switch self {
            case .floor: "floor"
            case .wall: "walls"
            case .door: "doors"
            case .window: "windows"
            case .sofa: "sofas"
            case .chair: "chairs"
            case .table: "tables"
            case .bed: "beds"
            case .storage: "storage"
            case .television: "TV"
            case .otherFurniture: "other furniture"
            case .placedObject: "the detailed 3D model(s)"
            }
        }

        init(label: String) {
            self = switch label {
            case "sofa": .sofa
            case "chair": .chair
            case "table": .table
            case "bed": .bed
            case "storage": .storage
            case "television": .television
            default: .otherFurniture
            }
        }
    }

    /// `width`: output pixels across; height follows the camera's view aspect. Call off the main thread.
    /// Returns nil when cancelled.
    static func render(room: RoomModel, placements: [Placement], objects: [ScannedObject],
                       camera: RenderCamera, width: Int = 384) -> Output? {
        guard camera.viewSize.width >= 1, camera.viewSize.height >= 1, width > 0 else { return nil }
        let aspect = min(max(Float(camera.viewSize.height / camera.viewSize.width), 1.0 / 3), 3)
        let height = Int((Float(width) * aspect).rounded())
        let solids = scene(room: room, placements: placements, objects: objects, wallScale: camera.wallScale)

        let origin = SIMD3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
        let rot = simd_float3x3(SIMD3(camera.transform.columns.0.x, camera.transform.columns.0.y, camera.transform.columns.0.z),
                                SIMD3(camera.transform.columns.1.x, camera.transform.columns.1.y, camera.transform.columns.1.z),
                                SIMD3(camera.transform.columns.2.x, camera.transform.columns.2.y, camera.transform.columns.2.z))
        let t = tan(camera.verticalFOV * .pi / 360)
        let w = Float(width), h = Float(height)

        // First pass: nearest hit per pixel. Second: shade by depth relative to the visible range.
        if Task.isCancelled { return nil }   // GCD workers have no task, so check around the loop, not inside
        var hits = [(depth: Float, kind: Kind)?](repeating: nil, count: width * height)
        hits.withUnsafeMutableBufferPointer { buf in
          DispatchQueue.concurrentPerform(iterations: height) { y in   // rows write disjoint ranges
            for x in 0..<width {
                // Same ray math as DesignerView.ray(at:), at pixel centers.
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let local = normalize(SIMD3((2 * px / w - 1) * t * w / h, (1 - 2 * py / h) * t, -1))
                let dir = rot * local
                var best: (Float, Kind)?
                for s in solids {
                    if let d = intersect(origin, dir, s), d < best?.0 ?? .greatestFiniteMagnitude { best = (d, s.kind) }
                }
                buf[y * width + x] = best
            }
          }
        }
        if Task.isCancelled { return nil }
        let depths = hits.compactMap { $0?.depth }
        guard let near = depths.min(), let far = depths.max() else { return nil }
        let range = max(far - near, 0.001)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (i, hit) in hits.enumerated() {
            var c = SIMD3<Float>(0, 0, 0)   // background: black
            if let hit { c = hit.kind.color * (1 - 0.55 * (hit.depth - near) / range) }
            pixels[i * 4] = UInt8(c.x * 255); pixels[i * 4 + 1] = UInt8(c.y * 255); pixels[i * 4 + 2] = UInt8(c.z * 255)
            pixels[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        let present = Set(hits.compactMap { $0?.kind })
        let legend = "Structure map colors: " + Kind.allCases.filter(present.contains)
            .map { "\($0.noun) \($0.colorName)" }.joined(separator: ", ") + "; background black."
        return Output(image: UIImage(cgImage: cg), legend: legend)
    }

    /// Room boxes moved into the Designer's frame (RoomBuilder centers the room and puts the floor at y = 0).
    private static func scene(room: RoomModel, placements: [Placement], objects: [ScannedObject], wallScale: Float) -> [Solid] {
        let outline = room.walls.isEmpty ? room.objects : room.walls
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for b in outline {   // same bounds as RoomBuilder.build
            let t = b.transform, c = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let x = SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z) * b.dimensions.x / 2
            for p in [c + x, c - x] { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            lo.y = min(lo.y, c.y - b.dimensions.y / 2)
        }
        guard !outline.isEmpty else { return [] }
        let center = SIMD3((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2)
        let shift = simd_float4x4(translation: -center)

        var solids: [Solid] = []
        func add(_ m: simd_float4x4, _ size: SIMD3<Float>, _ kind: Kind) {
            solids.append(Solid(inverse: m.inverse, half: size / 2, kind: kind))
        }
        // Thin slab so floor hits always register; matches RoomBuilder's plane (room size + 0.4 m).
        add(simd_float4x4(translation: [0, -0.005, 0]), [hi.x - lo.x + 0.4, 0.01, hi.z - lo.z + 0.4], .floor)

        func addSurface(_ b: RoomModel.Box, depth: Float, _ kind: Kind) {
            // RoomBuilder shrinks walls from the floor up when cut away.
            var m = shift * b.transform
            let h = b.dimensions.y * wallScale
            m.columns.3.y = (m.columns.3.y - b.dimensions.y / 2) * wallScale + h / 2
            add(m, [b.dimensions.x, h, depth], kind)
        }
        let wall: Float = 0.08   // RoomBuilder.wallThickness (main-actor isolated, so not read from here)
        room.walls.forEach { addSurface($0, depth: wall, .wall) }
        room.doors.forEach { addSurface($0, depth: wall + 0.02, .door) }
        room.windows.forEach { addSurface($0, depth: wall + 0.02, .window) }
        room.objects.forEach { add(shift * $0.transform, $0.dimensions, Kind(label: $0.label)) }

        for p in placements {
            guard let o = objects.first(where: { $0.id == p.objectID }) else { continue }
            let m = simd_float4x4(translation: p.position + [0, o.boundingBox.y / 2, 0])
                * simd_float4x4(simd_quatf(angle: p.yRotation, axis: [0, 1, 0]))
            add(m, o.boundingBox, .placedObject)
        }
        return solids
    }

    /// Ray vs oriented box (slab test in the box's local frame). Returns the distance along the ray.
    private static func intersect(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ s: Solid) -> Float? {
        let ro4 = s.inverse * SIMD4(o, 1), rd4 = s.inverse * SIMD4(d, 0)
        let ro = SIMD3(ro4.x, ro4.y, ro4.z), rd = SIMD3(rd4.x, rd4.y, rd4.z)
        // Camera inside this box (close zoom, inside a wall slab): ignore it rather than fill the frame with it.
        if abs(ro.x) <= s.half.x, abs(ro.y) <= s.half.y, abs(ro.z) <= s.half.z { return nil }
        var tmin: Float = 0, tmax = Float.greatestFiniteMagnitude
        for i in 0..<3 {
            if abs(rd[i]) < 1e-8 {
                if abs(ro[i]) > s.half[i] { return nil }
                continue
            }
            var t0 = (-s.half[i] - ro[i]) / rd[i], t1 = (s.half[i] - ro[i]) / rd[i]
            if t0 > t1 { swap(&t0, &t1) }
            tmin = max(tmin, t0); tmax = min(tmax, t1)
            if tmin > tmax { return nil }
        }
        return tmin
    }
}

private extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }
}
