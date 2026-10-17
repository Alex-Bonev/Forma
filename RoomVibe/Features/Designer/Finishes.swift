import RealityKit
import UIKit
import Metal

/// Wall and floor finishes (showcase). Textures: Poly Haven, CC0 (Resources/DemoData/Finishes/finish_*.jpg).
/// `tile` = meters covered by one repeat of the texture, so materials tile at real-world scale on any wall size.
struct Finish: Identifiable, Hashable {
    let id: String
    let name: String
    var texture: String? = nil
    var color: UIColor = .white
    var tile: Float = 1
    var roughness: Float = 0.85

    static let walls: [Finish] = [
        .init(id: "white", name: "White", color: .init(white: 0.97, alpha: 1)),
        .init(id: "plaster", name: "Warm Plaster", texture: "finish_painted_plaster_wall", tile: 2),
        .init(id: "beige", name: "Beige", texture: "finish_beige_wall_001", tile: 1.5),
        .init(id: "brick", name: "Brick", texture: "finish_red_brick_03", tile: 1.6),
        .init(id: "sage", name: "Sage", color: .init(red: 0.66, green: 0.74, blue: 0.65, alpha: 1)),
        .init(id: "navy", name: "Navy", color: .init(red: 0.2, green: 0.27, blue: 0.4, alpha: 1)),
    ]

    static let floors: [Finish] = [
        .init(id: "light", name: "Light", color: .init(white: 0.93, alpha: 1), roughness: 0.9),
        .init(id: "oak", name: "Oak", texture: "finish_wood_floor", tile: 2, roughness: 0.6),
        .init(id: "planks", name: "Planks", texture: "finish_plank_flooring_04", tile: 2, roughness: 0.65),
        .init(id: "marble", name: "Marble", texture: "finish_marble_01", tile: 1.2, roughness: 0.3),
        .init(id: "concrete", name: "Concrete", texture: "finish_concrete_floor_02", tile: 2.5),
    ]

    static func wall(_ id: String?) -> Finish {
        if let id, id.hasPrefix(paintPrefix), let c = UIColor(hex: String(id.dropFirst(paintPrefix.count))) {
            return Finish(id: id, name: "Matched Paint", color: c)
        }
        return walls.first { $0.id == id } ?? walls[0]
    }

    /// Custom paint (e.g. sampled from room photos), stored in Project.wallFinish as "paint:#RRGGBB".
    static let paintPrefix = "paint:"
    static func paintID(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return paintPrefix + String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
    static func floor(_ id: String?) -> Finish { floors.first { $0.id == id } ?? floors[0] }

    private static var textures: [String: TextureResource] = [:]

    /// Material for a surface of `size` meters (texture repeats every `tile` meters).
    @MainActor
    func material(size: SIMD2<Float>) async -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.roughness = .init(floatLiteral: roughness)
        m.baseColor = .init(tint: color)
        if let texture, let resource = Self.load(texture) {
            let s = MTLSamplerDescriptor()
            s.sAddressMode = .repeat
            s.tAddressMode = .repeat
            s.minFilter = .linear
            s.magFilter = .linear
            s.mipFilter = .linear
            m.baseColor = .init(tint: color, texture: .init(resource, sampler: .init(s)))
            m.textureCoordinateTransform = .init(scale: simd_max(size / tile, [0.05, 0.05]))
        }
        return m
    }

    /// Synchronous on purpose: textures from the async `TextureResource(contentsOf:)` crashed RealityKit's material
    /// system (EXC_BAD_ACCESS in MaterialParameterBlockArray, device + Simulator, iOS 26). ~1k JPEGs, cached.
    @MainActor
    private static func load(_ name: String) -> TextureResource? {
        if let t = textures[name] { return t }
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let t = try? TextureResource.load(contentsOf: url, options: .init(semantic: .color)) else { return nil }
        textures[name] = t
        return t
    }

    /// Re-skins walls and floor of a built room. Doors/windows keep their colors.
    @MainActor
    static func apply(to room: Entity, wall: Finish, floor: Finish) async {
        var targets: [(ModelEntity, Finish, SIMD2<Float>)] = []
        func visit(_ e: Entity) {
            if let m = e as? ModelEntity {
                let ext = m.visualBounds(relativeTo: m).extents
                if m.name == RoomBuilder.wallName { targets.append((m, wall, [ext.x, ext.y])) }
                if m.name == RoomBuilder.floorName { targets.append((m, floor, [ext.x, ext.z])) }
            }
            e.children.forEach(visit)
        }
        visit(room)
        for (m, finish, size) in targets { m.model?.materials = [await finish.material(size: size)] }
    }
}

extension UIColor {
    /// "#RRGGBB"
    convenience init?(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
