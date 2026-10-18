import Foundation
import Observation
import UIKit

/// A reusable aesthetic profile extracted once from inspiration images (/vibe/profile) and kept on the device.
/// Independent of rooms. The images live as JPEGs next to the index, never inside it.
struct SavedVibe: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var imageFiles: [String]
    var styles: [String]
    var mood: [String]
    var colors: [Swatch]
    var materials: [String]
    var textures: [String]
    var motifs: [String]
    var lighting: [String]
    var furnitureCharacteristics: [String]
    var avoid: [String]
    var description: String
    var customInstructions = ""
    var createdAt = Date.now
    var updatedAt = Date.now

    struct Swatch: Codable, Hashable { var name: String; var hex: String }

    /// An unsaved draft from the AI's profile. `name` is the AI's suggestion until the user edits it.
    init(profile p: VibeProfile) {
        name = p.name; imageFiles = []; styles = p.styles; mood = p.mood; colors = p.colors; materials = p.materials
        textures = p.textures; motifs = p.motifs; lighting = p.lighting
        furnitureCharacteristics = p.furnitureCharacteristics; avoid = p.avoid; description = p.description
    }
}

/// The backend's /vibe/profile answer, before the user names and saves it.
struct VibeProfile: Codable, Hashable {
    var name: String
    var styles: [String]
    var mood: [String]
    var colors: [SavedVibe.Swatch]
    var materials: [String]
    var textures: [String]
    var motifs: [String]
    var lighting: [String]
    var furnitureCharacteristics: [String]
    var avoid: [String]
    var description: String
}

/// Text brief for the (future) furniture-shopping agent: the saved description plus the tags, colors, materials
/// and the user's own instructions. Pure, so it can be reused without any AI call.
func getVibeAgentPrompt(_ vibe: SavedVibe) -> String {
    var lines = [vibe.description.trimmingCharacters(in: .whitespacesAndNewlines)]
    func add(_ label: String, _ items: [String]) {
        if !items.isEmpty { lines.append("\(label): \(items.joined(separator: ", "))") }
    }
    add("Styles", vibe.styles)
    add("Mood", vibe.mood)
    add("Colors", vibe.colors.map { "\($0.name) (\($0.hex))" })
    add("Materials", vibe.materials)
    add("Textures", vibe.textures)
    add("Motifs", vibe.motifs)
    add("Lighting", vibe.lighting)
    add("Furniture", vibe.furnitureCharacteristics)
    add("Avoid", vibe.avoid)
    let extra = vibe.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    if !extra.isEmpty { lines.append("User instructions (they win over the above): \(extra)") }
    return lines.filter { !$0.isEmpty }.joined(separator: "\n")
}

/// Brief for the Browserbase / smart-shopping agents: the room plus its applied vibe, built fresh from the saved
/// vibe each time so edits to the vibe are never stale. nil when the room has no (surviving) vibe.
func getRoomVibeBrief(room: Project, library: VibeLibrary) -> String? {
    guard let id = room.vibeID, let vibe = library.vibe(id) else { return nil }
    return "Room: \(room.name)\nVibe: \(vibe.name)\n" + getVibeAgentPrompt(vibe)
}

/// My Vibes: Application Support/Vibes/vibes.json is the index, Vibes/<id>/<n>.jpg the inspiration images.
@Observable
final class VibeLibrary {
    private(set) var vibes: [SavedVibe] = []

    static let maxImages = 15
    private static let root = ProjectStore.root.appending(path: "Vibes")
    private static let indexURL = root.appending(path: "vibes.json")

    init() {
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode([SavedVibe].self, from: data) else {
            try? FileManager.default.moveItem(at: Self.indexURL, to: Self.root.appending(path: "vibes.json.bad"))
            return
        }
        vibes = saved
    }

    func vibe(_ id: UUID) -> SavedVibe? { vibes.first { $0.id == id } }

    func imageURL(_ vibe: SavedVibe, _ file: String) -> URL {
        Self.root.appending(path: "\(vibe.id)/\(file)")
    }

    /// Stores the reviewed draft and its (already resized) images as a new vibe. Leaves no files behind on failure.
    @discardableResult
    func add(_ draft: SavedVibe, images: [Data]) throws -> SavedVibe {
        var vibe = draft
        vibe.name = vibe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        vibe.imageFiles = images.indices.map { "\($0).jpg" }
        vibe.createdAt = .now
        vibe.updatedAt = .now
        let dir = Self.root.appending(path: vibe.id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            for (file, data) in zip(vibe.imageFiles, images) { try data.write(to: dir.appending(path: file)) }
            vibes.insert(vibe, at: 0)
            try persist()
        } catch {
            vibes.removeAll { $0.id == vibe.id }
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return vibe
    }

    /// Saves edits. Never re-runs the AI: only the stored fields change.
    func update(_ vibe: SavedVibe) throws {
        guard let i = vibes.firstIndex(where: { $0.id == vibe.id }) else { return }
        var next = vibe
        next.updatedAt = .now
        let old = vibes[i]
        vibes[i] = next
        do { try persist() } catch { vibes[i] = old; throw error }
    }

    func delete(_ vibe: SavedVibe) throws {
        guard let i = vibes.firstIndex(where: { $0.id == vibe.id }) else { return }
        let old = vibes.remove(at: i)
        do { try persist() } catch { vibes.insert(old, at: i); throw error }
        try? FileManager.default.removeItem(at: Self.root.appending(path: vibe.id.uuidString))
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(vibes).write(to: Self.indexURL, options: .atomic)
    }
}

#if DEBUG
extension VibeLibrary {
    /// UI tests (`-seedVibe`): replaces the library with two known vibes whose photos are solid-color JPEGs.
    func seedForUITests() {
        for vibe in vibes { try? delete(vibe) }
        func jpeg(_ color: UIColor) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).jpegData(withCompressionQuality: 0.8) { c in
                color.setFill(); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
        }
        let photos = [UIColor.brown, .green, .gray, .orange].map(jpeg)
        for (name, style) in [("Soft Japandi", "minimal"), ("Warm Library", "moody")] {
            let profile = VibeProfile(
                name: name, styles: [style], mood: ["calm"], colors: [.init(name: "Oat", hex: "#E6DCCF")],
                materials: ["oak"], textures: ["matte"], motifs: ["branches"], lighting: ["soft"],
                furnitureCharacteristics: ["low profile"], avoid: ["clutter"], description: "A test brief.")
            try? add(SavedVibe(profile: profile), images: photos)
        }
    }
}
#endif
