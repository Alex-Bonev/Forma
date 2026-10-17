import RealityKit
import UIKit

/// Soft, rounded furniture built from primitives, for categories whose bundled models are low-poly.
/// Every model exactly fills `size` (centered on the origin, bottom at -size.y/2), front facing +Z.
@MainActor
enum ProceduralFurniture {
    static let keys = ["toilet", "bathtub", "sink", "washerDryer", "refrigerator", "stove", "oven", "dishwasher",
                       "television", "trashcan", "box", "bed", "stairs", "fireplace", "lamp", "rug", "plant",
                       "bench", "desk", "tv_console"]

    /// Soft, rounded model exactly filling `size` (meters), centered, front +Z. nil = no procedural model for key.
    static func model(for key: String, size: SIMD3<Float>) -> Entity? {
        let build: (Entity, Float, Float, Float) -> Void
        switch key {
        case "toilet": build = toilet
        case "bathtub": build = bathtub
        case "sink": build = vanity
        case "washerDryer": build = washer
        case "refrigerator": build = refrigerator
        case "stove": build = stove
        case "oven": build = oven
        case "dishwasher": build = dishwasher
        case "television": build = television
        case "trashcan": build = trashcan
        case "box": build = cardboardBox
        case "bed": build = bed
        case "stairs": build = stairs
        case "fireplace": build = fireplace
        case "lamp": build = lamp
        case "rug": build = rug
        case "plant": build = plant
        case "bench": build = bench
        case "desk": build = desk
        case "tv_console": build = tvConsole
        default: return nil
        }
        let e = Entity()
        build(e, size.x, size.y, size.z)
        return e
    }

    // MARK: Materials

    private static let ceramic = RoomBuilder.material(.init(white: 0.96, alpha: 1), roughness: 0.2)
    private static let ceramicShade = RoomBuilder.material(.init(white: 0.84, alpha: 1), roughness: 0.2)
    private static let chrome = RoomBuilder.material(.init(white: 0.78, alpha: 1), roughness: 0.15)
    private static let steel = RoomBuilder.material(.init(red: 0.8, green: 0.81, blue: 0.82, alpha: 1), roughness: 0.3)
    private static let applianceWhite = RoomBuilder.material(.init(white: 0.94, alpha: 1), roughness: 0.35)
    private static let glass = RoomBuilder.material(.init(white: 0.1, alpha: 1), roughness: 0.1)
    private static let charcoal = RoomBuilder.material(.init(white: 0.25, alpha: 1), roughness: 0.5)
    private static let oak = RoomBuilder.material(.init(red: 0.74, green: 0.58, blue: 0.42, alpha: 1), roughness: 0.6)
    private static let walnut = RoomBuilder.material(.init(red: 0.48, green: 0.34, blue: 0.24, alpha: 1), roughness: 0.55)
    private static let linen = RoomBuilder.material(.init(red: 0.93, green: 0.91, blue: 0.87, alpha: 1), roughness: 0.95)
    private static let blueFabric = RoomBuilder.material(.init(red: 0.56, green: 0.64, blue: 0.72, alpha: 1), roughness: 0.95)
    private static let wool = RoomBuilder.material(.init(red: 0.8, green: 0.72, blue: 0.62, alpha: 1), roughness: 1)
    private static let stone = RoomBuilder.material(.init(red: 0.9, green: 0.88, blue: 0.85, alpha: 1), roughness: 0.8)
    private static let leaf = RoomBuilder.material(.init(red: 0.36, green: 0.55, blue: 0.34, alpha: 1), roughness: 0.8)
    private static let leafLight = RoomBuilder.material(.init(red: 0.46, green: 0.64, blue: 0.4, alpha: 1), roughness: 0.8)
    private static let terracotta = RoomBuilder.material(.init(red: 0.78, green: 0.5, blue: 0.36, alpha: 1), roughness: 0.85)
    private static let cardboard = RoomBuilder.material(.init(red: 0.78, green: 0.63, blue: 0.45, alpha: 1), roughness: 0.9)
    private static let ember: UnlitMaterial = UnlitMaterial(color: .init(red: 1, green: 0.55, blue: 0.2, alpha: 1))

