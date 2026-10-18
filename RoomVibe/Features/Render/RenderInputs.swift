import UIKit
import simd

/// What "Make it real" describes, built from the project the way the Designer shows it.
/// Scan photos are not sent: with them the image model copied real furniture the 3D model doesn't have.
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
}
