import Foundation

public struct CachedRange: Sendable {
    public let bytes: Data
    public let total: Int64
    public let fromDisk: Bool
}

public struct CacheCounters: Equatable, Sendable {
    public var diskBytes: Int64
    public var packs: Int
    public var servedFromDisk: Int64
    public var downloaded: Int64
    public var failures: Int64

    public init(diskBytes: Int64, packs: Int, servedFromDisk: Int64, downloaded: Int64, failures: Int64) {
        self.diskBytes = diskBytes
        self.packs = packs
        self.servedFromDisk = servedFromDisk
        self.downloaded = downloaded
        self.failures = failures
    }
}

private actor DownloadSlots {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) {
        available = count
    }

    func acquire() async {
        if available > 0 {
            available -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

public final class SharedAssetCache: @unchecked Sendable {
    public static let maxConcurrentDownloads = 12

    private struct Key: Hashable {
        let pack: String
        let start: Int64
        let end: Int64
    }

    private struct Download {
        let id = UUID()
        let task: Task<CachedRange?, Never>
    }

    private let directory: URL
    private let fetcher: RangeFetcher
    private let log: @Sendable (String) -> Void
    private let slots = DownloadSlots(SharedAssetCache.maxConcurrentDownloads)
    private let lock = NSLock()
    private let packLock = NSLock()
    private var packs: [String: PackStore] = [:]
    private var downloads: [Key: Download] = [:]
    private var verifying: Set<String> = []
    private var servedFromDisk: Int64 = 0
    private var downloaded: Int64 = 0
    private var failures: Int64 = 0
    private var lastFailureLog = -Double.infinity
    private var disposed = false
    private var flushTimer: DispatchSourceTimer?

    public init(directory: URL, fetcher: RangeFetcher, flushInterval: TimeInterval = 2, log: @escaping @Sendable (String) -> Void) {
        self.directory = directory
        self.fetcher = fetcher
        self.log = log
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for index in names where index.hasSuffix(".bin.index") {
            let name = String(index.dropLast(".index".count))
            if AssetUrl.isValidPackName(name), let pack = PackStore.tryOpen(directory: directory, name: name) {
                packs[name] = pack
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in self?.flushAll() }
        timer.resume()
        flushTimer = timer
    }

    public var counters: CacheCounters {
        lock.lock()
        defer { lock.unlock() }
        return CacheCounters(
            diskBytes: packs.values.reduce(0) { $0 + $1.storedBytes },
            packs: packs.count,
            servedFromDisk: servedFromDisk,
            downloaded: downloaded,
            failures: failures
        )
    }

    public var packNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return packs.keys.sorted()
    }

    public func get(url: String, pack name: String, range: ByteRange) async -> CachedRange? {
        if isDisposed {
            return nil
        }
        if let pack = existingPack(name), pack.has(range) {
            let bytes = await Task.detached { [self] in readOrNull(pack, range) }.value
            if let bytes {
                add(servedFromDisk: Int64(bytes.count))
                return CachedRange(bytes: bytes, total: pack.total, fromDisk: true)
            }
        }
        let key = Key(pack: name, start: range.start, end: range.end)
        let download = startOrJoinDownload(key: key, url: url, range: range)
        let result = await download.task.value
        lock.withLock {
            if downloads[key]?.id == download.id {
                downloads[key] = nil
            }
        }
        return result
    }

    public func clear() {
        packLock.lock()
        defer { packLock.unlock() }
        lock.lock()
        let removed = packs
        packs.removeAll()
        servedFromDisk = 0
        downloaded = 0
        lock.unlock()
        for (name, pack) in removed {
            pack.dispose()
            PackStore.delete(directory: directory, name: name)
        }
    }

    public func flushAll() {
        lock.lock()
        let current = Array(packs.values)
        lock.unlock()
        for pack in current {
            do {
                try pack.flush()
            } catch {
                logFailure("Could not save the cache index for \(pack.name): \(error.localizedDescription)")
            }
        }
    }

    public func dispose() {
        lock.lock()
        if disposed {
            lock.unlock()
            return
        }
        disposed = true
        let current = Array(packs.values)
        packs.removeAll()
        lock.unlock()
        flushTimer?.cancel()
        current.forEach { $0.dispose() }
    }

    private var isDisposed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disposed
    }

    private func existingPack(_ name: String) -> PackStore? {
        lock.lock()
        defer { lock.unlock() }
        return packs[name]
    }

    private func add(servedFromDisk bytes: Int64) {
        lock.lock()
        servedFromDisk += bytes
        lock.unlock()
    }

    private func startOrJoinDownload(key: Key, url: String, range: ByteRange) -> Download {
        lock.lock()
        defer { lock.unlock() }
        if let existing = downloads[key] {
            return existing
        }
        let download = Download(task: Task { [self] in await self.download(url: url, packName: key.pack, range: range) })
        downloads[key] = download
        return download
    }

    private func download(url: String, packName: String, range: ByteRange) async -> CachedRange? {
        await slots.acquire()
        let result = await perform(url: url, packName: packName, range: range)
        await slots.release()
        return result
    }

    private func perform(url: String, packName: String, range: ByteRange) async -> CachedRange? {
        do {
            let fetched = try await fetcher.fetch(url: url, range: range)
            guard range.end < fetched.total else {
                throw RangeFetchError("The range lies outside the pack.")
            }
            lock.withLock { downloaded += Int64(fetched.bytes.count) }
            store(packName: packName, range: range, fetched: fetched)
            return CachedRange(bytes: fetched.bytes, total: fetched.total, fromDisk: false)
        } catch {
            let quiet = lock.withLock { () -> Bool in
                failures += 1
                return disposed
            }
            if !quiet {
                logFailure("Asset download failed, the browser loads it instead (\(packName) \(range.start)-\(range.end)): \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func store(packName: String, range: ByteRange, fetched: FetchedRange) {
        do {
            guard let pack = try acquirePack(packName, total: fetched.total) else { return }
            try pack.write(range, fetched.bytes)
            if !pack.verified && pack.isComplete {
                lock.lock()
                let first = verifying.insert(packName).inserted
                lock.unlock()
                if first {
                    Task.detached { [self] in verify(pack) }
                }
            }
        } catch {
            logFailure("Could not store \(packName) in the shared cache: \(error.localizedDescription)")
        }
    }

    private func acquirePack(_ name: String, total: Int64) throws -> PackStore? {
        packLock.lock()
        defer { packLock.unlock() }
        lock.lock()
        if disposed {
            lock.unlock()
            return nil
        }
        let current = packs[name]
        lock.unlock()
        if let current, current.total == total {
            return current
        }
        if let current {
            lock.lock()
            packs[name] = nil
            lock.unlock()
            current.dispose()
        }
        let created = try PackStore.create(directory: directory, name: name, total: total)
        lock.lock()
        packs[name] = created
        lock.unlock()
        return created
    }

    private func verify(_ pack: PackStore) {
        defer {
            lock.lock()
            verifying.remove(pack.name)
            lock.unlock()
        }
        if pack.verifyComplete() {
            return
        }
        log("Cached pack \(pack.name) did not match its hash and was removed.")
        packLock.lock()
        defer { packLock.unlock() }
        lock.lock()
        let current = packs[pack.name]
        if current === pack {
            packs[pack.name] = nil
        }
        lock.unlock()
        if current === pack {
            pack.dispose()
            PackStore.delete(directory: directory, name: pack.name)
        }
    }

    private func readOrNull(_ pack: PackStore, _ range: ByteRange) -> Data? {
        pack.tryRead(range)
    }

    private func logFailure(_ message: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let due = now - lastFailureLog >= 10
        if due {
            lastFailureLog = now
        }
        lock.unlock()
        if due {
            log(message)
        }
    }
}