    // MARK: Parts

    private enum Axis { case x, y, z }
    private static let unitCylinder = MeshResource.generateCylinder(height: 1, radius: 0.5)
    private static let unitSphere = MeshResource.generateSphere(radius: 0.5)

    /// Rounded box of extents `s` centered at `p`.
    private static func box(_ e: Entity, _ s: SIMD3<Float>, _ p: SIMD3<Float>, _ m: any Material, radius: Float? = nil) {
        add(e, .generateBox(size: s, cornerRadius: radius ?? min(0.06, s.min() / 4)), m, p)
    }

    /// Cylinder (elliptic if needed) with world extents `s`, its axis along `axis`.
    private static func cylinder(_ e: Entity, _ s: SIMD3<Float>, _ p: SIMD3<Float>, _ m: any Material, axis: Axis = .y) {
        switch axis {
        case .y: add(e, unitCylinder, m, p, scale: s)
        case .z: add(e, unitCylinder, m, p, scale: [s.x, s.z, s.y], rotation: .init(angle: .pi / 2, axis: [1, 0, 0]))
        case .x: add(e, unitCylinder, m, p, scale: [s.y, s.x, s.z], rotation: .init(angle: .pi / 2, axis: [0, 0, 1]))
        }
    }

    /// Ellipsoid with extents `s`.
    private static func sphere(_ e: Entity, _ s: SIMD3<Float>, _ p: SIMD3<Float>, _ m: any Material) {
        add(e, unitSphere, m, p, scale: s)
    }

    private static func add(_ e: Entity, _ mesh: MeshResource, _ m: any Material, _ p: SIMD3<Float>,
                            scale: SIMD3<Float> = .one, rotation: simd_quatf = .init(ix: 0, iy: 0, iz: 0, r: 1)) {
        let part = ModelEntity(mesh: mesh, materials: [m])
        part.transform = Transform(scale: scale, rotation: rotation, translation: p)
        e.addChild(part)
    }

    // MARK: Bathroom

    /// Tank on the back 30% of depth (upper part), rounded bowl and seat in front, on a pedestal.
    private static func toilet(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        // Overlapping rounded solids: base joins the tank, seat sits flush on the bowl. Nothing floats or pokes through.
        let floor = -h / 2, seat = floor + h * 0.56
        let tankD = d * 0.3, tankFront = -d / 2 + tankD
        let tankBottom = seat - h * 0.14
        box(e, [w, h / 2 - tankBottom, tankD], [0, (tankBottom + h / 2) / 2, -d / 2 + tankD / 2], ceramic,
            radius: min(0.05, tankD / 3))
        let baseBack = tankFront - d * 0.04, baseFront = d * 0.32, baseTop = seat - h * 0.1
        box(e, [w * 0.5, baseTop - floor, baseFront - baseBack], [0, (floor + baseTop) / 2, (baseBack + baseFront) / 2],
            ceramic, radius: min(0.06, w * 0.12))
        let bowlBack = tankFront - d * 0.02, bowlFront = d / 2
        let bowlH = h * 0.16, bowlZ = (bowlBack + bowlFront) / 2, bowlD = bowlFront - bowlBack
        box(e, [w * 0.9, bowlH, bowlD], [0, seat - h * 0.02 - bowlH / 2, bowlZ], ceramic, radius: min(0.07, bowlH / 2.2))
        box(e, [w * 0.92, h * 0.035, bowlD * 0.98], [0, seat, bowlZ], ceramic, radius: min(0.04, h * 0.017))
        cylinder(e, [w * 0.12, h * 0.02, w * 0.12], [0, h / 2 + h * 0.005, -d / 2 + tankD / 2], chrome)
    }

