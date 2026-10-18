import Foundation
import Observation
import RealityKit

/// Single source of truth. Index lives in library.json; heavy files in per-item folders:
///   Application Support/Projects/<id>/room.json (+ captured.json, room.usdz)
///   Application Support/Objects/<id>/model.usdz
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    private(set) var objects: [ScannedObject] = []

    static let root = URL.applicationSupportDirectory
    private static let indexURL = root.appending(path: "library.json")

    private struct Library: Codable { var projects: [Project]; var objects: [ScannedObject] }

    init() {
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        guard let lib = try? JSONDecoder().decode(Library.self, from: data) else {
            // Keep the unreadable index for recovery instead of overwriting it on the next save.
            try? FileManager.default.moveItem(at: Self.indexURL, to: Self.root.appending(path: "library.json.bad"))
            return
        }
        projects = lib.projects
        objects = lib.objects
        removeIncompleteScans()
    }

    /// Folders left by scans killed mid-capture: not in the index AND missing their main file.
    /// A complete room/object missing from the index is kept, never deleted.
    private func removeIncompleteScans() {
        let known = Set(projects.map(\.id.uuidString) + objects.map(\.id.uuidString))
        let fm = FileManager.default
        for (parent, mainFile) in [("Projects", "room.json"), ("Objects", "model.usdz")] {
            let url = Self.root.appending(path: parent)
            for name in (try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
            where !known.contains(name) && !fm.fileExists(atPath: url.appending(path: "\(name)/\(mainFile)").path(percentEncoded: false)) {
                try? fm.removeItem(at: url.appending(path: name))
            }
        }
    }

    static func projectDir(_ id: UUID) -> URL { root.appending(path: "Projects/\(id)") }
    static func objectDir(_ id: UUID) -> URL { root.appending(path: "Objects/\(id)") }

    func room(for project: Project) -> RoomModel? {
        guard let data = try? Data(contentsOf: Self.projectDir(project.id).appending(path: "room.json")) else { return nil }
        return try? JSONDecoder().decode(RoomModel.self, from: data)
    }

    func modelURL(for object: ScannedObject) -> URL? {
        object.modelFile.map { Self.objectDir(object.id).appending(path: $0) }
    }

    @discardableResult
    func addRoom(name: String, model: RoomModel, extraFiles: (URL) throws -> Void = { _ in }) throws -> Project {
        let project = Project(id: UUID(), name: name, createdAt: .now)
        let dir = Self.projectDir(project.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try JSONEncoder().encode(model).write(to: dir.appending(path: "room.json"))
            try extraFiles(dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)   // no orphan folder outside the index
            throw error
        }
        projects.insert(project, at: 0)
        try persist()
        return project
    }

    func addObject(_ object: ScannedObject) throws {
        objects.insert(object, at: 0)
        try persist()
    }

    /// Saves a downloaded model (SAM 3D, via /vibe/model3d) to Objects/<id>/ and measures it, without adding it to the
    /// library. Pass the result to `addObject` once it is used, or to `discardModel`. Leaves no files behind on failure.
    @MainActor
    func saveModel(usdz: Data, name: String) async throws -> ScannedObject {
        let id = UUID()
        let dir = Self.objectDir(id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: ObjectScanModel.modelName)
            try usdz.write(to: url)
            // Loaded directly: RoomBuilder.placedEntity falls back to the demo chair on a bad file. The extents are
            // axis-aligned in the file's frame; the backend writes Y-up USDZ, like RealityKit.
            let size = try await Entity(contentsOf: url).visualBounds(relativeTo: nil).extents
            guard size.min() > 0 else { throw CocoaError(.fileReadCorruptFile) }
            return ScannedObject(id: id, name: name, modelFile: ObjectScanModel.modelName, boundingBox: size)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Deletes the files of a `saveModel` result that never made it into the library.
    func discardModel(_ object: ScannedObject) {
        try? FileManager.default.removeItem(at: Self.objectDir(object.id))
    }

    func update(_ project: Project) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i] = project
        try? persist()
    }

    func rename(_ object: ScannedObject, to name: String) {
        guard let i = objects.firstIndex(where: { $0.id == object.id }) else { return }
        objects[i].name = name
        try? persist()
    }

    func delete(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        try? FileManager.default.removeItem(at: Self.projectDir(project.id))
        try? persist()
    }

    func delete(_ object: ScannedObject) {
        objects.removeAll { $0.id == object.id }
        try? FileManager.default.removeItem(at: Self.objectDir(object.id))
        try? persist()
    }

    /// Bundled fallback: sample room + sample chair. Works on any device, including Simulator.
    /// The chair is the bundled scan (sample_chair.usdz, see scripts/pull_demo_assets.py) or, if absent, a procedural one.
    static let dormName = "UCLA dorm"

    /// Adds the bundled UCLA dorm scan (room, scan photos, finishes) unless a room with that name exists.
    /// Files: Resources/DemoData/UCLADorm/dorm_room.json, dorm_photos.json, dorm_photo_NNN.jpg (bundle is flat).
    func addBundledDorm() throws {
        guard !projects.contains(where: { $0.name.caseInsensitiveCompare(Self.dormName) == .orderedSame }),
              let url = Bundle.main.url(forResource: "dorm_room", withExtension: "json") else { return }
        let model = try JSONDecoder().decode(RoomModel.self, from: Data(contentsOf: url))
        var project = try addRoom(name: Self.dormName, model: model) { dir in
            let photos = dir.appending(path: "photos")
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            if let thumb = Bundle.main.url(forResource: "dorm_thumb", withExtension: "jpg") {
                try FileManager.default.copyItem(at: thumb, to: dir.appending(path: "thumb.jpg"))   // until first open
            }
            if let index = Bundle.main.url(forResource: "dorm_photos", withExtension: "json") {
                try FileManager.default.copyItem(at: index, to: photos.appending(path: "photos.json"))
            }
            for jpg in Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? []
            where jpg.lastPathComponent.hasPrefix("dorm_photo_") {
                let name = String(jpg.lastPathComponent.dropFirst("dorm_photo_".count))
                try FileManager.default.copyItem(at: jpg, to: photos.appending(path: name))
            }
        }
        project.wallFinish = "paint:#8E694E"   // Matched Paint from the scan
        project.floorFinish = "oak"
        update(project)
    }

    func loadDemoData() throws {
        try addBundledDorm()
        guard let url = Bundle.main.url(forResource: "sample_room", withExtension: "json") else { return }
        let model = try JSONDecoder().decode(RoomModel.self, from: Data(contentsOf: url))
        try addRoom(name: "Demo Living Room", model: model) { dir in
            if let thumb = Bundle.main.url(forResource: "sample_room_thumb", withExtension: "jpg") {
                try FileManager.default.copyItem(at: thumb, to: dir.appending(path: "thumb.jpg"))
            }
        }
        let bundled = Bundle.main.url(forResource: "sample_chair", withExtension: "usdz")
        if let old = objects.first(where: { $0.name == "Demo Chair" }) {
            // Keep it, unless it's the procedural stand-in and a real scan is now bundled.
            guard old.modelFile == nil, bundled != nil else { return }
            delete(old)
        }
        var chair = ScannedObject(id: UUID(), name: "Demo Chair", modelFile: nil, boundingBox: [0.5, 0.9, 0.5])
        if let usdz = bundled {
            let dir = Self.objectDir(chair.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: usdz, to: dir.appending(path: "model.usdz"))
            if let thumb = Bundle.main.url(forResource: "sample_chair_thumb", withExtension: "jpg") {
                try? FileManager.default.copyItem(at: thumb, to: dir.appending(path: "thumb.jpg"))
            }
            chair.modelFile = "model.usdz"
        }
        try addObject(chair)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Library(projects: projects, objects: objects)).write(to: Self.indexURL, options: .atomic)
    }
}
