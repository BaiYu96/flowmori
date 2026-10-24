import Foundation
import Testing
@testable import FlowmoriCore

struct ProductMigrationTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FlowmoriMigration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func movesHistoryFavoritesFormatsImagesAndJournalTogether() throws {
        try withDirectory { root in
            let legacy = root.appendingPathComponent(ProductMigration.legacyDirectoryName)
            let text = ClipPayload(kind: .text, text: "迁移保留", representations: ["public.rtf": Data("{\\rtf1 test}".utf8)])
            let image = ClipPayload(kind: .image, imagePNG: Data([1, 2, 3, 4]))
            do {
                let store = try HistoryStore(directory: legacy)
                try store.insert(text); try store.setFavorite(text.fingerprint, true)
                try store.insert(image)
            }
            let journal = Data("{\"window\":123}".utf8)
            try journal.write(to: legacy.appendingPathComponent("menu-recovery.json"))
            let migrated = try ProductMigration.dataDirectory(in: root, legacyRunning: false)
            #expect(migrated.lastPathComponent == "Flowmori")
            #expect(!FileManager.default.fileExists(atPath: legacy.path))
            let store = try HistoryStore(directory: migrated)
            #expect(try store.records().count == 2)
            #expect(try store.records().first(where: { $0.id == text.fingerprint })?.favorite == true)
            #expect(try store.payload(for: text.fingerprint)?.representations == text.representations)
            #expect(try store.payload(for: image.fingerprint)?.imagePNG == image.imagePNG)
            #expect(try Data(contentsOf: migrated.appendingPathComponent("menu-recovery.json")) == journal)
            #expect(try ProductMigration.dataDirectory(in: root, legacyRunning: false) == migrated)
        }
    }

    @Test func runningLegacyAndExistingDestinationNeverLoseData() throws {
        try withDirectory { root in
            let old = root.appendingPathComponent(ProductMigration.legacyDirectoryName)
            let new = root.appendingPathComponent("Flowmori", isDirectory: true)
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            let marker = old.appendingPathComponent("history.sqlite3-wal")
            try Data([7]).write(to: marker)
            #expect(throws: ProductMigration.Failure.self) { try ProductMigration.dataDirectory(in: root, legacyRunning: true) }
            #expect(try Data(contentsOf: marker) == Data([7]))
            try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
            try Data([9]).write(to: new.appendingPathComponent("history.sqlite3"))
            #expect(try ProductMigration.dataDirectory(in: root, legacyRunning: false) == new)
            #expect(try Data(contentsOf: marker) == Data([7]))
            #expect(try Data(contentsOf: new.appendingPathComponent("history.sqlite3")) == Data([9]))
        }
    }

    @Test func preferencesPreserveNewValuesAndDisabledLoginIntent() throws {
        try withDirectory { root in
            let suite = "app.flowmori.tests.migration.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(700, forKey: "historyLimit")
            let shortcut = Data([1, 2])
            let old: [String: Any] = ["hasLaunched": true, "historyLimit": 300, "hotkey.history": shortcut,
                "exclusions": "test.private", "NSStatusItem Preferred Position MacFlow.Main": 80, "unrelated": "skip"]
            try Data("{\"loginEnabled\":false}".utf8).write(to: root.appendingPathComponent(ProductMigration.receiptName))
            ProductMigration.preferences(legacy: old, into: defaults, dataDirectory: root, hadLegacyData: true)
            #expect(defaults.integer(forKey: "historyLimit") == 700)
            #expect(defaults.data(forKey: "hotkey.history") == shortcut)
            #expect(defaults.string(forKey: "exclusions") == "test.private")
            #expect(defaults.integer(forKey: "NSStatusItem Preferred Position Flowmori.Main") == 80)
            #expect(defaults.object(forKey: ProductMigration.loginIntentKey) as? Bool == false)
            #expect(!defaults.bool(forKey: "hasLaunched"))
            #expect(defaults.object(forKey: "unrelated") == nil)
            defaults.removeObject(forKey: "exclusions")
            ProductMigration.preferences(legacy: old, into: defaults, dataDirectory: root, hadLegacyData: true)
            #expect(defaults.object(forKey: "exclusions") == nil)
        }
    }

    @Test func previousFlowmoriPreferencesFillOnlyMissingValues() throws {
        let suite = "ai.flowmori.tests.previous.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(700, forKey: "historyLimit")
        let shortcut = Data([9, 8, 7])
        let previous: [String: Any] = [
            "historyLimit": 300,
            "hotkey.history": shortcut,
            "menuEnabled": true,
            "exclusions": "old.private",
            "loginRequested": true,
            "hasLaunched": true,
            "NSStatusItem Preferred Position Flowmori.Main": 313,
            "NSStatusItem VisibleCC Flowmori.CollectionDivider": true,
            "unrelated": "skip"
        ]
        ProductMigration.migratePreviousPreferences(previous: previous, into: defaults)
        #expect(defaults.integer(forKey: "historyLimit") == 700)
        #expect(defaults.data(forKey: "hotkey.history") == shortcut)
        #expect(defaults.bool(forKey: "menuEnabled"))
        #expect(defaults.string(forKey: "exclusions") == "old.private")
        #expect(defaults.object(forKey: ProductMigration.loginIntentKey) as? Bool == true)
        #expect(!defaults.bool(forKey: "hasLaunched"))
        #expect(defaults.integer(forKey: "NSStatusItem Preferred Position Flowmori.Main") == 313)
        #expect(defaults.bool(forKey: "NSStatusItem VisibleCC Flowmori.CollectionDivider"))
        #expect(defaults.object(forKey: "unrelated") == nil)
    }

    @Test func previousFlowmoriMigrationPreservesExplicitLoginIntentAndEmptyDomain() throws {
        let suite = "ai.flowmori.tests.previous.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: ProductMigration.loginIntentKey)
        ProductMigration.migratePreviousPreferences(previous: ["loginRequested": true], into: defaults)
        #expect(defaults.object(forKey: ProductMigration.loginIntentKey) as? Bool == false)
        let freshSuite = "ai.flowmori.tests.previous.\(UUID())"
        let fresh = UserDefaults(suiteName: freshSuite)!
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        ProductMigration.migratePreviousPreferences(previous: [:], into: fresh)
        #expect(fresh.object(forKey: ProductMigration.loginIntentKey) == nil)
        #expect(fresh.object(forKey: "historyLimit") == nil)
    }

    @Test func freshInstallIsNotMistakenForMigration() throws {
        try withDirectory { root in
            let suite = "app.flowmori.tests.migration.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let new = try ProductMigration.dataDirectory(in: root, legacyRunning: false)
            ProductMigration.preferences(legacy: [:], into: defaults, dataDirectory: new, hadLegacyData: false)
            #expect(!defaults.bool(forKey: ProductMigration.completedKey))
            #expect(defaults.object(forKey: ProductMigration.loginIntentKey) == nil)
        }
    }
}
