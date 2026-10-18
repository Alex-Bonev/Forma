import Foundation
import os

/// Mirrors ProjectStore to Supabase (supabase/migrations). Local-first: the app keeps working offline from
/// Application Support, and each pass reconciles both ways.
///
/// One pass: pull every row, send pending deletes, then for each room and object take the newer side
/// (last writer wins on `updatedAt`, enforced again by a trigger in the database). Files reconcile on their own,
/// per file, by modification time, against the manifest in the item's row; so a file and the doc can each come
/// from a different install. A pass runs on launch, on return to the foreground, and a moment after any local change.
///
/// Known gaps: a device clock more than 5 minutes fast keeps re-sending its items (the database caps stamps);
/// a file whose upload landed but whose row did not stays in storage after a delete; a file missing from storage
/// fails that item on every pass.
@MainActor
final class CloudSync {
    private let store: ProjectStore
    private let client: CloudClient
    private var running = false
    private var again = false
    private var debounce: Task<Void, Never>?
    private let log = Logger(subsystem: "RoomVibe", category: "CloudSync")

    /// nil when the app has no cloud config: the library then stays on this device.
    init?(store: ProjectStore, config: APIConfig = .current) {
        guard let cloud = config.cloud else { return nil }
        self.store = store
        client = CloudClient(config: cloud)
        store.onChange = { [weak self] remote in
            if !remote { self?.schedule() }   // a change sync made itself needs no new pass
        }
    }

