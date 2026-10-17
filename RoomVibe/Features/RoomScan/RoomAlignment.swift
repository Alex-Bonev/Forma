import simd

extension RoomModel {
    static let markedLabel = "marked item"

    /// Boxes for points the user marked during the scan: 35 cm square, from the floor up to the tapped point.
    static func markedItems(_ points: [SIMD3<Float>], walls: [Box]) -> [Box] {
        guard !points.isEmpty else { return [] }
        let floorY = walls.map { $0.columns[3].y - $0.dimensions.y / 2 }.min() ?? (points.map(\.y).min() ?? 0)
        return points.map { p in
            let h = max(p.y - floorY, 0.15)
            var t = matrix_identity_float4x4
            t.columns.3 = [p.x, floorY + h / 2, p.z, 1]
            return Box(label: markedLabel, dimensions: [0.35, h, 0.35], transform: t)
        }
    }

    /// RoomPlan's world heading is wherever the phone faced when the scan started, so walls are rarely
    /// axis-aligned. Rotate the whole room about Y so the longest wall runs along X: then the axis-aligned
    /// bounds RoomBuilder computes (size label, floor, drag clamp, zoom) match the real room.
    func axisAligned() -> RoomModel {
        guard let longest = walls.max(by: { $0.dimensions.x < $1.dimensions.x }) else { return self }
        let x = longest.columns[0]
        let yaw = atan2(-x.z, x.x)
        let q = simd_quatf(angle: -yaw, axis: [0, 1, 0]), r = simd_float4x4(q)
        func rotate(_ boxes: [Box]) -> [Box] {
            boxes.map { b in
                var b = b
                let t = r * b.transform
                b.columns = [t.columns.0, t.columns.1, t.columns.2, t.columns.3]
                return b
            }
        }
        return RoomModel(walls: rotate(walls), doors: rotate(doors), windows: rotate(windows),
                         openings: rotate(openings), objects: rotate(objects),
                         floorOutline: floorOutline?.map { q.act($0) })
    }
}
