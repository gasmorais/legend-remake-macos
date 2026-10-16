import Foundation
import SQLite3

enum LegacyCache {
    private static let contentTypes = [
        "swf": "application/x-shockwave-flash", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "xml": "application/xml", "txt": "text/plain", "json": "application/json", "mp3": "audio/mpeg",
    ]

    static func importAll(from directory: URL, into disk: DiskCache, revalidates: (URL) -> Bool) -> (files: Int, bytes: Int64) {
        let database = directory.appending(path: "Cache.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return (0, 0) }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_close(handle) }

        let query = """
            SELECT r.request_key, d.isDataOnFS, d.receiver_data
            FROM cfurl_cache_response r JOIN cfurl_cache_receiver_data d ON d.entry_ID = r.entry_ID
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_finalize(statement) }

        var files = 0
        var bytes: Int64 = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyText = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: keyText)
            guard let url = URL(string: key), !key.contains("rnd="), !disk.contains(key) else { continue }

            let data: Data?
            if sqlite3_column_int(statement, 1) == 1, let name = sqlite3_column_text(statement, 2) {
                data = try? Data(contentsOf: directory.appending(path: "fsCachedData/\(String(cString: name))"))
            } else if let blob = sqlite3_column_blob(statement, 2) {
                data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2)))
            } else {
                data = nil
            }
            guard let data, !data.isEmpty else { continue }

            disk.store(key, data: data, meta: DiskCache.Meta(
                etag: nil,
                lastModified: nil,
                contentType: contentTypes[url.pathExtension.lowercased()],
                size: data.count,
                validatedAt: .distantPast,
                lastUsed: Date(),
                userAgent: nil,
                revalidates: revalidates(url)
            ))
            files += 1
            bytes += Int64(data.count)
        }
        return (files, bytes)
    }
}
