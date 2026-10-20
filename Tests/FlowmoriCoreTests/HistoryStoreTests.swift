import Testing
import Foundation
@testable import FlowmoriCore

final class HistoryStoreTests {
    var directory: URL!
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FlowmoriTests-\(UUID().uuidString)")
    }
    deinit { try? FileManager.default.removeItem(at:directory) }
    func text(_ value:String, html:String? = nil) -> ClipPayload {
        var formats = ["public.utf8-plain-text":Data(value.utf8)]
        if let html { formats["public.html"] = Data(html.utf8) }
        return ClipPayload(kind:.text,text:value,representations:formats,sourceBundleID:"test.app",sourceName:"测试来源")
    }
    @Test func testPersistsTextAndRichRepresentationsAcrossReopen() throws {
        let payload = text("你好，Mac",html:"<b>你好，Mac</b>")
        do { let db = try HistoryStore(directory:directory); try db.insert(payload); try db.setFavorite(payload.fingerprint,true) }
        let db = try HistoryStore(directory:directory)
        let restored = try #require(try db.payload(for:payload.fingerprint))
        #expect(restored.text == payload.text)
        #expect(restored.representations == payload.representations)
        #expect(try #require(try db.records().first).favorite)
    }
    @Test func testDedupUpdatesFormatAndOrderButKeepsFavorite() throws {
        let db = try HistoryStore(directory:directory)
        let a = text("same"), b = text("other")
        try db.insert(a,date:Date(timeIntervalSince1970:1)); try db.setFavorite(a.fingerprint,true)
        try db.insert(b,date:Date(timeIntervalSince1970:2))
        let formatted = text("same",html:"<b>same</b>")
        try db.insert(formatted,date:Date(timeIntervalSince1970:3))
        let records = try db.records()
        #expect(records.count == 2); #expect(records.first?.id == a.fingerprint); #expect(records.first?.favorite == true)
        #expect(try db.payload(for:a.fingerprint)?.representations == formatted.representations)
    }
    @Test func testRetentionCountsOnlyNonFavorites() throws {
        let db = try HistoryStore(directory:directory)
        let favorite = text("favorite")
        try db.insert(favorite); try db.setFavorite(favorite.fingerprint,true)
        for index in 0..<505 { try db.insert(text("记录\(index)"),limit:500,date:Date(timeIntervalSince1970:Double(index))) }
        let records = try db.records()
        #expect(records.count == 501)
        #expect(records.filter { !$0.favorite }.count == 500)
        #expect(try db.payload(for:text("记录0").fingerprint) == nil)
        #expect(try db.payload(for:favorite.fingerprint) != nil)
    }
    @Test func testUnfavoritingHonorsCurrentLimit() throws {
        let db = try HistoryStore(directory:directory)
        let old = text("old")
        try db.insert(old,date:Date(timeIntervalSince1970:1)); try db.setFavorite(old.fingerprint,true)
        try db.insert(text("new"),limit:1,date:Date(timeIntervalSince1970:2))
        try db.setFavorite(old.fingerprint,false,limit:1)
        #expect(try db.records().map(\.text) == ["new"])
    }
    @Test func testImagePersistsAndPruningRemovesPayloadFile() throws {
        let db = try HistoryStore(directory:directory)
        let image = ClipPayload(kind:.image,imagePNG:Data([1,2,3,4]))
        try db.insert(image,limit:1,date:Date(timeIntervalSince1970:1))
        #expect(try db.payload(for:image.fingerprint)?.imagePNG == Data([1,2,3,4]))
        let file = db.imagesDirectory.appendingPathComponent(image.fingerprint+".png")
        #expect(FileManager.default.fileExists(atPath:file.path))
        try db.insert(text("next"),limit:1,date:Date(timeIntervalSince1970:2))
        #expect(!(FileManager.default.fileExists(atPath:file.path)))
    }
    @Test func testClearPreservesFavoritesAndCleansDeletedImages() throws {
        let db = try HistoryStore(directory:directory)
        let image = ClipPayload(kind:.image,imagePNG:Data([1,2,3]))
        try db.insert(image); try db.setFavorite(image.fingerprint,true)
        try db.insert(text("ordinary")); try db.clear(includeFavorites:false)
        #expect(try db.records().count == 1)
        #expect(try db.payload(for:image.fingerprint) != nil)
        try db.clear(includeFavorites:true)
        #expect(try db.records().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath:db.imagesDirectory.path).isEmpty)
    }
    @Test func testDeletionIsIdempotent() throws {
        let db = try HistoryStore(directory:directory), payload = text("delete")
        try db.insert(payload); try db.delete(payload.fingerprint); try db.delete(payload.fingerprint)
        #expect(try db.records().isEmpty)
    }
    @Test func testSQLSpecialCharactersAndUnicodeRoundTrip() throws {
        let db = try HistoryStore(directory:directory), payload = text("'; DROP TABLE clips;--\n中文 👋\t%_\\\0after-null")
        try db.insert(payload)
        #expect(try db.payload(for:payload.fingerprint)?.text == payload.text)
        try db.insert(text("table still exists")); #expect(try db.records().count == 2)
    }
    @Test func testOversizedPayloadDoesNotEnterDatabase() throws {
        let db = try HistoryStore(directory:directory)
        #expect(throws: (any Error).self) { try db.insert(ClipPayload(kind:.image,imagePNG:Data(repeating:0,count:HistoryStore.maximumItemBytes+1))) }
        #expect(try db.records().isEmpty)
    }
    @Test func testOrphanFilesRemovedOnReopen() throws {
        do {
            let db = try HistoryStore(directory:directory)
            try Data([0]).write(to:db.imagesDirectory.appendingPathComponent("orphan.png"))
        }
        let db = try HistoryStore(directory:directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath:db.imagesDirectory.path).isEmpty)
    }
}
