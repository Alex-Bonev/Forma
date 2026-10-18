import Foundation
import simd

/// Plain-text description of a room for the render prompt: size, openings, and what each colored block is.
/// The image model sees blocks; this tells it "blue block = sofa, 2.1 m wide, against a wall".
enum LayoutDescription {
    /// `finishes`: wall/floor sentence (RenderInputs.finishes). `standIns`: placements that are generic catalog
    /// stand-ins, not scans of a real product.
    static func text(room: RoomModel, placements: [Placement], objects: [ScannedObject],
                     finishes: String = "White walls.", standIns: Set<UUID> = []) -> String {
        let walls = room.walls.map(Segment.init)
        let outline = walls.isEmpty ? room.objects.map(Segment.init) : walls
        let lo = outline.flatMap { [$0.a, $0.b] }.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = outline.flatMap { [$0.a, $0.b] }.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let size = outline.isEmpty ? .zero : hi - lo
        let center = (lo + hi) / 2   // RoomBuilder centers the room here; placements live in that centered frame
        let height = room.walls.map(\.dimensions.y).max() ?? 2.5
        let windows = room.windows.map { SIMD2($0.transform.columns.3.x, $0.transform.columns.3.z) }

        // Without walls the outline is just the furniture, so its size would be misleading.
        var lines = walls.isEmpty ? [] : [String(format: "Room exactly %.1f x %.1f m, ceiling %.1f m; keep this size and these proportions.",
                                                 size.x, size.y, height) + " " + finishes]
        if let o = room.floorOutline, o.count > 4 {
            lines.append("The floor plan is not a rectangle (\(o.count) corners, e.g. L-shaped): follow image 1's outline exactly.")
        }
        var openings: [String] = []
        if !room.doors.isEmpty { openings.append(count(room.doors.count, "door") + " (brown panels)") }
        if !room.windows.isEmpty { openings.append(count(room.windows.count, "window") + " (light blue panels)") }
        if !openings.isEmpty { lines.append("Openings: " + openings.joined(separator: ", ") + ".") }

        func spot(_ p: SIMD2<Float>, depth: Float) -> String {
            var notes: [String] = []
            if let d = walls.map({ $0.distance(to: p) }).min(), d < depth / 2 + 0.35 { notes.append("against a wall") }
            else { notes.append("free-standing") }
            if windows.contains(where: { simd_distance($0, p) < 1.5 }) { notes.append("near a window") }
            return notes.joined(separator: ", ")
        }

        var items: [String] = []
        for b in room.objects {
            let p = SIMD2(b.transform.columns.3.x, b.transform.columns.3.z)
            items.append(String(format: "%@ (scanned, %.1f m wide, %.1f m deep, %.1f m tall, %@)", b.label,
                                b.dimensions.x, b.dimensions.z, b.dimensions.y, spot(p, depth: min(b.dimensions.x, b.dimensions.z))))
        }
        for pl in placements {
            guard let o = objects.first(where: { $0.id == pl.objectID }) else { continue }
            let p = SIMD2(pl.position.x, pl.position.z) + center
            let kind = standIns.contains(pl.id) ? "added by the user" : "a 3D scan of a real product; keep its exact shape and colors"
            items.append(String(format: "%@ (%@, %.1f m wide, %.1f m deep, %.1f m tall, %@)", o.name, kind,
                                o.boundingBox.x, o.boundingBox.z, o.boundingBox.y, spot(p, depth: min(o.boundingBox.x, o.boundingBox.z))))
        }
        // An exact count: the image model otherwise "completes" rooms with furniture that isn't there.
        lines.append(items.isEmpty ? "No furniture: the room is empty."
                     : "Furniture, exactly \(items.count) piece\(items.count == 1 ? "" : "s") and nothing else: "
                       + items.joined(separator: "; ") + ".")
        return lines.joined(separator: " ")
    }

    private static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    /// A box's bottom edge on the floor plan: center ± half width along its local X.
    private struct Segment {
        let a, b: SIMD2<Float>

        init(_ box: RoomModel.Box) {
            let t = box.transform
            let c = SIMD2(t.columns.3.x, t.columns.3.z), x = SIMD2(t.columns.0.x, t.columns.0.z) * box.dimensions.x / 2
            a = c - x; b = c + x
        }

        func distance(to p: SIMD2<Float>) -> Float {
            let ab = b - a, len = simd_length_squared(ab)
            let t = len > 0 ? simd_clamp(simd_dot(p - a, ab) / len, 0, 1) : 0
            return simd_distance(p, a + ab * t)
        }
    }
}
