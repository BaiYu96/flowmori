import Foundation

/// Old identifiers exist only at this compatibility boundary. Do not reuse them
/// for current storage, notifications, pasteboard writes or application identity.
public enum ProductMigration {
    public static let legacyBundleID = "app.macflow.MacFlow"
    public static let legacyDirectoryName = "MacFlow"
    public static let legacyOwnCopyType = "app.macflow.own-copy"
    public static let receiptName = "flowmori-migration.json"
    public static let completedKey = "migration.legacyImported"
    public static let loginIntentKey = "migration.loginEnabled"

    public enum Failure: LocalizedError {
        case legacyRunning
        public var errorDescription: String? {
            "旧版 MacFlow 仍在运行。请先退出旧版，再重新打开 Flowmori，以安全迁移历史。"
        }
    }

    /// Rename the whole directory on the same volume, keeping SQLite WAL/SHM,
    /// image files and any recovery journal together. Never merge/overwrite data.
    public static func dataDirectory(in support: URL, legacyRunning: Bool,
                                     fileManager: FileManager = .default) throws -> URL {
        guard !legacyRunning else { throw Failure.legacyRunning }
        let destination = support.appendingPathComponent("Flowmori", isDirectory: true)
        let legacy = support.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: destination.path), fileManager.fileExists(atPath: legacy.path) {
            try fileManager.moveItem(at: legacy, to: destination)
        }
        return destination
    }

    public static func migratePreviousPreferences(previous: [String: Any], into defaults: UserDefaults) {
        guard !previous.isEmpty else { return }
        let keys = [
            "historyLimit", "exclusions", "menuEnabled",
            "hotkey.history", "hotkey.capture", "hotkey.pin", "hotkey.collection",
            "NSStatusItem Preferred Position Flowmori.Main",
            "NSStatusItem Preferred Position Flowmori.CollectionDivider",
            "NSStatusItem VisibleCC Flowmori.Main",
            "NSStatusItem VisibleCC Flowmori.CollectionDivider"
        ]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = previous[key] { defaults.set(value, forKey: key) }
        }
        if defaults.object(forKey: loginIntentKey) == nil,
           let requested = previous["loginRequested"] as? Bool {
            defaults.set(requested, forKey: loginIntentKey)
        }
    }

    /// Import only product preferences, never arbitrary global/system defaults.
    /// Keep existing Flowmori values and mark the import only after it completes.
    public static func preferences(legacy: [String: Any], into defaults: UserDefaults,
                                   dataDirectory: URL, hadLegacyData: Bool) {
        guard !defaults.bool(forKey: completedKey), !legacy.isEmpty || hadLegacyData else { return }
        let keys = ["historyLimit", "exclusions", "menuEnabled", "hotkey.history", "hotkey.capture", "hotkey.pin", "hotkey.collection"]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy[key] { defaults.set(value, forKey: key) }
        }
        for item in ["Main", "CollectionDivider"] {
            let oldKey = "NSStatusItem Preferred Position MacFlow.\(item)"
            let newKey = "NSStatusItem Preferred Position Flowmori.\(item)"
            if defaults.object(forKey: newKey) == nil, let value = legacy[oldKey] { defaults.set(value, forKey: newKey) }
        }
        let receiptURL = dataDirectory.appendingPathComponent(receiptName)
        if let data = try? Data(contentsOf: receiptURL),
           let receipt = try? JSONDecoder().decode(LoginReceipt.self, from: data) {
            defaults.set(receipt.loginEnabled, forKey: loginIntentKey)
        } else if let enabled = legacy["loginRequested"] as? Bool {
            defaults.set(enabled, forKey: loginIntentKey)
        }
        // hasLaunched intentionally belongs to the new app. Its first launch
        // applies the imported login intent and explains any new permissions.
        defaults.set(true, forKey: completedKey)
    }

    private struct LoginReceipt: Decodable { let loginEnabled: Bool }
}