    /// Ceramic shell with a recessed tub and a faucet on the left end.
    private static func bathtub(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let rim = min(w, d) * 0.1, shellH = h * 0.88, top = -h / 2 + shellH, fx = -w / 2 + rim / 2
        box(e, [w, shellH, d], [0, top - shellH / 2, 0], ceramic, radius: min(0.1, min(w, shellH, d) / 4))
        box(e, [w - 2 * rim, 0.01, d - 2 * rim], [rim * 0.3, top - 0.002, 0], ceramicShade, radius: min(0.12, d / 5))
        cylinder(e, [0.03, h - shellH, 0.03], [fx, h / 2 - (h - shellH) / 2, 0], chrome)
        box(e, [0.12, 0.025, 0.03], [fx + 0.05, h / 2 - 0.0125, 0], chrome, radius: 0.01)
    }

    /// Floor-standing vanity: two-door cabinet, ceramic top with basin, faucet at the back.
    private static func vanity(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let cabH = h * 0.78, topH = h * 0.08, topY = -h / 2 + cabH + topH / 2, ft = min(0.02, d * 0.05)
        box(e, [w * 0.97, cabH, d * 0.94 - ft], [0, -h / 2 + cabH / 2, -d * 0.03 - ft / 2], oak)
        for s: Float in [-1, 1] {
            box(e, [w * 0.45, cabH * 0.86, ft], [s * w * 0.24, -h / 2 + cabH * 0.5, d * 0.44 - ft / 2], linen)
            cylinder(e, [0.018, 0.12, 0.018], [s * w * 0.04, -h / 2 + cabH * 0.75, d * 0.44 + 0.01], chrome)
        }
        box(e, [w, topH, d], [0, topY, 0], ceramic)
        box(e, [w * 0.55, 0.01, d * 0.5], [0, topY + topH / 2 - 0.003, d * 0.06], ceramicShade, radius: min(0.08, d / 6))
        let faucetH = h - cabH - topH
        cylinder(e, [0.03, faucetH, 0.03], [0, h / 2 - faucetH / 2, -d * 0.36], chrome)
        box(e, [0.03, 0.025, d * 0.18], [0, h / 2 - 0.0125, -d * 0.28], chrome, radius: 0.01)
    }

    // MARK: Appliances

    /// Front loader: white body, porthole door, control strip.
    private static func washer(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let ft = min(0.02, d * 0.05), r = min(w, h) * 0.32
        box(e, [w, h, d - ft], [0, 0, -ft / 2], applianceWhite)
        box(e, [w * 0.92, h * 0.12, ft], [0, h * 0.38, d / 2 - ft / 2], RoomBuilder.material(.init(white: 0.88, alpha: 1), roughness: 0.35))
        cylinder(e, [w * 0.12, w * 0.12, ft * 1.5], [w * 0.3, h * 0.38, d / 2 - ft / 2], chrome, axis: .z)
        cylinder(e, [2 * r, 2 * r, ft], [0, -h * 0.06, d / 2 - ft / 2], chrome, axis: .z)
        cylinder(e, [1.6 * r, 1.6 * r, ft * 1.2], [0, -h * 0.06, d / 2 - ft * 0.4], glass, axis: .z)
    }

    /// Stainless two-door fridge (freezer on top) with vertical handles.
    private static func refrigerator(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let ft = min(0.03, d * 0.06), hz = d / 2 - ft - 0.012
        box(e, [w, h, d - ft - 0.025], [0, 0, -(ft + 0.025) / 2], steel)
        box(e, [w * 0.98, h * 0.31, ft], [0, h * 0.34, hz - ft / 2 + 0.012], steel)
        box(e, [w * 0.98, h * 0.66, ft], [0, -h * 0.165, hz - ft / 2 + 0.012], steel)
        box(e, [0.025, h * 0.18, 0.025], [w * 0.38, h * 0.3, d / 2 - 0.0125], chrome, radius: 0.01)
        box(e, [0.025, h * 0.36, 0.025], [w * 0.38, h * 0.05, d / 2 - 0.0125], chrome, radius: 0.01)
    }

