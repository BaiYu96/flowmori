import Foundation
import CSQLite

public enum HistoryError: LocalizedError {
    case database(String), invalidImage, oversized
    public var errorDescription: String? {
        switch self {
        case .database(let message): return "历史数据库操作失败：\(message)"
        case .invalidImage: return "图片数据不完整"
        case .oversized: return "单条内容超过 32 MB，未加入历史"
        }
    }
}

/// Accessed by a single actor in the app; synchronous to allow isolated storage tests.
public final class HistoryStore {
    private var db: OpaquePointer?
    public let directory: URL
    public let imagesDirectory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public static let maximumItemBytes = 32 * 1024 * 1024

    public init(directory: URL) throws {
        self.directory = directory
        imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("history.sqlite3")
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let db { sqlite3_close(db) }; db = nil
            throw HistoryError.database(message)
        }
        sqlite3_busy_timeout(db, 3000)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON;")
        try execute("""
        CREATE TABLE IF NOT EXISTS clips (
          id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL,
          source_id TEXT NOT NULL, source_name TEXT NOT NULL, updated REAL NOT NULL,
          favorite INTEGER NOT NULL DEFAULT 0, image TEXT, representations BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS clips_recent ON clips(updated DESC);
        PRAGMA user_version=1;
        """)
        try removeOrphanedImages()
    }
    deinit { if let db { sqlite3_close(db) } }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> HistoryError { .database(String(cString: sqlite3_errmsg(db))) }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        return stmt
    }
    private func bind(_ value: String, to stmt: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(stmt, index, $0, Int32(value.utf8.count), transient) }
    }
    private func string(_ stmt: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(stmt, column) else { return "" }
        return String(decoding:UnsafeBufferPointer(start:value,count:Int(sqlite3_column_bytes(stmt,column))),as:UTF8.self)
    }
    private func step(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    @discardableResult
    public func insert(_ payload: ClipPayload, limit: Int = 500, date: Date = Date()) throws -> String {
        let size = payload.representations.values.reduce(0) { $0 + $1.count } + (payload.imagePNG?.count ?? 0) + payload.text.utf8.count
        guard size <= Self.maximumItemBytes else { throw HistoryError.oversized }
        if payload.kind == .image && payload.imagePNG == nil { throw HistoryError.invalidImage }
        let id = payload.fingerprint
        let imageFilename = payload.imagePNG.map { _ in id + ".png" }
        if let data = payload.imagePNG, let imageFilename {
            let file = imagesDirectory.appendingPathComponent(imageFilename)
            if !FileManager.default.fileExists(atPath: file.path) {
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        let representations = try JSONEncoder().encode(payload.representations)
        let stmt = try statement("""
        INSERT INTO clips(id,kind,text,source_id,source_name,updated,image,representations) VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET text=excluded.text,source_id=excluded.source_id,
        source_name=excluded.source_name,updated=excluded.updated,representations=excluded.representations;
        """)
        defer { sqlite3_finalize(stmt) }
        bind(id, to: stmt, at: 1); bind(payload.kind.rawValue, to: stmt, at: 2)
        bind(payload.text, to: stmt, at: 3); bind(payload.sourceBundleID, to: stmt, at: 4)
        bind(payload.sourceName, to: stmt, at: 5); sqlite3_bind_double(stmt, 6, date.timeIntervalSince1970)
        if let imageFilename { bind(imageFilename, to: stmt, at: 7) } else { sqlite3_bind_null(stmt, 7) }
        _ = representations.withUnsafeBytes { sqlite3_bind_blob(stmt, 8, $0.baseAddress, Int32($0.count), transient) }
        try step(stmt)
        try prune(limit: limit)
        return id
    }

    public func records() throws -> [ClipRecord] {
        let stmt = try statement("SELECT id,kind,text,source_id,source_name,updated,favorite,image FROM clips ORDER BY updated DESC,id ASC")
        defer { sqlite3_finalize(stmt) }
        var result: [ClipRecord] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            result.append(ClipRecord(id: string(stmt,0), kind: ClipKind(rawValue: string(stmt,1)) ?? .text,
                                     text: string(stmt,2), sourceBundleID: string(stmt,3), sourceName: string(stmt,4),
                                     updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt,5)),
                                     favorite: sqlite3_column_int(stmt,6) != 0,
                                     imageFilename: sqlite3_column_type(stmt,7) == SQLITE_NULL ? nil : string(stmt,7)))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw error() }
        return result
    }

    public func payload(for id: String) throws -> ClipPayload? {
        let stmt = try statement("SELECT kind,text,source_id,source_name,image,representations FROM clips WHERE id=?")
        defer { sqlite3_finalize(stmt) }; bind(id, to: stmt, at: 1)
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw error() }
        var formats: [String: Data] = [:]
        if let bytes = sqlite3_column_blob(stmt, 5) {
            formats = try JSONDecoder().decode([String: Data].self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt,5))))
        }
        let imageFile = string(stmt,4)
        let image = imageFile.isEmpty ? nil : try Data(contentsOf: imagesDirectory.appendingPathComponent(imageFile))
        return ClipPayload(kind: ClipKind(rawValue: string(stmt,0)) ?? .text, text: string(stmt,1),
                           representations: formats, imagePNG: image, sourceBundleID: string(stmt,2), sourceName: string(stmt,3))
    }

    public func setFavorite(_ id: String, _ favorite: Bool, limit: Int = 500) throws {
        let stmt = try statement("UPDATE clips SET favorite=? WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt,1,favorite ? 1 : 0); bind(id,to:stmt,at:2); try step(stmt)
        try prune(limit: limit)
    }
    public func delete(_ id: String) throws {
        let stmt = try statement("DELETE FROM clips WHERE id=?")
        defer { sqlite3_finalize(stmt) }; bind(id,to:stmt,at:1); try step(stmt)
        let file = imagesDirectory.appendingPathComponent(id + ".png")
        if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
    }
    public func clear(includeFavorites: Bool) throws {
        try execute(includeFavorites ? "DELETE FROM clips" : "DELETE FROM clips WHERE favorite=0")
        try removeOrphanedImages()
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    public func prune(limit: Int) throws {
        let stmt = try statement("DELETE FROM clips WHERE favorite=0 AND id NOT IN (SELECT id FROM clips WHERE favorite=0 ORDER BY updated DESC,id ASC LIMIT ?)")
        defer { sqlite3_finalize(stmt) }; sqlite3_bind_int(stmt,1,Int32(max(1,min(limit,10000))))
        try step(stmt)
        if sqlite3_changes(db) > 0 { try removeOrphanedImages() }
    }
    private func removeOrphanedImages() throws {
        let referenced = Set(try records().compactMap(\.imageFilename))
        for file in try FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys:nil) where file.pathExtension == "png" && !referenced.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at:file)
        }
    }
}

public actor HistoryRepository {
    private let store: HistoryStore
    public init(directory: URL) throws { store = try HistoryStore(directory: directory) }
    public func records() throws -> [ClipRecord] { try store.records() }
    public func insert(_ payload: ClipPayload, limit: Int) throws { try store.insert(payload, limit: limit) }
    public func payload(for id: String) throws -> ClipPayload? { try store.payload(for:id) }
    public func favorite(_ id: String, _ value: Bool, limit: Int) throws { try store.setFavorite(id,value,limit:limit) }
    public func delete(_ id: String) throws { try store.delete(id) }
    public func clear(includeFavorites: Bool) throws { try store.clear(includeFavorites:includeFavorites) }
    public func prune(limit: Int) throws { try store.prune(limit:limit) }
}
