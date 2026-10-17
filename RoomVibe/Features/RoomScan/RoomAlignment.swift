import simd

extension RoomModel {
    /// RoomPlan's world heading is wherever the phone faced when the scan started, so walls are rarely
    /// axis-aligned. Rotate the whole room about Y so the longest wall runs along X: then the axis-aligned
    /// bounds RoomBuilder computes (size label, floor, drag clamp, zoom) match the real room.
    func axisAligned() -> RoomModel {
        guard let longest = walls.max(by: { $0.dimensions.x < $1.dimensions.x }) else { return self }
        let x = longest.columns[0]
        let yaw = atan2(-x.z, x.x)
        let q = simd_quatf(angle: -yaw, axis: [0, 1, 0]), r = simd_float4x4(q)
        func rotate(_ boxes: [Box]) -> [Box] {
            boxes.map { Box(label: $0.label, dimensions: $0.dimensions, transform: r * $0.transform) }
        }
        return RoomModel(walls: rotate(walls), doors: rotate(doors), windows: rotate(windows),
                         openings: rotate(openings), objects: rotate(objects),
                         floorOutline: floorOutline?.map { q.act($0) })
    }
}
