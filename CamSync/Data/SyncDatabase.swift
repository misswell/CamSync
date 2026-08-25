import Foundation
import SQLite3

actor SyncDatabase {
    enum DatabaseError: Error {
        case open(String)
        case execute(String)
        case prepare(String)
    }

    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("CamSync", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = support.appendingPathComponent("sync-ledger.sqlite").path

        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(db)))
        }
        try Self.initializeSchema(in: db)
        try Self.migrateSchema(in: db)
    }

    deinit {
        sqlite3_close(db)
    }

    func upsertDevice(_ device: DeviceRecord) throws {
        let sql = """
        INSERT INTO devices(id, display_name, device_name, bookmark, last_connected_at)
        VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET display_name=excluded.display_name,
          device_name=COALESCE(excluded.device_name, devices.device_name),
          bookmark=excluded.bookmark, last_connected_at=excluded.last_connected_at
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(device.id, at: 1, to: statement)
        bind(device.displayName, at: 2, to: statement)
        if let volumeName = device.volumeName {
            bind(volumeName, at: 3, to: statement)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        _ = device.bookmark.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(bytes.count), transient)
        }
        sqlite3_bind_double(statement, 5, device.lastConnectedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    func mostRecentDevice() throws -> DeviceRecord? {
        let statement = try prepare("SELECT id, display_name, device_name, bookmark, last_connected_at FROM devices ORDER BY last_connected_at DESC LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let bytes = sqlite3_column_blob(statement, 3)
        let count = Int(sqlite3_column_bytes(statement, 3))
        let bookmark = bytes.map { Data(bytes: $0, count: count) } ?? Data()
        return DeviceRecord(
            id: text(statement, 0),
            displayName: text(statement, 1),
            volumeName: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : text(statement, 2),
            bookmark: bookmark,
            lastConnectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        )
    }

    func devices() throws -> [DeviceRecord] {
        let statement = try prepare("SELECT id, display_name, device_name, bookmark, last_connected_at FROM devices ORDER BY last_connected_at DESC")
        defer { sqlite3_finalize(statement) }
        var records: [DeviceRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let bytes = sqlite3_column_blob(statement, 3)
            let count = Int(sqlite3_column_bytes(statement, 3))
            let bookmark = bytes.map { Data(bytes: $0, count: count) } ?? Data()
            records.append(DeviceRecord(
                id: text(statement, 0),
                displayName: text(statement, 1),
                volumeName: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : text(statement, 2),
                bookmark: bookmark,
                lastConnectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return records
    }

    func deleteDevice(id: String) throws {
        let statement = try prepare("DELETE FROM devices WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(id, at: 1, to: statement)
        try stepDone(statement)
    }

    func saveSettings(_ settings: DeviceSettings, deviceID: String) throws {
        let data = try encoder.encode(settings)
        let statement = try prepare("""
        INSERT INTO device_settings(device_id, json) VALUES(?, ?)
        ON CONFLICT(device_id) DO UPDATE SET json=excluded.json
        """)
        defer { sqlite3_finalize(statement) }
        bind(deviceID, at: 1, to: statement)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), transient)
        }
        try stepDone(statement)
    }

    func settings(deviceID: String) throws -> DeviceSettings {
        let statement = try prepare("SELECT json FROM device_settings WHERE device_id=?")
        defer { sqlite3_finalize(statement) }
        bind(deviceID, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return DeviceSettings() }
        let bytes = sqlite3_column_blob(statement, 0)
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard let bytes else { return DeviceSettings() }
        return try decoder.decode(DeviceSettings.self, from: Data(bytes: bytes, count: count))
    }

    func syncedItemIDs(deviceID: String, itemIDs: [String]) throws -> Set<String> {
        guard !itemIDs.isEmpty else { return [] }
        let uniqueIDs = Array(Set(itemIDs))
        var result = Set<String>()
        result.reserveCapacity(uniqueIDs.count)

        // Keep each query well below SQLite's host-parameter limit. Only IDs from
        // the currently visible/indexed folder are returned, so a very large
        // lifetime history is never loaded into memory.
        let batchSize = 400
        var start = 0
        while start < uniqueIDs.count {
            let end = min(start + batchSize, uniqueIDs.count)
            let batch = uniqueIDs[start..<end]
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let statement = try prepare("""
            SELECT source_key FROM sync_items
            WHERE device_id=? AND status='synced' AND source_key IN (\(placeholders))
            """)
            bind(deviceID, at: 1, to: statement)
            for (offset, itemID) in batch.enumerated() {
                bind(itemID, at: Int32(offset + 2), to: statement)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                result.insert(text(statement, 0))
            }
            sqlite3_finalize(statement)
            start = end
        }
        return result
    }

    func beginAttempt(item: MediaItem, deviceID: String, force: Bool) throws -> SyncAttemptToken? {
        try transaction {
            if !force, try isSynced(itemID: item.id, deviceID: deviceID) { return nil }
            let statement = try prepare("""
            INSERT INTO sync_attempts(device_id, source_key, relative_path, file_name, byte_size,
              created_at, modified_at, status, started_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, 'transferring', ?)
            """)
            defer { sqlite3_finalize(statement) }
            bind(deviceID, at: 1, to: statement)
            bind(item.id, at: 2, to: statement)
            bind(item.relativePath, at: 3, to: statement)
            bind(item.fileName, at: 4, to: statement)
            sqlite3_bind_int64(statement, 5, item.byteSize)
            sqlite3_bind_double(statement, 6, item.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 7, item.modifiedAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 8, Date().timeIntervalSince1970)
            try stepDone(statement)
            return SyncAttemptToken(id: sqlite3_last_insert_rowid(db), itemID: item.id)
        }
    }

    func finishSuccess(
        token: SyncAttemptToken,
        item: MediaItem,
        deviceID: String,
        destination: SyncDestination,
        result: SyncResult
    ) throws {
        try transaction {
            let now = Date().timeIntervalSince1970
            let attempt = try prepare("""
            UPDATE sync_attempts SET status='synced', completed_at=?, destination_kind=?,
              destination_locator=?, content_hash=?, error_message=NULL WHERE id=?
            """)
            defer { sqlite3_finalize(attempt) }
            sqlite3_bind_double(attempt, 1, now)
            bind(destination.kind.rawValue, at: 2, to: attempt)
            bind(result.destinationLocator, at: 3, to: attempt)
            bind(result.contentHash, at: 4, to: attempt)
            sqlite3_bind_int64(attempt, 5, token.id)
            try stepDone(attempt)

            let itemStatement = try prepare("""
            INSERT INTO sync_items(device_id, source_key, relative_path, file_name, byte_size,
              created_at, modified_at, content_hash, status, destination_kind,
              destination_locator, completed_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, 'synced', ?, ?, ?)
            ON CONFLICT(device_id, source_key) DO UPDATE SET content_hash=excluded.content_hash,
              status='synced', destination_kind=excluded.destination_kind,
              destination_locator=excluded.destination_locator, completed_at=excluded.completed_at
            """)
            defer { sqlite3_finalize(itemStatement) }
            bind(deviceID, at: 1, to: itemStatement)
            bind(item.id, at: 2, to: itemStatement)
            bind(item.relativePath, at: 3, to: itemStatement)
            bind(item.fileName, at: 4, to: itemStatement)
            sqlite3_bind_int64(itemStatement, 5, item.byteSize)
            sqlite3_bind_double(itemStatement, 6, item.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(itemStatement, 7, item.modifiedAt.timeIntervalSince1970)
            bind(result.contentHash, at: 8, to: itemStatement)
            bind(destination.kind.rawValue, at: 9, to: itemStatement)
            bind(result.destinationLocator, at: 10, to: itemStatement)
            sqlite3_bind_double(itemStatement, 11, now)
            try stepDone(itemStatement)
        }
    }

    func finishFailure(token: SyncAttemptToken, error: Error) throws {
        let statement = try prepare("UPDATE sync_attempts SET status='failed', completed_at=?, error_message=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        bind(String(describing: error), at: 2, to: statement)
        sqlite3_bind_int64(statement, 3, token.id)
        try stepDone(statement)
    }

    func finishCancelled(token: SyncAttemptToken) throws {
        let statement = try prepare("UPDATE sync_attempts SET status='cancelled', completed_at=?, error_message=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        bind("用户取消传输", at: 2, to: statement)
        sqlite3_bind_int64(statement, 3, token.id)
        try stepDone(statement)
    }

    func clearHistory(deviceID: String?) throws {
        try transaction {
            if let deviceID {
                for table in ["sync_attempts", "sync_items"] {
                    let statement = try prepare("DELETE FROM \(table) WHERE device_id=?")
                    bind(deviceID, at: 1, to: statement)
                    try stepDone(statement)
                    sqlite3_finalize(statement)
                }
            } else {
                try execute("DELETE FROM sync_attempts")
                try execute("DELETE FROM sync_items")
            }
        }
    }

    func historyCount(deviceID: String) throws -> (synced: Int, failed: Int) {
        let statement = try prepare("""
        SELECT (SELECT COUNT(*) FROM sync_items WHERE device_id=? AND status='synced'),
               (SELECT COUNT(*) FROM sync_attempts WHERE device_id=? AND status IN ('failed','interrupted'))
        """)
        defer { sqlite3_finalize(statement) }
        bind(deviceID, at: 1, to: statement)
        bind(deviceID, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)))
    }

    private static func initializeSchema(in db: OpaquePointer?) throws {
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS devices(
          id TEXT PRIMARY KEY, display_name TEXT NOT NULL, device_name TEXT, bookmark BLOB NOT NULL,
          last_connected_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS device_settings(
          device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
          json BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sync_items(
          id INTEGER PRIMARY KEY, device_id TEXT NOT NULL, source_key TEXT NOT NULL,
          relative_path TEXT NOT NULL, file_name TEXT NOT NULL, byte_size INTEGER NOT NULL,
          created_at REAL NOT NULL, modified_at REAL NOT NULL, content_hash TEXT,
          status TEXT NOT NULL, destination_kind TEXT, destination_locator TEXT,
          completed_at REAL, UNIQUE(device_id, source_key)
        );
        CREATE TABLE IF NOT EXISTS sync_attempts(
          id INTEGER PRIMARY KEY, device_id TEXT NOT NULL, source_key TEXT NOT NULL,
          relative_path TEXT NOT NULL, file_name TEXT NOT NULL, byte_size INTEGER NOT NULL,
          created_at REAL NOT NULL, modified_at REAL NOT NULL, status TEXT NOT NULL,
          started_at REAL NOT NULL, completed_at REAL, destination_kind TEXT,
          destination_locator TEXT, content_hash TEXT, error_message TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_sync_items_device_status
          ON sync_items(device_id, status, source_key);
        CREATE INDEX IF NOT EXISTS idx_sync_items_hash
          ON sync_items(device_id, content_hash) WHERE status='synced';
        CREATE INDEX IF NOT EXISTS idx_attempts_device_status
          ON sync_attempts(device_id, status, started_at);
        UPDATE sync_attempts SET status='interrupted', completed_at=strftime('%s','now'),
          error_message='同步被中断' WHERE status='transferring';
        """
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let description = message.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(message)
            throw DatabaseError.execute(description)
        }
    }

    private static func migrateSchema(in db: OpaquePointer?) throws {
        var check: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT device_name FROM devices LIMIT 0", -1, &check, nil) == SQLITE_OK {
            sqlite3_finalize(check)
            return
        }
        sqlite3_finalize(check)
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, "ALTER TABLE devices ADD COLUMN device_name TEXT", nil, nil, &message) == SQLITE_OK else {
            let description = message.map { String(cString: $0) } ?? "Unable to migrate devices table"
            sqlite3_free(message)
            throw DatabaseError.execute(description)
        }
    }

    private func isSynced(itemID: String, deviceID: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sync_items WHERE device_id=? AND source_key=? AND status='synced' LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(deviceID, at: 1, to: statement)
        bind(itemID, at: 2, to: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let description = message.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(message)
            throw DatabaseError.execute(description)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.execute(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}
