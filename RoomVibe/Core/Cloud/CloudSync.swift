import Foundation
import os

/// Mirrors ProjectStore to Supabase (supabase/migrations). Local-first: the app keeps working offline from
/// Application Support, and each pass reconciles both ways.
///
/// One pass: pull every row, send pending deletes, then for each room and object take the newer side
/// (last writer wins on `updatedAt`, enforced again by a trigger in the database). Files reconcile on their own,
/// per file, against the manifest in the item's row and the one both sides had at the item's last sync (its base,
/// kept in `sync-state.json`): a file missing on one side is a delete when the other side still has the base's copy,
/// otherwise the newer copy wins by modification time. So a file and the doc can each come from a different install.
/// A pass runs on launch, on return to the foreground, and a moment after any local change.
///
/// Known gaps: a device clock more than 5 minutes fast keeps re-sending its items (the database caps stamps);
/// a file whose upload landed but whose row did not stays in storage after a delete; a file missing from storage
/// fails that item on every pass; a delete on another install wins over file-only changes here, since a file write
/// does not stamp the item (if it did, every thumbnail save would beat real edits elsewhere).
@MainActor
final class CloudSync {
    private let store: ProjectStore
    private let client: CloudClient
    private var running = false
    private var again = false
    private var debounce: Task<Void, Never>?
    /// Each item's manifest at its last sync: what tells a delete from a new file. Saved once per pass.
    private var state: SyncState
    private var stateDirty = false   // a change not yet saved, or a save that failed
    private var badManifests = Set<UUID>()   // rows whose `files` did not decode, logged once
    private let log = Logger(subsystem: "RoomVibe", category: "CloudSync")
    private static let stateURL = ProjectStore.root.appending(path: "sync-state.json")

