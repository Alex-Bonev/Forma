import UIKit
import simd

/// What "Make it real" describes, built from the project the way the Designer shows it, plus real scan photos
/// as ground truth for how the room looks.
enum RenderInputs {
    /// Room for LayoutDescription and StructureMap: hidden/replaced scanned objects dropped, every placement
    /// (library scans and catalog items) as a sized object. Catalog items are stand-ins, listed in `standIns`.
    /// `shopped`: every shopped placement (Placement.product), in placement order; Make it real numbers the first 3
    /// whose photo (ProductPhotos) loads as product 1, 2, 3.
    static func scene(project: Project, room: RoomModel, objects: [ScannedObject])
        -> (room: RoomModel, placements: [Placement], objects: [ScannedObject], standIns: Set<UUID>,
            shopped: [(id: UUID, product: ShopProduct)]) {
        var visible = room
        let gone = Set((project.hiddenRoomObjects ?? []) + (project.removedRoomObjects ?? []))
        visible.objects = room.objects.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
        var placements: [Placement] = [], sized: [ScannedObject] = [], standIns: Set<UUID> = []
        for p in project.placements {
            let base: (name: String, size: SIMD3<Float>)
            if let item = CatalogItem.item(p.catalogItem) {
                // A shopped product (Vibe) is named by its listing so the model can match the real piece.
                // Title capped: the backend cuts the layout at 2000 chars, and the structure-map legend comes last.
                base = (p.product.map { "\($0.title.prefix(60)) (\(item.name.lowercased()))" } ?? item.name.lowercased(), item.size)
                standIns.insert(p.id)
            } else if let o = objects.first(where: { $0.id == p.objectID }) {
                base = (p.product != nil ? String(o.name.prefix(60)) : o.name, o.boundingBox)   // Make it 3D: product title
            } else { continue }
            var q = p
            q.objectID = p.id   // one sized object per placement, so scale is baked in
            placements.append(q)
            sized.append(ScannedObject(id: p.id, name: base.name, modelFile: nil, boundingBox: base.size * (p.scale ?? .one)))
        }
        return (visible, placements, sized, standIns, placements.compactMap { p in p.product.map { (p.id, $0) } })
    }

    /// "Walls: Matched Paint (#CEB389). Floor: Oak." for the prompt (replaces the old fixed "white walls").
    static func finishes(_ project: Project) -> String {
        let wall = Finish.wall(project.wallFinish), floor = Finish.floor(project.floorFinish)
        let paint = project.wallFinish.flatMap { $0.hasPrefix(Finish.paintPrefix) ? String($0.dropFirst(Finish.paintPrefix.count)) : nil }
        let wallText = paint.map { "painted, color \($0) as sampled from photos of the real walls" } ?? wall.name.lowercased()
        return "Walls: \(wallText). Floor: \(floor.name.lowercased())."
    }

    /// Up to `count` scan photos spread around the room (by viewing direction), upright, ≤ 1024 px.
    static func photos(projectID: UUID, count: Int = 3) -> [UIImage] {
        let dir = ProjectStore.projectDir(projectID).appending(path: "photos")
        guard let data = try? Data(contentsOf: dir.appending(path: "photos.json")),
              let all = try? JSONDecoder().decode([RoomPhoto].self, from: data) else { return [] }
        // Mostly level shots show walls and furniture; steep ones are floor or ceiling.
        let level = all.filter { abs(forward($0).y) < 0.55 }.sorted { yaw($0) < yaw($1) }
        guard !level.isEmpty else { return [] }
        let picks = (0..<min(count, level.count)).map { level[$0 * level.count / min(count, level.count)] }
        return picks.compactMap { p in
            guard let img = UIImage(contentsOfFile: dir.appending(path: p.file).path(percentEncoded: false)),
                  let cg = img.cgImage else { return nil }
            let upright = UIImage(cgImage: cg, scale: 1, orientation: orientation(p))
            return upright.uploadJPEG(maxEdge: 1024).flatMap(UIImage.init(data:))
        }
    }

    private static func forward(_ p: RoomPhoto) -> SIMD3<Float> { -SIMD3(p.columns[2].x, p.columns[2].y, p.columns[2].z) }
    private static func yaw(_ p: RoomPhoto) -> Float { let f = forward(p); return atan2(f.x, f.z) }

    /// Photos are stored in sensor orientation (landscape). Turn them so world-up points up, from the camera pose.
    static func orientation(_ p: RoomPhoto) -> UIImage.Orientation {
        // World up in camera space; image x = camera +X, image y (down) = camera -Y.
        let r = simd_float3x3(SIMD3(p.columns[0].x, p.columns[0].y, p.columns[0].z),
                              SIMD3(p.columns[1].x, p.columns[1].y, p.columns[1].z),
                              SIMD3(p.columns[2].x, p.columns[2].y, p.columns[2].z))
        let up = r.transpose * SIMD3<Float>(0, 1, 0)
        if abs(up.x) > abs(up.y) { return up.x > 0 ? .left : .right }   // up points to the image's right / left
        return up.y > 0 ? .up : .down
    }
}