    /// Runs a pass after `delay`, coalescing the burst of saves a drag or a scan makes. Only the wait is cancelled
    /// by a newer call, never a running pass: that one runs again when it ends.
    func schedule(after delay: Duration = .seconds(2)) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            Task { await self?.sync() }   // a separate task: cancelling `debounce` must not reach the pass
        }
    }

    /// One pass, or one more right after the running pass when called during it.
    func sync() async {
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            do { try await pass() } catch is CancellationError {
                return
            } catch {
                log.error("sync pass failed: \(error.localizedDescription, privacy: .public)")
                return   // offline or signed out: the next trigger tries again
            }
        } while again
    }

    // MARK: Pass

    private func pass() async throws {
        let projectRows = try await client.select("projects", as: ProjectRow.self)
        let objectRows = try await client.select("scanned_objects", as: ObjectRow.self)
        try await sendDeletes(projectRows: projectRows, objectRows: objectRows)

        // Objects first: placements in a pulled room reference them.
        let objectsByID = Dictionary(objectRows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in Set(objectsByID.keys).union(store.objects.map(\.id)) {
            try await item { try await syncObject(id, row: objectsByID[id]) }
        }
        let projectsByID = Dictionary(projectRows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in Set(projectsByID.keys).union(store.projects.map(\.id)) {
            try await item { try await syncProject(id, row: projectsByID[id]) }
        }
    }

    /// One item's failure (a bad file, a rejected row) is logged and skipped; losing the network ends the pass.
    private func item(_ body: () async throws -> Void) async throws {
        do { try await body() } catch let e as APIError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("sync item failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deleted here and not yet sent: the pass leaves it alone (the user may delete during a pass's awaits).
    private func deleting(_ id: UUID) -> Bool { store.pendingDeletes.contains { $0.id == id } }

    private func sendDeletes(projectRows: [ProjectRow], objectRows: [ObjectRow]) async throws {
        var sent = Set<ProjectStore.PendingDelete>()
        for delete in store.pendingDeletes {
            try await item {
                let table = delete.kind == .project ? "projects" : "scanned_objects"
                let remote: (updatedAt: Date, deletedAt: Date?, files: Manifest)? = switch delete.kind {
                case .project: projectRows.first { $0.id == delete.id }.map { ($0.updatedAt, $0.deletedAt, $0.files) }
                case .object: objectRows.first { $0.id == delete.id }.map { ($0.updatedAt, $0.deletedAt, $0.files) }
                }
                // Never uploaded, or already gone: nothing to tell the cloud. Edited elsewhere after this delete:
                // the edit wins, and this pass pulls the item back.
                if let remote, remote.deletedAt == nil, delete.deletedAt >= remote.updatedAt {
                    try await client.update(table, id: delete.id,
                                            Tombstone(updatedAt: delete.deletedAt, deletedAt: delete.deletedAt))
                    // After the tombstone, so other installs never see a live row without its files. A failure here
                    // only leaves files behind.
                    let prefix = Self.remoteFolder(delete.kind, delete.id)
                    do { try await client.remove(remote.files.keys.map { "\(prefix)/\($0)" }) } catch let e as APIError {
                        throw e
                    } catch {
                        log.error("could not remove deleted files: \(error.localizedDescription, privacy: .public)")
                    }
                }
                sent.insert(delete)
            }
        }
        if !sent.isEmpty { store.clearPendingDeletes(sent) }
    }

    private func syncProject(_ id: UUID, row: ProjectRow?) async throws {
        guard !deleting(id) else { return }
        let local = store.projects.first { $0.id == id }
        let dir = ProjectStore.projectDir(id)
        if let row, let deletedAt = row.deletedAt {
            guard let local else { return }
            if Self.newer(local.updatedAt, than: deletedAt) {
                try await push(.project, id, remoteFiles: [:])   // edited here after the delete elsewhere
            } else {
                store.removeRemote(.project, id)
            }
            return
        }
        guard let local else {
            guard let row, let doc = row.doc, let room = row.room else { return }
            try await pull(row.files, kind: .project, id: id, into: dir)
            guard !deleting(id), !store.projects.contains(where: { $0.id == id }) else { return }
            try store.applyRemote(doc, room: room)
            return
        }
        guard let row, let doc = row.doc, let room = row.room else {
            try await push(.project, id, remoteFiles: row?.files ?? [:])   // new here, or the cloud's doc is unreadable
            return
        }
        if Self.newer(row.updatedAt, than: local.updatedAt) {
            let uploaded = try await reconcileFiles(row.files, kind: .project, id: id, dir: dir)
            // The user may have edited (or deleted) it during the transfers: then the local state is the newer one.
            guard store.projects.first(where: { $0.id == id })?.updatedAt == local.updatedAt else { return }
            try store.applyRemote(doc, room: room)
            if uploaded { try await upsert(.project, id) }
        } else if Self.newer(local.updatedAt, than: row.updatedAt) {
            try await push(.project, id, remoteFiles: row.files)
        } else if try await reconcileFiles(row.files, kind: .project, id: id, dir: dir) {
            try await upsert(.project, id)   // only files changed: same doc, new manifest
        }
    }

    private func syncObject(_ id: UUID, row: ObjectRow?) async throws {
        guard !deleting(id) else { return }
        let local = store.objects.first { $0.id == id }
        let dir = ProjectStore.objectDir(id)
        if let row, let deletedAt = row.deletedAt {
            guard let local else { return }
            if Self.newer(local.updatedAt, than: deletedAt) {
                try await push(.object, id, remoteFiles: [:])
            } else {
                store.removeRemote(.object, id)
            }
            return
        }
        guard let local else {
            guard let row, let doc = row.doc else { return }
            try await pull(row.files, kind: .object, id: id, into: dir)
            guard !deleting(id), !store.objects.contains(where: { $0.id == id }) else { return }
            try store.applyRemote(doc)
            return
        }
        guard let row, let doc = row.doc else {
            try await push(.object, id, remoteFiles: row?.files ?? [:])
            return
        }
        if Self.newer(row.updatedAt, than: local.updatedAt) {
            let uploaded = try await reconcileFiles(row.files, kind: .object, id: id, dir: dir)
            guard store.objects.first(where: { $0.id == id })?.updatedAt == local.updatedAt else { return }
            try store.applyRemote(doc)
            if uploaded { try await upsert(.object, id) }
        } else if Self.newer(local.updatedAt, than: row.updatedAt) {
            try await push(.object, id, remoteFiles: row.files)
        } else if try await reconcileFiles(row.files, kind: .object, id: id, dir: dir) {
            try await upsert(.object, id)
        }
    }

    // MARK: Rows

    private func push(_ kind: ProjectStore.PendingDelete.Kind, _ id: UUID, remoteFiles: Manifest) async throws {
        let dir = kind == .project ? ProjectStore.projectDir(id) : ProjectStore.objectDir(id)
        _ = try await reconcileFiles(remoteFiles, kind: kind, id: id, dir: dir)
        try await upsert(kind, id)
    }

    /// Sends the item as it is in the store now (not as it was before this pass's awaits), with a manifest of what
    /// is on disk now, which every file the cloud has (reconciled just before) matches. An item saved before sync
    /// existed has no stamp: it gets one here, locally too, so both sides then agree.
    private func upsert(_ kind: ProjectStore.PendingDelete.Kind, _ id: UUID) async throws {
        switch kind {
        case .project:
            guard !deleting(id), var project = store.projects.first(where: { $0.id == id }),
                  let room = store.room(for: project) else { return }   // deleted mid-pass
            let unstamped = project.updatedAt == nil
            if unstamped { project.updatedAt = .syncStamp }
            try await client.upsert("projects", ProjectRow(id: id, updatedAt: project.updatedAt!, doc: project, room: room,
                                                           files: Self.manifest(of: ProjectStore.projectDir(id), kind: .project)))
            if unstamped, store.projects.first(where: { $0.id == id })?.updatedAt == nil { try store.applyRemote(project, room: room) }
        case .object:
            guard !deleting(id), var object = store.objects.first(where: { $0.id == id }) else { return }
            let unstamped = object.updatedAt == nil
            if unstamped { object.updatedAt = .syncStamp }
            try await client.upsert("scanned_objects", ObjectRow(id: id, updatedAt: object.updatedAt!, doc: object,
                                                                 files: Self.manifest(of: ProjectStore.objectDir(id), kind: .object)))
            if unstamped, store.objects.first(where: { $0.id == id })?.updatedAt == nil { try store.applyRemote(object) }
        }
    }

    // MARK: Files

    /// Per file, the newer copy wins. Returns whether anything was uploaded (the row's manifest is then stale).
    /// Stops when the item is deleted here meanwhile, so a download never recreates its folder.
    private func reconcileFiles(_ remote: Manifest, kind: ProjectStore.PendingDelete.Kind, id: UUID, dir: URL) async throws -> Bool {
        let local = Self.manifest(of: dir, kind: kind)
        let prefix = Self.remoteFolder(kind, id)
        var uploaded = false
        for path in Set(local.keys).union(remote.keys).sorted() {
            guard !deleting(id) else { return uploaded }
            switch (local[path], remote[path]) {
            case let (l?, r?) where l.matches(r): continue
            case let (l?, r?) where !Self.newer(l.modified, than: r.modified):
                try await download(path, entry: r, prefix: prefix, dir: dir)
            case (_?, _):
                try await client.upload(dir.appending(path: path), to: "\(prefix)/\(path)")
                uploaded = true
            case let (nil, r?):
                try await download(path, entry: r, prefix: prefix, dir: dir)
            case (nil, nil): continue
            }
        }
        return uploaded
    }

    /// Downloads every file of an item that is new to this install. On failure, removes the folder only if this
    /// pull made it: half an item is not in the index, and removeIncompleteScans would keep it once it has its
    /// main file.
    private func pull(_ remote: Manifest, kind: ProjectStore.PendingDelete.Kind, id: UUID, into dir: URL) async throws {
        let existed = FileManager.default.fileExists(atPath: dir.path(percentEncoded: false))
        do {
            for (path, entry) in remote.sorted(by: { $0.key < $1.key }) {
                guard !deleting(id) else { throw CancellationError() }
                try await download(path, entry: entry, prefix: Self.remoteFolder(kind, id), dir: dir)
            }
        } catch {
            if !existed { try? FileManager.default.removeItem(at: dir) }
            throw error
        }
    }

    /// Moves the file into place with the writer's modification time, so the manifests then match.
    private func download(_ path: String, entry: FileEntry, prefix: String, dir: URL) async throws {
        let temp = try await client.download("\(prefix)/\(path)")
        let target = dir.appending(path: path)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: target)
            }
            try fm.setAttributes([.modificationDate: entry.modified], ofItemAtPath: target.path(percentEncoded: false))
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// The item's synced files, by path relative to its folder. room.json travels in the row; an object's
    /// Images/ and Checkpoint/ are scan inputs, deleted once the model is built.
    static func manifest(of dir: URL, kind: ProjectStore.PendingDelete.Kind) -> Manifest {
        let skipped: Set<String> = kind == .project ? ["room.json"] : ["Images", "Checkpoint"]
        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: dir.path(percentEncoded: false)) else { return [:] }
        var out = Manifest()
        while let path = walk.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            if skipped.contains(path) || name.hasPrefix(".") {
                walk.skipDescendants()
                continue
            }
            guard let a = walk.fileAttributes, a[.type] as? FileAttributeType == .typeRegular,
                  let size = a[.size] as? Int, let modified = a[.modificationDate] as? Date else { continue }
            out[path] = FileEntry(size: size, modified: Date(timeIntervalSince1970: (modified.timeIntervalSince1970 * 1000).rounded() / 1000))
        }
        return out
    }

    /// The item's folder in the bucket, under the user's own folder (CloudClient adds that).
    static func remoteFolder(_ kind: ProjectStore.PendingDelete.Kind, _ id: UUID) -> String {
        "\(kind == .project ? "projects" : "objects")/\(id.uuidString.lowercased())"
    }

    /// Whether `a` is a later stamp than `b`. A missing stamp (saved before sync) is the oldest.
    static func newer(_ a: Date?, than b: Date?) -> Bool {
        let a = a ?? .distantPast, b = b ?? .distantPast
        return a > b && !a.syncEquals(b)
    }
}