    /// nil when the app has no cloud config: the library then stays on this device.
    /// `client` defaults to the process's one CloudClient: refresh tokens rotate, so a second instance would break
    /// the session.
    init?(store: ProjectStore, client: CloudClient? = .shared) {
        guard let client else { return nil }
        self.store = store
        self.client = client
        state = Self.loadState()
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
        defer { saveState() }   // a failed pass keeps the bases it confirmed too
        // Bases describe one cloud library: another user's rows say nothing about what was deleted here.
        let user = try await client.user()
        if state.user != user {
            state = SyncState(user: user)
            stateDirty = true
        }
        let projectRows = try await client.select("projects", as: ProjectRow.self)
        let objectRows = try await client.select("scanned_objects", as: ObjectRow.self)
        // An item on neither side (its tombstone missed, say) needs no base.
        let known = Set(projectRows.map { Self.remoteFolder(.project, $0.id) } + store.projects.map { Self.remoteFolder(.project, $0.id) }
                        + objectRows.map { Self.remoteFolder(.object, $0.id) } + store.objects.map { Self.remoteFolder(.object, $0.id) })
        for key in state.bases.keys where !known.contains(key) {
            state.bases[key] = nil
            stateDirty = true
        }
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
                setBase(delete.kind, delete.id, nil)
            }
        }
        if !sent.isEmpty { store.clearPendingDeletes(sent) }
    }

    private func syncProject(_ id: UUID, row: ProjectRow?) async throws {
        guard !deleting(id) else { return }
        let local = store.projects.first { $0.id == id }
        let dir = ProjectStore.projectDir(id)
        if let row, let deletedAt = row.deletedAt {
            // The tombstone's empty manifest is not a delete of each file: whatever happens, the base is stale.
            setBase(.project, id, nil)
            guard let local else { return }
            if Self.newer(local.updatedAt, than: deletedAt) {
                try await push(.project, id, remoteFiles: [:])   // edited here after the delete elsewhere
            } else {
                store.removeRemote(.project, id)
            }
            return
        }
        guard row?.filesValid != false else { return skipBadManifest(id) }
        guard let local else {
            guard let row, let doc = row.doc, let room = row.room else { return }
            try await pull(row.files, kind: .project, id: id, into: dir)
            guard !deleting(id), !store.projects.contains(where: { $0.id == id }) else { return }
            try store.applyRemote(doc, room: room)
            setBase(.project, id, row.files)
            return
        }
        guard let row, let doc = row.doc, let room = row.room else {
            // New here, or the cloud's doc is unreadable. No row: no base either, so a missing row (another
            // cloud user, say) never reads as every file deleted elsewhere.
            try await push(.project, id, remoteFiles: row?.files ?? [:], base: row == nil ? nil : base(.project, id))
            return
        }
        if Self.newer(row.updatedAt, than: local.updatedAt) {
            guard let files = try await reconcileFiles(row.files, base: base(.project, id), kind: .project, id: id, dir: dir)
            else { return }
            // The user may have edited (or deleted) it during the transfers: then the local state is the newer one.
            guard store.projects.first(where: { $0.id == id })?.updatedAt == local.updatedAt else { return }
            try store.applyRemote(doc, room: room)
            try await finish(.project, id, remote: row.files, files)
        } else if Self.newer(local.updatedAt, than: row.updatedAt) {
            try await push(.project, id, remoteFiles: row.files, base: base(.project, id))
        } else {
            // Same doc: only files may have changed, and then the row needs a new manifest.
            guard let files = try await reconcileFiles(row.files, base: base(.project, id), kind: .project, id: id, dir: dir)
            else { return }
            try await finish(.project, id, remote: row.files, files)
        }
    }

    private func syncObject(_ id: UUID, row: ObjectRow?) async throws {
        guard !deleting(id) else { return }
        let local = store.objects.first { $0.id == id }
        let dir = ProjectStore.objectDir(id)
        if let row, let deletedAt = row.deletedAt {
            setBase(.object, id, nil)
            guard let local else { return }
            if Self.newer(local.updatedAt, than: deletedAt) {
                try await push(.object, id, remoteFiles: [:])
            } else {
                store.removeRemote(.object, id)
            }
            return
        }
        guard row?.filesValid != false else { return skipBadManifest(id) }
        guard let local else {
            guard let row, let doc = row.doc else { return }
            try await pull(row.files, kind: .object, id: id, into: dir)
            guard !deleting(id), !store.objects.contains(where: { $0.id == id }) else { return }
            try store.applyRemote(doc)
            setBase(.object, id, row.files)
            return
        }
        guard let row, let doc = row.doc else {
            try await push(.object, id, remoteFiles: row?.files ?? [:], base: row == nil ? nil : base(.object, id))
            return
        }
        if Self.newer(row.updatedAt, than: local.updatedAt) {
            guard let files = try await reconcileFiles(row.files, base: base(.object, id), kind: .object, id: id, dir: dir)
            else { return }
            guard store.objects.first(where: { $0.id == id })?.updatedAt == local.updatedAt else { return }
            try store.applyRemote(doc)
            try await finish(.object, id, remote: row.files, files)
        } else if Self.newer(local.updatedAt, than: row.updatedAt) {
            try await push(.object, id, remoteFiles: row.files, base: base(.object, id))
        } else {
            guard let files = try await reconcileFiles(row.files, base: base(.object, id), kind: .object, id: id, dir: dir)
            else { return }
            try await finish(.object, id, remote: row.files, files)
        }
    }

    // MARK: Rows

    /// A row whose manifest did not decode (a newer app's format, a damaged row) would read as every file gone
    /// there: the item waits, untouched, until a readable row comes.
    private func skipBadManifest(_ id: UUID) {
        guard badManifests.insert(id).inserted else { return }
        log.error("unreadable file manifest in row, item skipped: \(id.uuidString, privacy: .public)")
    }

    /// `base` nil merges two-way: right for an item with no row, or one whose row is a tombstone.
    private func push(_ kind: ProjectStore.PendingDelete.Kind, _ id: UUID, remoteFiles: Manifest, base: Manifest? = nil) async throws {
        let dir = kind == .project ? ProjectStore.projectDir(id) : ProjectStore.objectDir(id)
        guard let files = try await reconcileFiles(remoteFiles, base: base, kind: kind, id: id, dir: dir) else { return }
        if let sent = try await upsert(kind, id, files: files.verified) { setBase(kind, id, sent) }
    }

    /// Ends a live item's sync after its files reconciled. Changed: the row's manifest is stale, so send the row and
    /// take the manifest it carried as the base. Unchanged: both sides list exactly the row's files.
    private func finish(_ kind: ProjectStore.PendingDelete.Kind, _ id: UUID, remote: Manifest, _ files: Reconciled) async throws {
        if files.changed {
            if let sent = try await upsert(kind, id, files: files.verified) { setBase(kind, id, sent) }
        } else if !deleting(id) {
            setBase(kind, id, remote)
        }
    }

    /// Sends the item as it is in the store now (not as it was before this pass's awaits), with `files`, the manifest
    /// the reconcile just confirmed in storage: never a fresh read of the disk, which may list a file written since
    /// and never uploaded. An item saved before sync existed has no stamp: it gets one here, locally too, so both
    /// sides then agree. Returns the manifest stored, or nil when nothing was: the item is gone (deleted mid-pass),
    /// or the last-writer-wins trigger kept a newer row, which the next pass merges.
    @discardableResult
    private func upsert(_ kind: ProjectStore.PendingDelete.Kind, _ id: UUID, files: Manifest) async throws -> Manifest? {
        switch kind {
        case .project:
            guard !deleting(id), var project = store.projects.first(where: { $0.id == id }),
                  let room = store.room(for: project) else { return nil }   // deleted mid-pass
            let unstamped = project.updatedAt == nil
            if unstamped { project.updatedAt = .syncStamp }
            let stored = try await client.upsert("projects", ProjectRow(id: id, updatedAt: project.updatedAt!, doc: project, room: room,
                                                           files: files))
            if unstamped, store.projects.first(where: { $0.id == id })?.updatedAt == nil { try store.applyRemote(project, room: room) }
            return stored ? files : nil
        case .object:
            guard !deleting(id), var object = store.objects.first(where: { $0.id == id }) else { return nil }
            let unstamped = object.updatedAt == nil
            if unstamped { object.updatedAt = .syncStamp }
            let stored = try await client.upsert("scanned_objects", ObjectRow(id: id, updatedAt: object.updatedAt!, doc: object,
                                                                 files: files))
            if unstamped, store.objects.first(where: { $0.id == id })?.updatedAt == nil { try store.applyRemote(object) }
            return stored ? files : nil
        }
    }

    // MARK: Sync state

    private func base(_ kind: ProjectStore.PendingDelete.Kind, _ id: UUID) -> Manifest? { state.bases[Self.remoteFolder(kind, id)] }

    /// Records (or with nil drops) an item's base; saved at the end of the pass. Only ever a manifest the item's row
    /// lists, never a local one ahead of it: a base file missing from the row reads as deleted elsewhere.
    private func setBase(_ kind: ProjectStore.PendingDelete.Kind, _ id: UUID, _ manifest: Manifest?) {
        let key = Self.remoteFolder(kind, id)
        guard state.bases[key] != manifest else { return }
        state.bases[key] = manifest
        stateDirty = true
    }

    /// Writes the state if it changed. On failure it stays dirty, so the next pass writes it again. Not fatal: a lost
    /// base only means a two-way merge for that item.
    private func saveState() {
        guard stateDirty else { return }
        do {
            try FileManager.default.createDirectory(at: ProjectStore.root, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: Self.stateURL, options: .atomic)
            stateDirty = false
        } catch {
            log.error("could not save sync state: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// No file yet: empty. Undecodable: kept aside as `sync-state.json.bad` (as ProjectStore does with its index),
    /// then empty, so every item merges two-way once, as on a first sync.
    private static func loadState() -> SyncState {
        guard let data = try? Data(contentsOf: stateURL) else { return SyncState() }
        do { return try JSONDecoder().decode(SyncState.self, from: data) } catch {
            Logger(subsystem: "RoomVibe", category: "CloudSync")
                .error("unreadable sync state, starting empty: \(error.localizedDescription, privacy: .public)")
            let bad = ProjectStore.root.appending(path: "sync-state.json.bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: stateURL, to: bad)
            return SyncState()
        }
    }

    // MARK: Files

    /// What to do with one file, given its entry at the item's last sync (`base`), here and in the row.
    enum FileAction: Equatable { case none, upload, download, removeRemote, removeLocal }

    /// The three-way rule. A side missing a file the other still has unchanged from the base deleted it: the delete
    /// wins. A file on both sides that changed on only one since the base takes that side's copy. Anything else (no
    /// base, a file new on one side, an edit against a delete, edits on both) falls to the newer copy; at the same
    /// time, to the local one, so a tie never overwrites a file here.
    static func fileAction(base: FileEntry?, local: FileEntry?, remote: FileEntry?) -> FileAction {
        switch (local, remote) {
        case (nil, nil): return .none
        case let (l?, r?):
            if l.matches(r) { return .none }
            // Only one side changed since the base: that side wins, whatever the clocks say.
            if let base, l.matches(base) { return .download }
            if let base, r.matches(base) { return .upload }
            return l.modified.syncEquals(r.modified) || Self.newer(l.modified, than: r.modified) ? .upload : .download
        case let (nil, r?): return base.map(r.matches) == true ? .removeRemote : .download
        case let (l?, nil): return base.map(l.matches) == true ? .removeLocal : .upload
        }
    }

    /// What a reconcile confirmed. `verified` lists only files storage holds as listed (a match, a download, an
    /// upload), so a row sent with it never claims a file written since. `changed`: the row's manifest is stale (a
    /// file uploaded or removed from storage); when not, `verified` is the row's manifest.
    struct Reconciled {
        var verified = Manifest()
        var changed = false
    }

    /// The base, or nil (merge two-way) when either side lists no file at all: that is more likely a broken folder
    /// or row than a delete of each file, and two-way restores instead of deleting.
    static func usableBase(_ base: Manifest?, local: Manifest, remote: Manifest) -> Manifest? {
        local.isEmpty || remote.isEmpty ? nil : base
    }

    /// Reconciles each file by `fileAction`. nil when the item is skipped this pass: its folder is missing or
    /// unreadable (which must never read as every file deleted here), or it is deleted here meanwhile, so a
    /// download never recreates its folder. Each file is checked again right before a download or a remove: one
    /// the user wrote meanwhile is kept, and the next pass merges it.
    private func reconcileFiles(_ remote: Manifest, base: Manifest?, kind: ProjectStore.PendingDelete.Kind, id: UUID,
                                dir: URL) async throws -> Reconciled? {
        guard let local = Self.manifest(of: dir, kind: kind) else {
            log.error("item folder unreadable, skipped: \(Self.remoteFolder(kind, id), privacy: .public)")
            return nil
        }
        let base = Self.usableBase(base, local: local, remote: remote)
        let prefix = Self.remoteFolder(kind, id)
        var out = Reconciled()
        for path in Set(local.keys).union(remote.keys).sorted() {
            guard !deleting(id) else { return nil }
            let target = dir.appending(path: path)
            let l = local[path], r = remote[path]
            let unchanged = { Self.same(Self.entry(at: target), l) }
            switch Self.fileAction(base: base?[path], local: l, remote: r) {
            case .none:
                if let l { out.verified[path] = l }
            case .download:
                if unchanged() { try await download(path, entry: r!, prefix: prefix, dir: dir) }
                out.verified[path] = r   // written now, or still what storage holds beside the user's newer copy
            case .upload:
                try await client.upload(target, to: "\(prefix)/\(path)")
                // Rewritten during the upload: storage may hold either copy, so leave it unlisted for the next pass.
                if unchanged() { out.verified[path] = l }
                out.changed = true
            case .removeRemote:
                // Back meanwhile, or the folder gone: keep the remote copy, still listed, for the next pass.
                guard unchanged(), FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) else {
                    out.verified[path] = r
                    continue
                }
                try await client.remove(["\(prefix)/\(path)"])
                out.changed = true
            case .removeLocal:
                // Not listed either way: a copy written meanwhile is new to the row, and the next pass uploads it.
                if unchanged() { try FileManager.default.removeItem(at: target) }
            }
        }
        return out
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
    /// Images/ and Checkpoint/ are scan inputs, deleted once the model is built. nil when the folder is missing or
    /// unreadable, or a file's attributes are: a partial listing would read as files deleted here.
    static func manifest(of dir: URL, kind: ProjectStore.PendingDelete.Kind) -> Manifest? {
        let skipped: Set<String> = kind == .project ? ["room.json"] : ["Images", "Checkpoint"]
        let fm = FileManager.default
        let root = dir.path(percentEncoded: false)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue, fm.isReadableFile(atPath: root),
              let walk = fm.enumerator(atPath: root) else { return nil }
        var out = Manifest()
        while let path = walk.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            if skipped.contains(path) || name.hasPrefix(".") {
                walk.skipDescendants()
                continue
            }
            guard let a = walk.fileAttributes else { return nil }
            guard a[.type] as? FileAttributeType == .typeRegular else { continue }
            guard let entry = FileEntry(a) else { return nil }
            out[path] = entry
        }
        return out
    }

    /// One file's entry as it is on disk now; nil when it is missing or not a regular file.
    static func entry(at url: URL) -> FileEntry? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              a[.type] as? FileAttributeType == .typeRegular else { return nil }
        return FileEntry(a)
    }

    /// Both missing, or both present and matching.
    static func same(_ a: FileEntry?, _ b: FileEntry?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a.matches(b)
        default: false
        }
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

/// `sync-state.json`, written only by CloudSync: the cloud user the bases belong to, and each item's base by
/// `remoteFolder`.
private struct SyncState: Codable {
    var user: UUID? = nil
    var bases: [String: Manifest] = [:]
}

// MARK: Rows

typealias Manifest = [String: FileEntry]

struct FileEntry: Codable, Hashable {
    var size: Int
    var modified: Date

    func matches(_ other: FileEntry) -> Bool { size == other.size && modified.syncEquals(other.modified) }
}

extension FileEntry {
    /// From file attributes, the time rounded to the millisecond the database keeps.
    init?(_ a: [FileAttributeKey: Any]) {
        guard let size = a[.size] as? Int, let modified = a[.modificationDate] as? Date else { return nil }
        self.init(size: size, modified: Date(timeIntervalSince1970: (modified.timeIntervalSince1970 * 1000).rounded() / 1000))
    }
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
    /// false when `files` did not decode: then `[:]` is not the row's manifest, and the item is skipped.
    var filesValid = true

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
        do { files = try c.decodeIfPresent(Manifest.self, forKey: .files) ?? [:] } catch {
            files = [:]
            filesValid = false
        }
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
    var filesValid = true   // see ProjectRow

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
        do { files = try c.decodeIfPresent(Manifest.self, forKey: .files) ?? [:] } catch {
            files = [:]
            filesValid = false
        }
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