    /// Range: body, glass cooktop with four burners, oven window, handle, back guard with knobs.
    private static func stove(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let guardD = min(0.06, d * 0.1), topY = h * 0.38, bz = guardD / 2
        box(e, [w, h * 0.88, d - guardD - 0.01], [0, -h * 0.06, bz - 0.005], steel)
        box(e, [w * 0.96, 0.012, (d - guardD) * 0.92], [0, topY, bz], glass, radius: 0.005)
        for x: Float in [-0.24, 0.24] { for z: Float in [-0.2, 0.2] {
            cylinder(e, [w * 0.24, 0.006, w * 0.24], [x * w, topY + 0.008, bz + z * (d - guardD)], charcoal)
        } }
        box(e, [w * 0.8, h * 0.36, 0.012], [0, -h * 0.12, d / 2 - 0.006], glass, radius: 0.02)
        box(e, [w * 0.7, 0.025, 0.03], [0, h * 0.14, d / 2 - 0.015], chrome, radius: 0.01)
        box(e, [w, h * 0.12, guardD], [0, h * 0.44, -d / 2 + guardD / 2], steel)
    }

    /// Built-in oven: stainless box, glass door, handle, control strip.
    private static func oven(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let ft = min(0.02, d * 0.05)
        box(e, [w, h, d - ft], [0, 0, -ft / 2], steel)
        box(e, [w * 0.92, h * 0.14, ft], [0, h * 0.4, d / 2 - ft / 2], glass, radius: 0.01)
        box(e, [w * 0.78, h * 0.48, ft], [0, -h * 0.1, d / 2 - ft / 2], glass, radius: 0.03)
        box(e, [w * 0.7, 0.025, ft], [0, h * 0.24, d / 2 - ft / 2], chrome, radius: 0.008)
    }

    /// Stainless panel with a top handle bar and control strip.
    private static func dishwasher(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let ft = min(0.02, d * 0.05)
        box(e, [w, h, d - ft], [0, 0, -ft / 2], steel)
        box(e, [w * 0.96, h * 0.82, ft], [0, -h * 0.07, d / 2 - ft / 2], steel)
        box(e, [w * 0.96, h * 0.08, ft * 0.6], [0, h * 0.44, d / 2 - ft * 0.7], charcoal, radius: 0.008)
        box(e, [w * 0.6, 0.022, ft], [0, h * 0.28, d / 2 - ft / 2], chrome, radius: 0.008)
    }

    // MARK: Living

    /// Thin panel on a small pedestal stand.
    private static func television(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let panelH = h * 0.86, panelD = min(0.04, d * 0.3), py = h / 2 - panelH / 2
        box(e, [w, panelH, panelD], [0, py, 0], charcoal, radius: 0.012)
        box(e, [w * 0.97, panelH * 0.95, 0.002], [0, py, panelD / 2], glass, radius: 0.006)
        box(e, [min(0.08, w * 0.08), h - panelH + 0.02, panelD * 0.8], [0, -h / 2 + (h - panelH) / 2 + 0.01, -panelD * 0.2], charcoal, radius: 0.01)
        box(e, [w * 0.35, 0.02, d], [0, -h / 2 + 0.01, 0], charcoal, radius: 0.009)
    }

    /// Low media cabinet on short legs, two or three doors.
    private static func tvConsole(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let legH = h * 0.18, bodyH = h - legH, ft = min(0.02, d * 0.05), by = h / 2 - bodyH / 2
        box(e, [w, bodyH, d - ft], [0, by, -ft / 2], walnut)
        let n = w > 1.4 ? 3 : 2, dw = w * 0.96 / Float(n)
        for i in 0..<n {
            let x = -w * 0.48 + dw * (Float(i) + 0.5)
            box(e, [dw - 0.01, bodyH * 0.84, ft], [x, by, d / 2 - ft / 2], oak)
        }
        for x: Float in [-0.44, 0.44] { for z: Float in [-0.35, 0.35] {
            cylinder(e, [0.035, legH, 0.035], [x * w, -h / 2 + legH / 2, z * d], walnut)
        } }
    }