// MARK: Rows

typealias Manifest = [String: FileEntry]

struct FileEntry: Codable, Hashable {
    var size: Int
    var modified: Date

    func matches(_ other: FileEntry) -> Bool { size == other.size && modified.syncEquals(other.modified) }
}

/// A `projects` row. `doc` and `room` are nil when they do not decode (a newer app's format, a damaged row): the
/// row is then skipped or overwritten instead of failing the whole select.
struct ProjectRow: Codable {
    var id: UUID
    var updatedAt: Date
    var deletedAt: Date? = nil
    var doc: Project?
    var room: RoomModel?
    var files: Manifest

    enum CodingKeys: String, CodingKey {
        case id, doc, room, files
        case updatedAt = "updated_at", deletedAt = "deleted_at"
    }

    init(id: UUID, updatedAt: Date, doc: Project, room: RoomModel, files: Manifest) {
        self.id = id; self.updatedAt = updatedAt; self.doc = doc; self.room = room; self.files = files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        doc = try? c.decodeIfPresent(Project.self, forKey: .doc)
        room = try? c.decodeIfPresent(RoomModel.self, forKey: .room)
        files = (try? c.decodeIfPresent(Manifest.self, forKey: .files)) ?? [:]
    }

    /// Sends `deleted_at: null`: an upsert is a live item, which clears a tombstone it won over.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeNil(forKey: .deletedAt)
        try c.encode(doc, forKey: .doc)
        try c.encode(room, forKey: .room)
        try c.encode(files, forKey: .files)
    }
}

/// A `scanned_objects` row. `doc` is nil when it does not decode (see ProjectRow).
struct ObjectRow: Codable {
    var id: UUID
    var updatedAt: Date
    var deletedAt: Date? = nil
    var doc: ScannedObject?
    var files: Manifest

    enum CodingKeys: String, CodingKey {
        case id, doc, files
        case updatedAt = "updated_at", deletedAt = "deleted_at"
    }

    init(id: UUID, updatedAt: Date, doc: ScannedObject, files: Manifest) {
        self.id = id; self.updatedAt = updatedAt; self.doc = doc; self.files = files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        doc = try? c.decodeIfPresent(ScannedObject.self, forKey: .doc)
        files = (try? c.decodeIfPresent(Manifest.self, forKey: .files)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeNil(forKey: .deletedAt)
        try c.encode(doc, forKey: .doc)
        try c.encode(files, forKey: .files)
    }
}

/// Marks a row deleted. The doc stays, so a late edit elsewhere can still win and bring the item back.
private struct Tombstone: Encodable {
    var updatedAt: Date
    var deletedAt: Date
    let files = Manifest()   // the files are removed right after

    enum CodingKeys: String, CodingKey { case files, updatedAt = "updated_at", deletedAt = "deleted_at" }
}
