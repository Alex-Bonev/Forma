import Foundation
import simd

struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var placements: [Placement] = []
    /// Indices into the room's RoomPlan objects the user hid (false detections, or replaced by a placement).
    var hiddenRoomObjects: [Int]? = nil
    /// Finish.id for walls / floor (nil = default white / light).
    var wallFinish: String? = nil
    var floorFinish: String? = nil
}

struct ScannedObject: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// File name inside Objects/<id>/. nil = built-in procedural demo chair.
    var modelFile: String?
    var boundingBox: SIMD3<Float>
}

struct Placement: Codable, Identifiable, Hashable {
    let id: UUID
    var objectID: UUID
    var position: SIMD3<Float>   // room-local, y = 0 (floor)
    var yRotation: Float         // radians
    /// Set for generic catalog furniture (CatalogItem.id); `objectID` is then `Placement.catalogObjectID`.
    var catalogItem: String? = nil

    static let catalogObjectID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

/// Our own slim copy of RoomPlan output. Lets demo data be hand-written JSON
/// and keeps RoomBuilder independent of RoomPlan (which needs LiDAR).
struct RoomModel: Codable {
    struct Box: Codable {
        var label: String
        var dimensions: SIMD3<Float>   // walls/doors/windows have z = 0
        var columns: [SIMD4<Float>]    // simd_float4x4 columns
        /// RoomPlan object attributes, type-qualified, e.g. "SofaType.lShaped", "ChairArmType.existing". nil for old saves.
        var attributes: [String]? = nil

        var transform: simd_float4x4 { .init(columns[0], columns[1], columns[2], columns[3]) }
    }
    var walls: [Box] = []
    var doors: [Box] = []
    var windows: [Box] = []
    var openings: [Box] = []
    var objects: [Box] = []
    /// Floor polygon in world space (y = floor height), from RoomPlan's floor surface. nil for older saves / demo JSON.
    var floorOutline: [SIMD3<Float>]? = nil
}

extension RoomModel.Box {
    init(label: String, dimensions: SIMD3<Float>, transform t: simd_float4x4) {
        self.init(label: label, dimensions: dimensions, columns: [t.columns.0, t.columns.1, t.columns.2, t.columns.3])
    }
}
