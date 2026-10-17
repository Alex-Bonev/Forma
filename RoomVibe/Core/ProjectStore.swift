import Foundation
import Observation

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
        guard let data = try? Data(contentsOf: Self.indexURL),
              let lib = try? JSONDecoder().decode(Library.self, from: data) else { return }
        projects = lib.projects
        objects = lib.objects
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
        try JSONEncoder().encode(model).write(to: dir.appending(path: "room.json"))
        try extraFiles(dir)
        projects.insert(project, at: 0)
        try persist()
        return project
    }

    func addObject(_ object: ScannedObject) throws {
        objects.insert(object, at: 0)
        try persist()
    }

    func update(_ project: Project) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i] = project
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
    func loadDemoData() throws {
        guard let url = Bundle.main.url(forResource: "sample_room", withExtension: "json") else { return }
        let model = try JSONDecoder().decode(RoomModel.self, from: Data(contentsOf: url))
        try addRoom(name: "Demo Living Room", model: model)
        guard !objects.contains(where: { $0.name == "Demo Chair" }) else { return }
        var chair = ScannedObject(id: UUID(), name: "Demo Chair", modelFile: nil, boundingBox: [0.5, 0.9, 0.5])
        if let usdz = Bundle.main.url(forResource: "sample_chair", withExtension: "usdz") {
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
