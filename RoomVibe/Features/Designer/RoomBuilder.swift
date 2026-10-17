import RealityKit
import UIKit

/// RoomModel -> RealityKit "dollhouse". Output is centered on the room with the floor at y = 0,
/// so placements can live in plain scene coordinates.
@MainActor
enum RoomBuilder {
    struct Built { let entity: Entity; let size: SIMD2<Float> }

    static let wallThickness: Float = 0.08
    static let surfaceName = "surface"              // prefix of every wall/door/window entity (wall cutaway)
    static let wallName = "surface:wall"
    static let floorName = "floor"
    static let furniturePrefix = "furniture:"

    static func build(_ room: RoomModel, wallScale: Float = 1) -> Built {
        let boxes = room.walls.isEmpty ? room.objects : room.walls
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for b in boxes {
            // Wall endpoints = center ± half width along local X.
            let t = b.transform, c = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let x = SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z) * b.dimensions.x / 2
            for p in [c + x, c - x] { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            lo.y = min(lo.y, c.y - b.dimensions.y / 2)
        }
        let center = SIMD3((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2)
        let size = SIMD2(hi.x - lo.x, hi.z - lo.z)

        let root = Entity()
        let content = Entity()
        content.position = -center
        root.addChild(content)

        let floor = ModelEntity(mesh: .generatePlane(width: size.x + 0.4, depth: size.y + 0.4),
                                materials: [material(.init(white: 0.93, alpha: 1), roughness: 0.9)])
        floor.position = center
        floor.name = floorName
        content.addChild(floor)

        func addSurface(_ b: RoomModel.Box, depth: Float, color: UIColor, kind: String) {
            let h = b.dimensions.y * wallScale
            let e = ModelEntity(mesh: .generateBox(size: [b.dimensions.x, h, depth]), materials: [material(color)])
            e.transform = Transform(matrix: b.transform)
            // Shrink from the floor up, not around the center.
            e.position.y = lo.y + (e.position.y - lo.y - b.dimensions.y / 2) * wallScale + h / 2
            e.name = surfaceName + ":" + kind   // faded by DesignerView's WallCutaway when between camera and room
            content.addChild(e)
        }
        room.walls.forEach { addSurface($0, depth: wallThickness, color: .init(white: 0.97, alpha: 1), kind: "wall") }
        room.doors.forEach { addSurface($0, depth: wallThickness + 0.02, color: .init(red: 0.55, green: 0.42, blue: 0.3, alpha: 1), kind: "door") }
        room.windows.forEach { addSurface($0, depth: wallThickness + 0.02, color: .init(red: 0.62, green: 0.8, blue: 0.95, alpha: 1), kind: "window") }

        for (i, b) in room.objects.enumerated() {
            let e = ModelEntity(mesh: .generateBox(size: b.dimensions, cornerRadius: min(0.04, b.dimensions.min() / 4)),
                                materials: [material(color(for: b.label))])
            e.transform = Transform(matrix: b.transform)
            e.name = furniturePrefix + "\(i)"
            content.addChild(e)

            let text = ModelEntity(mesh: .generateText(b.label.capitalized, extrusionDepth: 0.002,
                                                       font: .systemFont(ofSize: 0.08, weight: .semibold),
                                                       alignment: .center),
                                   materials: [UnlitMaterial(color: .darkGray)])
            let tb = text.visualBounds(relativeTo: nil)
            let label = Entity()
            label.name = "label"
            label.position = [0, b.dimensions.y / 2 + 0.12, 0]   // gravity-aligned box: local y is up
            text.position = -tb.center
            label.addChild(text)
            label.components.set(BillboardComponent())
            e.addChild(label)
        }
        return Built(entity: root, size: size)
    }

    // MARK: Realistic furniture (Tier 2)

    /// Bundled model for a RoomPlan object, picked by category, attributes and size.
    /// Files: Resources/DemoData/Furniture/<name>.usdz (Kenney Furniture Kit, CC0).
    static func furnitureModel(for b: RoomModel.Box) -> String {
        let a = Set(b.attributes ?? [])
        switch b.label {
        case "sofa":
            if a.contains("SofaType.lShaped") || a.contains("SofaType.lShapedExtension") { return "sofa_corner" }
            if a.contains("SofaType.singleSeat") { return "sofa_single" }
            return b.dimensions.x > 2.4 ? "sofa_long" : "sofa"
        case "table":
            if a.contains("TableShapeType.circularElliptic") { return "table_round" }
            if a.contains("TableType.coffee") || b.dimensions.y < 0.55 { return "table_coffee" }
            return "table"
        case "chair":
            if a.contains("ChairType.swivel") { return "chair_swivel" }
            if a.contains("ChairType.stool") { return "chair_stool" }
            if a.contains("ChairArmType.existing") { return "chair_arm" }
            return "chair"
        case "storage":
            if a.contains("StorageType.shelf") { return "storage_shelf" }
            if b.dimensions.y < 0.9 { return "storage_low" }
            return a.contains("StorageType.cabinet") ? "storage_cabinet" : "storage"
        default:
            return b.label
        }
    }

    private static var templates: [String: Entity] = [:]

    /// Photoreal Poly Haven (CC0) stand-ins for the low-poly models, used when "Realistic models" is on.
    /// Generated by scripts/polyhaven_to_usdz.py; same facing as Kenney (front -Z). Bathroom, TV, lamp, rug: no CC0 match.
    static let realisticModels: [String: String] = [
        "sofa": "real_sofa_02", "sofa_long": "real_sofa_02",
        "sofa_single": "real_mid_century_lounge_chair", "chair_arm": "real_mid_century_lounge_chair",
        "chair": "real_dining_chair_02",
        "table_coffee": "real_modern_coffee_table_01", "table_round": "real_round_wooden_table_01",
        "sideTable": "real_side_table_01",
        "storage": "real_drawer_cabinet", "storage_cabinet": "real_drawer_cabinet",
        "storage_shelf": "real_steel_frame_shelves_02", "storage_low": "real_modern_wooden_cabinet",
    ]
    static let realisticKey = "realisticFurniture"
    static var realistic: Bool { UserDefaults.standard.object(forKey: realisticKey) as? Bool ?? true }

    /// Bundled furniture template, loaded once and cloned per use.
    static func furnitureTemplate(_ requested: String) async -> Entity? {
        let name = realistic ? realisticModels[requested] ?? requested : requested
        if let t = templates[name] { return t.clone(recursive: true) }
        guard let url = Bundle.main.url(forResource: name, withExtension: "usdz"),
              let t = try? await Entity(contentsOf: url) else { return nil }
        templates[name] = t
        return t.clone(recursive: true)
    }

    /// Swaps each furniture box for a real model stretched to the box (RoomPlan boxes are tight bounds).
    /// Boxes stay as the fallback when a category has no model. Call after `build`; safe to call again.
    static func furnish(_ built: Built, room: RoomModel) async {
        for (i, b) in room.objects.enumerated() {
            guard let box = built.entity.findEntity(named: furniturePrefix + "\(i)") as? ModelEntity,
                  box.findEntity(named: "furniture-model") == nil else { continue }
            // A sink box floating above the floor is a wall-mounted basin (RoomPlan boxes only the basin).
            if b.label == "sink", box.position(relativeTo: built.entity).y - b.dimensions.y / 2 > 0.2 {
                let basin = wallBasin(b.dimensions)
                basin.name = "furniture-model"
                box.addChild(basin)
                box.model = nil
                box.findEntity(named: "label")?.isEnabled = false
                continue
            }
            guard let model = await furnitureTemplate(furnitureModel(for: b)) else { continue }
            let bounds = model.visualBounds(relativeTo: nil)
            guard bounds.extents.min() > 0 else { continue }
            let holder = Entity()
            holder.name = "furniture-model"
            holder.addChild(model)
            model.position = -bounds.center
            // Kenney models face -Z; RoomPlan objects face +Z (back against the wall), verified on a real scan.
            holder.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
            holder.scale = b.dimensions / bounds.extents
            box.addChild(holder)
            box.model = nil                                  // hide the box, keep its transform as the anchor
            box.findEntity(named: "label")?.isEnabled = false // the model speaks for itself
        }
    }

    /// Wall-mounted ceramic basin filling `size` (centered box, back toward -Z / the wall).
    static func wallBasin(_ size: SIMD3<Float>) -> Entity {
        let ceramic = material(.init(white: 0.96, alpha: 1), roughness: 0.25)
        let basin = Entity()
        let body = ModelEntity(mesh: .generateBox(size: size, cornerRadius: min(0.05, size.min() / 3)), materials: [ceramic])
        basin.addChild(body)
        // Recessed bowl: a darker inset slab just under the rim.
        let bowl = ModelEntity(mesh: .generateBox(size: [size.x * 0.78, 0.01, size.z * 0.62], cornerRadius: 0.004),
                               materials: [material(.init(white: 0.82, alpha: 1), roughness: 0.2)])
        bowl.position = [0, size.y / 2 + 0.001, size.z * 0.06]
        basin.addChild(bowl)
        let chrome = material(.init(white: 0.75, alpha: 1), roughness: 0.15)
        let faucet = ModelEntity(mesh: .generateCylinder(height: 0.14, radius: 0.012), materials: [chrome])
        faucet.position = [0, size.y / 2 + 0.07, -size.z / 2 + 0.05]
        basin.addChild(faucet)
        let spout = ModelEntity(mesh: .generateBox(size: [0.022, 0.018, 0.09], cornerRadius: 0.008), materials: [chrome])
        spout.position = [0, size.y / 2 + 0.13, -size.z / 2 + 0.09]
        basin.addChild(spout)
        return basin
    }

    static func color(for category: String) -> UIColor {
        switch category {
        case "sofa": UIColor(red: 0.42, green: 0.55, blue: 0.75, alpha: 1)
        case "chair": UIColor(red: 0.85, green: 0.6, blue: 0.4, alpha: 1)
        case "table": UIColor(red: 0.72, green: 0.58, blue: 0.43, alpha: 1)
        case "bed": UIColor(red: 0.6, green: 0.7, blue: 0.6, alpha: 1)
        case "storage": UIColor(red: 0.78, green: 0.74, blue: 0.68, alpha: 1)
        case "television": UIColor(white: 0.2, alpha: 1)
        default: UIColor(white: 0.75, alpha: 1)
        }
    }

    static func material(_ color: UIColor, roughness: Float = 0.7) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: roughness)
        return m
    }

    /// Stand-in for a scanned object so the full flow works without LiDAR.
    static func demoChair() -> Entity {
        let wood = material(UIColor(red: 0.6, green: 0.42, blue: 0.27, alpha: 1), roughness: 0.5)
        let fabric = material(UIColor(red: 0.85, green: 0.45, blue: 0.3, alpha: 1), roughness: 0.95)
        let chair = Entity()
        func part(_ size: SIMD3<Float>, _ pos: SIMD3<Float>, _ m: PhysicallyBasedMaterial) {
            let e = ModelEntity(mesh: .generateBox(size: size, cornerRadius: 0.01), materials: [m])
            e.position = pos
            chair.addChild(e)
        }
        for x: Float in [-0.2, 0.2] { for z: Float in [-0.2, 0.2] { part([0.04, 0.45, 0.04], [x, 0.225, z], wood) } }
        part([0.48, 0.06, 0.48], [0, 0.47, 0], fabric)
        part([0.48, 0.45, 0.05], [0, 0.72, -0.215], fabric)
        return chair
    }

    /// Placed object: model sits on y = 0, centered. Hit testing is done by DesignerView's own ray math.
    static func placedEntity(for object: ScannedObject, url: URL?) async -> Entity {
        var model: Entity = demoChair()
        if let url {
            do { model = try await Entity(contentsOf: url) }
            catch { print("RoomVibe: failed to load \(url.lastPathComponent): \(error)") }   // falls back to the demo chair
        }
        let b = model.visualBounds(relativeTo: nil)
        model.position -= [b.center.x, b.min.y, b.center.z]
        let container = Entity()
        container.addChild(model)
        return container
    }
}
