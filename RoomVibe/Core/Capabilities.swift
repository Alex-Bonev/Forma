import RoomPlan
import RealityKit
import SwiftUI // ObjectCaptureSession lives in RealityKit's SwiftUI overlay

/// LiDAR-only features. False in Simulator and on non-Pro iPhones -> app falls back to demo data.
@MainActor
enum Capabilities {
    static var canScanRoom: Bool { RoomCaptureSession.isSupported }
    static var canScanObject: Bool { ObjectCaptureSession.isSupported }
}
