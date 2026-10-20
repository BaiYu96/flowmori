import AppKit
import Combine
import FlowmoriCore

@MainActor final class ClipboardService: ObservableObject {
    @Published private(set) var records: [ClipRecord] = []
    @Published private(set) var status = "正在准备历史记录"
    @Published private(set) var needsPermission = false
    private let settings: Settings
    private let repository: HistoryRepository
    let dataDirectory: URL
    private let pasteboard: NSPasteboard
    private var lastChange: Int
    private var timer: Timer?
    private var captureTask: Task<Void,Never>?
    private var pending: [ClipPayload] = []
    private var draining = false
    private var refreshGeneration = 0
    private var cancellables: Set<AnyCancellable> = []
    var onMessage: ((String) -> Void)?
    private(set) var pollCount: UInt64 = 0
    init(settings: Settings, repository: HistoryRepository, directory: URL, pasteboard: NSPasteboard = .general) {
        self.settings = settings; self.repository = repository; self.dataDirectory = directory
        self.pasteboard = pasteboard; lastChange = pasteboard.changeCount
        settings.$historyLimit.dropFirst().sink { [weak self] limit in
            guard let self else { return }
            Task { do { try await self.repository.prune(limit:limit); await self.reload() } catch { self.report(error) } }
        }.store(in:&cancellables)
        settings.$paused.dropFirst().sink { [weak self] _ in self?.lastChange = self?.pasteboard.changeCount ?? 0 }.store(in:&cancellables)
        Task { await reload() }
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval:0.35,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(timer!,forMode:.common)
        poll()
    }
    func stop() { timer?.invalidate(); timer = nil }
    func poll() {
        pollCount += 1
        guard !settings.paused else { lastChange = pasteboard.changeCount; updateStatus("记录已暂停"); return }
        let behavior = pasteboard.accessBehavior
        if behavior == .alwaysDeny || behavior == .ask {
            if !needsPermission { needsPermission = true }
            updateStatus("需要允许读取剪贴板"); return
        }
        if needsPermission { needsPermission = false }
        updateStatus("正在记录 · \(records.count) 条历史")
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        // Skip collections containing multiple pasteboard objects instead of truncating them.
        guard let items = pasteboard.pasteboardItems, items.count == 1, let item = items.first else { lastChange = count; return }
        let app = NSWorkspace.shared.frontmostApplication
        let sourceID = item.string(forType:NSPasteboard.PasteboardType("org.nspasteboard.source")) ?? app?.bundleIdentifier ?? ""
        let types = Set(item.types.map(\.rawValue))
        guard !ClipboardPolicy.shouldIgnore(types:types,source:sourceID,exclusions:settings.excludedBundleIDs) else { lastChange = count; return }
        do {
            guard let payload = try makePayload(item,sourceID:sourceID,sourceName:app?.localizedName ?? "") else { lastChange = count; return }
            guard pasteboard.changeCount == count else { return } // retry a torn read on the next tick
            lastChange = count
            enqueue(payload)
        } catch { lastChange = count; report(error) }
    }
    func requestRead() {
        _ = pasteboard.pasteboardItems // Explicit user action may show the system paste authorization dialog.
        lastChange = pasteboard.changeCount - 1
        poll()
        if needsPermission { settings.openPrivacy("Privacy_Pasteboard") }
    }
    private func makePayload(_ item: NSPasteboardItem, sourceID: String, sourceName: String) throws -> ClipPayload? {
        if item.types.contains(.png) || item.types.contains(.tiff) {
            guard let raw = item.data(forType:.png) ?? item.data(forType:.tiff) else { return nil }
            guard raw.count <= HistoryStore.maximumItemBytes else { throw HistoryError.oversized }
            guard let bitmap = NSBitmapImageRep(data:raw), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                  bitmap.pixelsWide <= 24000, bitmap.pixelsHigh <= 24000,
                  bitmap.pixelsWide * bitmap.pixelsHigh <= 80_000_000,
                  let png = bitmap.representation(using:.png,properties:[:]) else { return nil }
            return ClipPayload(kind:.image,imagePNG:png,sourceBundleID:sourceID,sourceName:sourceName)
        }
        let text = item.string(forType:.string) ?? item.string(forType:.URL)
        guard let text, !text.isEmpty else { return nil }
        var representations: [String:Data] = [:]
        for type: NSPasteboard.PasteboardType in [.string,.URL,.rtf,.html, .tabularText] {
            if let data = item.data(forType:type) { representations[type.rawValue] = data }
        }
        return ClipPayload(kind:.text,text:text,representations:representations,sourceBundleID:sourceID,sourceName:sourceName)
    }
    func enqueue(_ payload: ClipPayload) {
        pending.append(payload)
        guard !draining else { return }
        draining = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            while !self.pending.isEmpty {
                let next = self.pending.removeFirst()
                do { try await self.repository.insert(next,limit:self.settings.historyLimit) }
                catch { self.report(error) }
            }
            self.draining = false
            await self.reload()
        }
    }
    func reload() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let result = try await repository.records()
            if refreshGeneration == generation, records != result { records = result }
        } catch { report(error) }
    }
    @discardableResult func write(_ payload: ClipPayload) -> Bool {
        let item = NSPasteboardItem()
        if let image = payload.imagePNG { item.setData(image,forType:.png) }
        else {
            for (type,data) in payload.representations { item.setData(data,forType:NSPasteboard.PasteboardType(type)) }
            item.setString(payload.text,forType:.string)
        }
        item.setString("1",forType:NSPasteboard.PasteboardType("app.flowmori.own-copy"))
        item.setString(payload.sourceBundleID,forType:NSPasteboard.PasteboardType("org.nspasteboard.source"))
        pasteboard.clearContents()
        let success = pasteboard.writeObjects([item])
        lastChange = pasteboard.changeCount
        if !success { onMessage?("复制失败，请重试。") }
        return success
    }
    func copy(_ record: ClipRecord, completion: @escaping (Bool) -> Void) {
        Task {
            do {
                guard let payload = try await repository.payload(for:record.id) else { completion(false); return }
                let success = write(payload)
                if success { enqueue(payload) }
                completion(success)
            } catch { report(error); completion(false) }
        }
    }
    func acceptScreenshot(_ png: Data) {
        let payload = ClipPayload(kind:.image,imagePNG:png,sourceBundleID:Bundle.main.bundleIdentifier ?? "",sourceName:"Flowmori 截图")
        if write(payload) {
            enqueue(payload)
            let shortcut = settings.shortcuts[.pin]?.display ?? AppAction.pin.defaultShortcut.display
            onMessage?("截图已复制 · \(shortcut) 贴到屏幕")
        }
    }
    func currentImage() -> NSImage? {
        guard let items = pasteboard.pasteboardItems, items.count == 1, let item = items.first,
              !item.types.contains(.fileURL), let data = item.data(forType:.png) ?? item.data(forType:.tiff),
              data.count <= HistoryStore.maximumItemBytes else { return nil }
        return NSImage(data:data)
    }
    func imageURL(_ record: ClipRecord) -> URL? {
        record.imageFilename.map { dataDirectory.appendingPathComponent("Images").appendingPathComponent($0) }
    }
    func favorite(_ record: ClipRecord) {
        Task { do { try await repository.favorite(record.id,!record.favorite,limit:settings.historyLimit); await reload() } catch { report(error) } }
    }
    func delete(_ record: ClipRecord) {
        Task { do { try await repository.delete(record.id); await reload() } catch { report(error) } }
    }
    func clear(includeFavorites: Bool) {
        pending.removeAll()
        Task {
            await captureTask?.value
            do { try await repository.clear(includeFavorites:includeFavorites); await reload() } catch { report(error) }
        }
    }
    private func updateStatus(_ value: String) { if status != value { status = value } }
    private func report(_ error: Error) { updateStatus(error.localizedDescription); onMessage?(error.localizedDescription) }
}
