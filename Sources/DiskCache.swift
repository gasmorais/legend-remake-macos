import CryptoKit
import Foundation

final class DiskCache: @unchecked Sendable {
    struct Meta: Codable {
        var etag: String?
        var lastModified: String?
        var contentType: String?
        var size: Int
        var validatedAt: Date
        var lastUsed: Date
        var userAgent: String?
        var revalidates: Bool
    }

    private let directory: URL
    private let indexFile: URL
    private let limit: Int64
    private let lock = NSLock()
    private var entries: [String: Meta]
    private var saveScheduled = false

    init(directory: URL, limit: Int64 = 4 << 30) {
        self.directory = directory
        self.limit = limit
        indexFile = directory.appending(path: "index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        entries = (try? Data(contentsOf: indexFile)).flatMap { try? JSONDecoder.iso.decode([String: Meta].self, from: $0) } ?? [:]
    }

    var usage: Int64 {
        lock.withLock { entries.values.reduce(0) { $0 + Int64($1.size) } }
    }

    func contains(_ key: String) -> Bool {
        lock.withLock { entries[key] != nil }
    }

    func lookup(_ key: String) -> (data: Data, meta: Meta)? {
        guard let meta = lock.withLock({ entries[key] }) else { return nil }
        guard let data = try? Data(contentsOf: file(for: key), options: .mappedIfSafe), data.count == meta.size else {
            remove(key)
            return nil
        }
        lock.withLock { entries[key]?.lastUsed = Date() }
        scheduleSave()
        return (data, meta)
    }

    func store(_ key: String, data: Data, meta: Meta) {
        guard (try? data.write(to: file(for: key), options: .atomic)) != nil else { return }
        lock.withLock { entries[key] = meta }
        evictIfNeeded()
        scheduleSave()
    }

    func markValidated(_ key: String, userAgent: String? = nil) {
        lock.withLock {
            entries[key]?.validatedAt = Date()
            if let userAgent { entries[key]?.userAgent = userAgent }
        }
        scheduleSave()
    }

    func adoptValidators(_ key: String, etag: String?, lastModified: String?) {
        lock.withLock {
            entries[key]?.etag = etag
            entries[key]?.lastModified = lastModified
            entries[key]?.validatedAt = Date()
        }
        scheduleSave()
    }

    func isFresh(_ key: String, within interval: TimeInterval) -> Bool {
        lock.withLock { entries[key].map { Date().timeIntervalSince($0.validatedAt) < interval } ?? false }
    }

    func revalidationCandidates(usedWithin interval: TimeInterval) -> [(key: String, meta: Meta)] {
        let limit = Date().addingTimeInterval(-interval)
        return lock.withLock {
            entries.filter { $0.value.revalidates && $0.value.lastUsed > limit }.map { (key: $0.key, meta: $0.value) }
        }
    }

    func clear() {
        lock.withLock { entries.removeAll() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func remove(_ key: String) {
        _ = lock.withLock { entries.removeValue(forKey: key) }
        try? FileManager.default.removeItem(at: file(for: key))
        scheduleSave()
    }

    private func evictIfNeeded() {
        let victims: [String] = lock.withLock {
            var total = entries.values.reduce(0) { $0 + Int64($1.size) }
            guard total > limit else { return [] }
            var result: [String] = []
            for (key, meta) in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) where total > limit * 9 / 10 {
                total -= Int64(meta.size)
                result.append(key)
            }
            result.forEach { entries.removeValue(forKey: $0) }
            return result
        }
        victims.forEach { try? FileManager.default.removeItem(at: file(for: $0)) }
    }

    private func file(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }

    private func scheduleSave() {
        let schedule: Bool = lock.withLock {
            defer { saveScheduled = true }
            return !saveScheduled
        }
        guard schedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in self?.save() }
    }

    private func save() {
        let data: Data? = lock.withLock {
            saveScheduled = false
            return try? JSONEncoder.iso.encode(entries)
        }
        try? data?.write(to: indexFile, options: .atomic)
    }
}
