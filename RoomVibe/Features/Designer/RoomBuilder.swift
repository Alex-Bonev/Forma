import RealityKit
import UIKit

/// RoomModel -> RealityKit "dollhouse". Output is centered on the room with the floor at y = 0,
/// so placements can live in plain scene coordinates.
@MainActor
enum RoomBuilder {
    struct Built { let entity: Entity; let size: SIMD2<Float> }

    static let wallThickness: Float = 0.08
    static let surfaceName = "surface"

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
        content.addChild(floor)

        func addSurface(_ b: RoomModel.Box, depth: Float, color: UIColor) {
            let h = b.dimensions.y * wallScale
            let e = ModelEntity(mesh: .generateBox(size: [b.dimensions.x, h, depth]), materials: [material(color)])
            e.transform = Transform(matrix: b.transform)
            // Shrink from the floor up, not around the center.
            e.position.y = lo.y + (e.position.y - lo.y - b.dimensions.y / 2) * wallScale + h / 2
            e.name = surfaceName   // walls/doors/windows: faded by DesignerView when between camera and room
            content.addChild(e)
        }
        room.walls.forEach { addSurface($0, depth: wallThickness, color: .init(white: 0.97, alpha: 1)) }
        room.doors.forEach { addSurface($0, depth: wallThickness + 0.02, color: .init(red: 0.55, green: 0.42, blue: 0.3, alpha: 1)) }
        room.windows.forEach { addSurface($0, depth: wallThickness + 0.02, color: .init(red: 0.62, green: 0.8, blue: 0.95, alpha: 1)) }

        for b in room.objects {
            let e = ModelEntity(mesh: .generateBox(size: b.dimensions, cornerRadius: min(0.04, b.dimensions.min() / 4)),
                                materials: [material(color(for: b.label))])
            e.transform = Transform(matrix: b.transform)
            content.addChild(e)

            let text = ModelEntity(mesh: .generateText(b.label.capitalized, extrusionDepth: 0.002,
                                                       font: .systemFont(ofSize: 0.08, weight: .semibold),
                                                       alignment: .center),
                                   materials: [UnlitMaterial(color: .darkGray)])
            let tb = text.visualBounds(relativeTo: nil)
            let label = Entity()
            label.position = e.position + [0, b.dimensions.y / 2 + 0.12, 0]
            text.position = -tb.center
            label.addChild(text)
            label.components.set(BillboardComponent())
            content.addChild(label)
        }
        return Built(entity: root, size: size)
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
        if let url, let loaded = try? await Entity(contentsOf: url) { model = loaded }
        let b = model.visualBounds(relativeTo: nil)
        model.position -= [b.center.x, b.min.y, b.center.z]
        let container = Entity()
        container.addChild(model)
        return container
    }
}
