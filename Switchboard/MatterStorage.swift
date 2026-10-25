import Foundation
import Matter

/// Persistent key/value storage the Matter framework uses for fabric and device data.
final class MatterStorage: NSObject, MTRStorage {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private let fileURL: URL

    override init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("matter-storage.plist")
        super.init()
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? PropertyListDecoder().decode([String: Data].self, from: data) {
            values = decoded
        }
    }

    func storageData(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func setStorageData(_ value: Data, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        return persist()
    }

    func removeStorageData(forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
        return persist()
    }

    /// Caller must hold the lock.
    private func persist() -> Bool {
        do {
            let data = try PropertyListEncoder().encode(values)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
