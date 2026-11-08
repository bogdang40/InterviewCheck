import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - Screenshot Operations
    
    func insertScreenshot(_ screenshot: ScreenshotRecord) {
        performAsync { db in
            guard let db else { return }
            
            let sql = """
            INSERT INTO screenshots 
            (session_id, captured_at, width, height, size_bytes, source, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, screenshot.sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, Int64(screenshot.capturedAt.timeIntervalSince1970 * 1000))
                sqlite3_bind_int(stmt, 3, Int32(screenshot.width ?? 0))
                sqlite3_bind_int(stmt, 4, Int32(screenshot.height ?? 0))
                sqlite3_bind_int(stmt, 5, Int32(screenshot.sizeBytes ?? 0))
                sqlite3_bind_text(stmt, 6, screenshot.source, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 7, Int64(Date().timeIntervalSince1970 * 1000))
                
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func saveSessionSnapshot(_ snapshot: SessionSnapshotRecord) {
        performAsync { db in
            guard let db else { return }
            let sql = """
            INSERT OR REPLACE INTO session_snapshots
            (id, session_id, captured_at, width, height, size_bytes, source, content_hash, encrypted_payload, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, snapshot.id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, snapshot.sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, Int64(snapshot.capturedAt.timeIntervalSince1970 * 1000))
                sqlite3_bind_int(stmt, 4, Int32(snapshot.width))
                sqlite3_bind_int(stmt, 5, Int32(snapshot.height))
                sqlite3_bind_int(stmt, 6, Int32(snapshot.sizeBytes))
                sqlite3_bind_text(stmt, 7, snapshot.source, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 8, snapshot.contentHash, -1, SQLITE_TRANSIENT)
                _ = snapshot.encryptedPayload.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(stmt, 9, bytes.baseAddress, Int32(snapshot.encryptedPayload.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(stmt, 10, Int64(Date().timeIntervalSince1970 * 1000))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func loadSessionSnapshots(sessionId: String) -> [SessionSnapshotRecord] {
        var snapshots: [SessionSnapshotRecord] = []

        performSync { db in
            guard let db else { return }

            let sql = """
            SELECT id, session_id, captured_at, width, height, size_bytes, source, content_hash, encrypted_payload
            FROM session_snapshots
            WHERE session_id = ?
            ORDER BY captured_at ASC
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

                while sqlite3_step(stmt) == SQLITE_ROW {
                    let payload: Data = {
                        guard let bytes = sqlite3_column_blob(stmt, 8) else { return Data() }
                        let count = Int(sqlite3_column_bytes(stmt, 8))
                        return Data(bytes: bytes, count: count)
                    }()

                    snapshots.append(
                        SessionSnapshotRecord(
                            id: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString,
                            sessionId: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? sessionId,
                            capturedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000),
                            width: Int(sqlite3_column_int(stmt, 3)),
                            height: Int(sqlite3_column_int(stmt, 4)),
                            sizeBytes: Int(sqlite3_column_int(stmt, 5)),
                            source: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "manual",
                            contentHash: sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "",
                            encryptedPayload: payload
                        )
                    )
                }
            }
            sqlite3_finalize(stmt)
        }

        return snapshots
    }
}