    /// Wooden frame with a headboard against the wall, mattress, duvet and two pillows.
    private static func bed(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let headD = min(0.08, d * 0.05), frameH = h * 0.25, mattH = h * 0.22, mz = headD / 2
        box(e, [w, h, headD], [0, 0, -d / 2 + headD / 2], walnut)
        box(e, [w, frameH, d - headD], [0, -h / 2 + frameH / 2, mz], walnut)
        let mattY = -h / 2 + frameH + mattH / 2
        box(e, [w * 0.95, mattH, (d - headD) * 0.97], [0, mattY, mz], linen, radius: min(0.08, mattH / 3))
        box(e, [w * 0.97, mattH * 0.35, (d - headD) * 0.66], [0, mattY + mattH * 0.38, d / 2 - (d - headD) * 0.34], blueFabric,
            radius: min(0.05, mattH * 0.15))
        for s: Float in [-1, 1] {
            sphere(e, [w * 0.4, h * 0.12, d * 0.17], [s * w * 0.23, mattY + mattH / 2 + h * 0.04, -d / 2 + headD + d * 0.11], linen)
        }
    }

    /// Straight flight rising toward the back (-Z), one rounded block per step.
    private static func stairs(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let n = min(12, max(3, Int((h / 0.18).rounded()))), step = h / Float(n), run = d / Float(n)
        for i in 0..<n {
            let sh = step * Float(i + 1)
            box(e, [w, sh, run], [0, -h / 2 + sh / 2, d / 2 - run * (Float(i) + 0.5)], i.isMultiple(of: 2) ? oak : walnut,
                radius: min(0.03, run / 4, step / 4))
        }
    }

    /// Stone surround with a wooden mantel and a glowing firebox.
    private static func fireplace(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let mantelH = h * 0.08, bodyH = h - mantelH
        box(e, [w * 0.92, bodyH, d * 0.9], [0, -h / 2 + bodyH / 2, -d * 0.05], stone)
        box(e, [w, mantelH, d], [0, h / 2 - mantelH / 2, 0], walnut)
        let fbW = w * 0.55, fbH = bodyH * 0.55, fbY = -h / 2 + fbH / 2 + bodyH * 0.06
        box(e, [fbW, fbH, 0.01], [0, fbY, d * 0.4], glass, radius: min(0.05, fbW / 6))
        box(e, [fbW * 0.6, fbH * 0.1, 0.008], [0, fbY - fbH * 0.3, d * 0.408], ember, radius: 0.01)
        for s: Float in [-1, 1] {
            cylinder(e, [fbW * 0.38, fbH * 0.11, fbH * 0.11], [s * fbW * 0.14, fbY - fbH * 0.36, d * 0.41], walnut, axis: .x)
        }
    }

    /// Floor lamp: round base, thin pole, fabric drum shade.
    private static func lamp(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let shadeH = min(h * 0.25, 0.35)
        cylinder(e, [w * 0.6, 0.03, d * 0.6], [0, -h / 2 + 0.015, 0], charcoal)
        cylinder(e, [0.025, h - shadeH, 0.025], [0, -h / 2 + (h - shadeH) / 2, 0], charcoal)
        cylinder(e, [w, shadeH, d], [0, h / 2 - shadeH / 2, 0], linen)
    }

    /// Very thin slab with soft plan-view corners and an inset border.
    private static func rug(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let r = min(0.15, min(w, d) / 6), inset: Float = min(0.06, min(w, d) / 10)
        box(e, [w - r, h, d - r], .zero, wool, radius: h / 3)   // edge thickness; corners stay inside the rounded top
        add(e, .generatePlane(width: w, depth: d, cornerRadius: r), wool, [0, h / 2 + 0.0005, 0])
        add(e, .generatePlane(width: w - 2 * inset, depth: d - 2 * inset, cornerRadius: max(r - inset, 0.01)),
            RoomBuilder.material(.init(red: 0.88, green: 0.83, blue: 0.75, alpha: 1), roughness: 1), [0, h / 2 + 0.001, 0])
    }

