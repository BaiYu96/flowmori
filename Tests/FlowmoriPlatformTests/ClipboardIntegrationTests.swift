import AppKit
import Carbon
import Combine
import Testing
@testable import Flowmori
import FlowmoriCore

/// Named pasteboards and isolated preferences keep tests away from the user's clipboard/history.
@MainActor @Suite(.serialized) struct ClipboardIntegrationTests {
    @MainActor final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FlowmoriPlatform-\(UUID().uuidString)")
        let suite = "app.flowmori.tests.\(UUID().uuidString)"
        let pasteboard = NSPasteboard.withUniqueName()
        let settings: Settings
        let repository: HistoryRepository
        let service: ClipboardService
        init() throws {
            settings = Settings(defaults:UserDefaults(suiteName:suite)!)
            settings.exclusions = "test.excluded"
            repository = try HistoryRepository(directory:directory)
            service = ClipboardService(settings:settings,repository:repository,directory:directory,pasteboard:pasteboard)
        }
        func dispose() {
            service.stop(); pasteboard.releaseGlobally()
            UserDefaults.standard.removePersistentDomain(forName:suite)
            try? FileManager.default.removeItem(at:directory)
        }
        func put(_ text:String, types:[NSPasteboard.PasteboardType:Data] = [:], source:String = "test.source") {
            let item = NSPasteboardItem()
            item.setString(text,forType:.string)
            item.setString(source,forType:NSPasteboard.PasteboardType("org.nspasteboard.source"))
            for (type,data) in types { item.setData(data,forType:type) }
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects([item]))
            service.poll()
        }
        func settle(count:Int) async throws {
            for _ in 0..<100 {
                if try await repository.records().count == count { await service.reload(); return }
                try await Task.sleep(for:.milliseconds(10))
            }
            #expect(try await repository.records().count == count)
        }
    }
    @Test func richTextRoundTripAndOwnCopyDeduplication() async throws {
        let f = try Fixture(); defer { f.dispose() }
        let html = Data("<b>中文 rich</b>".utf8)
        let rtf = Data("{\\rtf1\\ansi rich}".utf8)
        f.put("中文 rich",types:[.html:html,.rtf:rtf])
        try await f.settle(count:1)
        let record = try #require(f.service.records.first)
        let success = await withCheckedContinuation { continuation in
            f.service.copy(record) { continuation.resume(returning:$0) }
        }
        #expect(success)
        #expect(f.pasteboard.string(forType:.string) == "中文 rich")
        #expect(f.pasteboard.data(forType:.html) == html)
        #expect(f.pasteboard.data(forType:.rtf) == rtf)
        f.service.poll()
        try await f.settle(count:1)
    }
    @Test func confidentialFilesExcludedAppsAndPauseAreSkipped() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.put("private",types:[NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"):Data()])
        f.put("temporary",types:[NSPasteboard.PasteboardType("org.nspasteboard.TransientType"):Data()])
        f.put("file",types:[.fileURL:Data("file:///tmp/example".utf8)])
        f.put("excluded",source:"test.excluded")
        f.settings.paused = true; f.put("paused")
        f.settings.paused = false; f.service.poll()
        f.put("keep")
        try await f.settle(count:1)
        #expect(f.service.records.map(\.text) == ["keep"])
    }
    @Test func rapidCopiesKeepEachChangeAndMergeRepeatedText() async throws {
        let f = try Fixture(); defer { f.dispose() }
        for i in 0..<20 { f.put("中文 \(i)") }
        f.put("中文 2")
        try await f.settle(count:20)
        // Wait for the final queued update as well as initial inserts.
        for _ in 0..<100 {
            await f.service.reload()
            if f.service.records.first?.text == "中文 2" { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        #expect(f.service.records.first?.text == "中文 2")
    }
    @Test func screenshotPNGIsCopiedAndStored() async throws {
        let f = try Fixture(); defer { f.dispose() }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:6,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let png = try #require(bitmap.representation(using:.png,properties:[:]))
        f.service.acceptScreenshot(png)
        try await f.settle(count:1)
        #expect(f.service.records.first?.kind == .image)
        #expect(f.pasteboard.data(forType:.png) == png)
        #expect(f.service.currentImage() != nil)
        let record = try #require(f.service.records.first)
        #expect(try await f.repository.payload(for:record.id)?.imagePNG == png)
    }
    @Test func idlePollingKeepsWatchingWithoutInvalidatingViews() throws {
        let f = try Fixture(); defer { f.dispose() }
        f.service.poll()
        var clipboardChanges = 0, permissionChanges = 0
        let clipboardSubscription = f.service.objectWillChange.sink { clipboardChanges += 1 }
        let permissionSubscription = f.settings.objectWillChange.sink { permissionChanges += 1 }
        defer { clipboardSubscription.cancel(); permissionSubscription.cancel() }
        let count = f.service.pollCount
        for _ in 0..<50 { f.service.poll() }
        for _ in 0..<5 { f.settings.refreshPermissions() }
        #expect(f.service.pollCount == count + 50)
        #expect(clipboardChanges == 0)
        #expect(permissionChanges == 0)
    }
    @Test func shortcutPreferencesPersistWithoutChangingDefaults() throws {
        let f = try Fixture(); defer { f.dispose() }
        #expect(AppAction.allCases.map { f.settings.shortcuts[$0]!.display } == ["⌥V","⌥A","⌥P","⌥M"])
        let changed = Shortcut(keyCode:7,modifiers:2048,label:"X")
        f.settings.saveShortcut(changed,for:.history)
        let reloaded = Settings(defaults:UserDefaults(suiteName:f.suite)!)
        #expect(reloaded.shortcuts[.history] == changed)
        #expect(reloaded.shortcuts[.capture] == AppAction.capture.defaultShortcut)
    }
    @Test func menuLayoutRefreshWaitsForTheLatestResizeAndCancelsOnStop() async throws {
        let layout = MenuLayoutDeferral()
        var refreshes = 0
        layout.onSettled = { refreshes += 1 }
        layout.changed()
        #expect(layout.isSettling)
        #expect(refreshes == 0)
        try await Task.sleep(for:.milliseconds(150))
        layout.changed()
        try await Task.sleep(for:.milliseconds(150))
        #expect(layout.isSettling)
        #expect(refreshes == 0)
        for _ in 0..<100 {
            if !layout.isSettling { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        #expect(!layout.isSettling)
        #expect(refreshes == 1)
        layout.changed(); layout.cancel()
        try await Task.sleep(for:.milliseconds(300))
        #expect(!layout.isSettling)
        #expect(refreshes == 1)
    }
    @Test func systemHotkeyConflictPreservesPreviousRegistration() throws {
        let owner = HotkeyManager(), occupied = HotkeyManager(), probe = HotkeyManager()
        defer { owner.unregisterAll(); occupied.unregisterAll(); probe.unregisterAll() }
        let flags = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let original = Shortcut(keyCode:UInt32(kVK_F18),modifiers:flags,label:"F18")
        let replacement = Shortcut(keyCode:UInt32(kVK_F19),modifiers:flags,label:"F19")
        try owner.register(.history,shortcut:original,current:[:])
        try occupied.register(.capture,shortcut:replacement,current:[:])
        #expect(throws:(any Error).self) { try owner.register(.history,shortcut:replacement,current:[:]) }
        // Choosing the still-active original chord after an error is a no-op,
        // not another registration that conflicts with our own reservation.
        try owner.register(.history,shortcut:original,current:[:])
        // A failed replacement must leave the original key registered to its owner.
        #expect(throws:(any Error).self) { try probe.register(.pin,shortcut:original,current:[:]) }
        owner.unregisterAll()
        try probe.register(.pin,shortcut:original,current:[:])
    }
}
