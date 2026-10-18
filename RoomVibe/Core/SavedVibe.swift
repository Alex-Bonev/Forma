import Foundation
import Observation
import os
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
/// CloudSync mirrors both to Supabase when configured (`saved_vibes`, bucket `vibes/<id>/`), with the same hooks as
/// ProjectStore; this library stays the working copy either way.
@Observable
final class VibeLibrary {
    private(set) var vibes: [SavedVibe] = []
    /// Deletes not yet sent to the cloud. Recorded only while `syncEnabled`.
    private(set) var pendingDeletes: [PendingDelete] = []

    /// With a cloud config, deletes are kept as pending until CloudSync sends them. Set before any delete can happen.
    /// Off in UI-test runs, which delete the whole library.
    @ObservationIgnored var syncEnabled = APIConfig.current.cloud != nil && !CloudSync.isUITestRun
    /// Called after every saved change, local or from the cloud (`remote`).
    @ObservationIgnored var onChange: ((_ remote: Bool) -> Void)?

    struct PendingDelete: Codable, Hashable {
        var id: UUID
        var deletedAt: Date
    }

    static let maxImages = 15
    private static let root = ProjectStore.root.appending(path: "Vibes")
    private static let indexURL = root.appending(path: "vibes.json")

    /// vibes.json. Builds from before sync saved a bare `[SavedVibe]` array: still read, rewritten as this on the
    /// next save.
    private struct Index: Codable {
        var vibes: [SavedVibe]
        var pendingDeletes: [PendingDelete]? = nil
    }

    /// Set when an unreadable index could not be moved aside: saving would overwrite the only copy, so nothing is
    /// saved this launch.
    @ObservationIgnored private var indexLocked = false

    init() {
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        guard let index = Self.decodeIndex(data) else {
            // Keep the unreadable index for recovery instead of overwriting it on the next save.
            let bad = Self.root.appending(path: "vibes.json.bad")
            try? FileManager.default.removeItem(at: bad)
            do { try FileManager.default.moveItem(at: Self.indexURL, to: bad) } catch {
                indexLocked = true
                Logger(subsystem: "RoomVibe", category: "VibeLibrary")
                    .error("unreadable vibes.json could not be moved aside, not saving: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        vibes = index.vibes
        pendingDeletes = index.pendingDeletes ?? []
    }

    /// ISO 8601 dates, read with or without a fraction (older builds wrote whole seconds). Written with the exact
    /// millisecond (`CloudClient.syncString`) and read back rounded to it, so a sync stamp survives a relaunch
    /// unchanged: a lost fraction would make every vibe read as older than its row.
    private static func decodeIndex(_ data: Data) -> Index? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = CloudClient.parseDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(s)")
            }
            return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
        }
        if let index = try? decoder.decode(Index.self, from: data) { return index }
        return (try? decoder.decode([SavedVibe].self, from: data)).map { Index(vibes: $0) }
    }

    private static func encodeIndex(_ index: Index) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(CloudClient.syncString(date))
        }
        return try encoder.encode(index)
    }

    static func dir(_ id: UUID) -> URL { root.appending(path: id.uuidString) }

    func vibe(_ id: UUID) -> SavedVibe? { vibes.first { $0.id == id } }

    func imageURL(_ vibe: SavedVibe, _ file: String) -> URL {
        Self.dir(vibe.id).appending(path: file)
    }

    /// Stores the reviewed draft and its (already resized) images as a new vibe. Leaves no files behind on failure.
    @discardableResult
    func add(_ draft: SavedVibe, images: [Data]) throws -> SavedVibe {
        var vibe = draft
        vibe.name = vibe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        vibe.imageFiles = images.indices.map { "\($0).jpg" }
        vibe.createdAt = .syncStamp
        vibe.updatedAt = vibe.createdAt
        let dir = Self.dir(vibe.id)
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

    /// Saves edits. Never re-runs the AI: only the stored fields change. A no-op save must not stamp: the stamp
    /// would beat a real edit from another install.
    func update(_ vibe: SavedVibe) throws {
        guard let i = vibes.firstIndex(where: { $0.id == vibe.id }) else { return }
        let old = vibes[i]
        var next = vibe
        next.updatedAt = old.updatedAt
        guard next != old else { return }
        next.updatedAt = .syncStamp
        vibes[i] = next
        do { try persist() } catch { vibes[i] = old; throw error }
    }

    // The folder goes only once the index without the vibe (and its pending delete) is saved, so a failed save
    // never leaves an indexed vibe without its photos.
    func delete(_ vibe: SavedVibe) throws {
        guard let i = vibes.firstIndex(where: { $0.id == vibe.id }) else { return }
        let old = vibes.remove(at: i)
        let oldDeletes = pendingDeletes
        if syncEnabled {
            pendingDeletes.removeAll { $0.id == vibe.id }
            pendingDeletes.append(PendingDelete(id: vibe.id, deletedAt: .syncStamp))
        }
        do { try persist() } catch {
            vibes.insert(old, at: i)
            pendingDeletes = oldDeletes
            throw error
        }
        try? FileManager.default.removeItem(at: Self.dir(vibe.id))
    }

    // MARK: Cloud sync (CloudSync). These keep the cloud's updatedAt and record no pending delete.

    /// Inserts or replaces a vibe pulled from the cloud. Its photos are already in place.
    func applyRemote(_ vibe: SavedVibe) throws {
        let dir = Self.dir(vibe.id)
        let old = self.vibe(vibe.id)
        // A vibe with no photos still gets its folder: sync reads a missing folder as unreadable and skips the vibe.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let i = vibes.firstIndex(where: { $0.id == vibe.id }) { vibes[i] = vibe } else { vibes.insert(vibe, at: 0) }
        do { try persist(remote: true) } catch {
            if let old, let i = vibes.firstIndex(where: { $0.id == vibe.id }) { vibes[i] = old } else {
                vibes.removeAll { $0.id == vibe.id }
                try? FileManager.default.removeItem(at: dir)   // nothing cleans up a folder outside the index
            }
            throw error
        }
    }

    /// Deletes a vibe another install deleted. Rooms here may keep its `vibeID`; lookups treat it as no vibe.
    func removeRemote(_ id: UUID) {
        guard let i = vibes.firstIndex(where: { $0.id == id }) else { return }
        let old = vibes.remove(at: i)
        guard (try? persist(remote: true)) != nil else {
            vibes.insert(old, at: i)   // still indexed with its photos: the next pass removes it again
            return
        }
        try? FileManager.default.removeItem(at: Self.dir(id))
    }

    /// Pending deletes the cloud now has.
    func clearPendingDeletes(_ sent: Set<PendingDelete>) {
        pendingDeletes.removeAll { sent.contains($0) }
        try? persist(remote: true)
    }

    private func persist(remote: Bool = false) throws {
        guard !indexLocked else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try Self.encodeIndex(Index(vibes: vibes, pendingDeletes: pendingDeletes)).write(to: Self.indexURL, options: .atomic)
        onChange?(remote)
    }
}

#if DEBUG
extension VibeLibrary {
    /// UI tests (`-seedVibe`): replaces the library with two known vibes whose photos are solid-color JPEGs.
    /// Sync stays off for the rest of the launch: the seed's deletes must never reach the cloud as tombstones.
    func seedForUITests() {
        syncEnabled = false
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