    /// Terracotta pot with a cluster of rounded foliage.
    private static func plant(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let potH = h * 0.3, potY = -h / 2 + potH / 2
        cylinder(e, [w * 0.5, potH, d * 0.5], [0, potY, 0], terracotta)
        cylinder(e, [w * 0.56, potH * 0.14, d * 0.56], [0, potY + potH * 0.43, 0], terracotta)
        let fy = -h / 2 + potH, fh = h - potH
        sphere(e, [w * 0.8, fh * 0.6, d * 0.8], [0, fy + fh * 0.34, 0], leaf)
        sphere(e, [w * 0.55, fh * 0.48, d * 0.55], [-w * 0.2, fy + fh * 0.48, d * 0.1], leafLight)
        sphere(e, [w * 0.5, fh * 0.45, d * 0.5], [w * 0.22, fy + fh * 0.52, -d * 0.12], leaf)
        sphere(e, [w * 0.45, fh * 0.42, d * 0.45], [0, fy + fh * 0.79, 0], leafLight)
    }

    /// Wooden seat on two panel legs, with a fabric cushion.
    private static func bench(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let seatH = h * 0.12, cushH = h * 0.12, seatY = h / 2 - cushH - seatH / 2, legH = h - cushH - seatH
        box(e, [w, seatH, d], [0, seatY, 0], oak)
        box(e, [w * 0.96, cushH, d * 0.94], [0, h / 2 - cushH / 2, 0], blueFabric, radius: min(0.04, cushH / 2.5))
        for s: Float in [-1, 1] {
            box(e, [min(0.06, w * 0.06), legH, d * 0.85], [s * w * 0.42, -h / 2 + legH / 2, 0], oak)
        }
    }

    /// Wooden top on four legs with a drawer unit on the right.
    private static func desk(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let topH = min(0.04, h * 0.06), legH = h - topH
        box(e, [w, topH, d], [0, h / 2 - topH / 2, 0], oak)
        for x: Float in [-0.46, 0.46] { for z: Float in [-0.42, 0.42] {
            box(e, [0.04, legH, 0.04], [x * w, -h / 2 + legH / 2, z * d], walnut, radius: 0.015)
        } }
        let drW = min(0.4, w * 0.3), drH = h * 0.14, drY = h / 2 - topH - drH / 2
        box(e, [drW, drH, d * 0.85], [w * 0.46 - drW / 2 - 0.02, drY, 0], oak)
        box(e, [drW * 0.4, 0.015, 0.015], [w * 0.46 - drW / 2 - 0.02, drY, d * 0.425], chrome, radius: 0.006)
    }

    // MARK: Misc

    /// Brushed metal bin with a slightly wider lid.
    private static func trashcan(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        let lidH = h * 0.1
        cylinder(e, [w * 0.96, h - lidH, d * 0.96], [0, -lidH / 2, 0], steel)
        sphere(e, [w, lidH * 2, d], [0, h / 2 - lidH, 0], steel)
        cylinder(e, [w * 0.96, 0.012, d * 0.96], [0, h / 2 - lidH - 0.006, 0], charcoal)
    }

    /// Cardboard box with a tape strip across the top.
    private static func cardboardBox(_ e: Entity, _ w: Float, _ h: Float, _ d: Float) {
        box(e, [w, h - 0.004, d], [0, -0.002, 0], cardboard, radius: min(0.03, min(w, h, d) / 4))
        box(e, [w * 0.15, 0.006, d * 0.99], [0, h / 2 - 0.003, 0], RoomBuilder.material(.init(red: 0.86, green: 0.76, blue: 0.6, alpha: 1), roughness: 0.6), radius: 0.002)
    }
}
