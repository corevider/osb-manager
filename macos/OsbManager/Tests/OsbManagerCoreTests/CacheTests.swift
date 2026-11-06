import CryptoKit
import Foundation
import Testing
@testable import OsbManagerCore

private let packUrl = "https://opensro.online/assets/packs/"
private let zeroName = "p-001-000000000000.bin"

private func bytes(_ length: Int) -> Data {
    Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 7) })
}

private func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class FakeFetcher: RangeFetcher, @unchecked Sendable {
    let data: Data
    var gate: Gate?
    var failure: Error?
    private let lock = NSLock()
    private var calls = 0
    private var active = 0
    private var peak = 0
    private var requested: [ByteRange] = []

    init(_ data: Data, gate: Gate? = nil, failure: Error? = nil) {
        self.data = data
        self.gate = gate
        self.failure = failure
    }

    var callCount: Int { lock.withLock { calls } }
    var peakConcurrency: Int { lock.withLock { peak } }
    var ranges: [ByteRange] { lock.withLock { requested } }

    func fetch(url: String, range: ByteRange) async throws -> FetchedRange {
        lock.withLock {
            calls += 1
            active += 1
            peak = max(peak, active)
            requested.append(range)
        }
        defer { lock.withLock { active -= 1 } }
        if let gate {
            await gate.wait()
        }
        if let failure {
            throw failure
        }
        return FetchedRange(bytes: data.subdata(in: Int(range.start)..<Int(range.endExclusive)), total: Int64(data.count))
    }
}

private struct Offline: Error, LocalizedError {
    var errorDescription: String? { "offline" }
}

private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ message: String) {
        lock.withLock { items.append(message) }
    }

    var all: [String] { lock.withLock { items } }
}

struct IntervalSetTests {
    @Test func mergesOverlappingAndAdjacentIntervals() {
        var set = IntervalSet()
        set.add(10, 20)
        set.add(30, 40)
        set.add(20, 25)
        set.add(0, 5)
        set.add(24, 31)

        #expect(set.items == [Interval(0, 5), Interval(10, 40)])
        #expect(set.coveredBytes == 35)
    }

    @Test func containsOnlyFullyStoredRanges() {
        var set = IntervalSet()
        set.add(100, 200)
        set.add(300, 400)

        #expect(set.contains(100, 200))
        #expect(set.contains(150, 160))
        #expect(!set.contains(99, 150))
        #expect(!set.contains(150, 301))
        #expect(!set.contains(200, 300))
        #expect(!set.contains(0, 1))
    }

    @Test func ignoresEmptyIntervals() {
        var set = IntervalSet()
        set.add(5, 5)
        set.add(9, 3)

        #expect(set.count == 0)
    }

    @Test func fillsASparsePackFromPartsAndOverlaps() {
        var set = IntervalSet()
        for (start, end) in [(0, 10), (20, 30), (10, 20), (5, 25), (30, 40)] as [(Int64, Int64)] {
            set.add(start, end)
        }

        #expect(set.items == [Interval(0, 40)])
        #expect(set.contains(0, 40))
        #expect(set.coveredBytes == 40)
    }
}

struct ByteRangeTests {
    @Test(arguments: [("bytes=0-15", 0, 15), ("bytes= 100-199 ", 100, 199), ("BYTES=7-7", 7, 7)] as [(String, Int64, Int64)])
    func parsesSingleClosedRanges(header: String, start: Int64, end: Int64) {
        #expect(ByteRange.parse(header: header) == ByteRange(start: start, end: end))
    }

    @Test(arguments: [nil, "", "bytes=10-", "bytes=-500", "bytes=0-1,5-9", "bytes=9-3", "bytes=a-9", "items=0-9", "bytes=0-67108864", "bytes=+1-5", "bytes=1 -5"] as [String?])
    func rejectsEverythingElse(header: String?) {
        #expect(ByteRange.parse(header: header) == nil)
    }

    @Test func acceptsTheLargestAllowedRange() {
        #expect(ByteRange.parse(header: "bytes=0-67108863")?.length == 64 << 20)
        #expect(ByteRange.parse(header: "bytes=0-100", maxLength: 100) == nil)
        #expect(ByteRange.parse(header: "bytes=0-99", maxLength: 100)?.length == 100)
    }

    @Test func writesTheHeaderBack() {
        #expect(ByteRange(start: 5, end: 9).header == "bytes=5-9")
        #expect(ByteRange(start: 5, end: 9).endExclusive == 10)
    }
}

struct AssetUrlTests {
    @Test func acceptsContentHashedPacks() {
        let name = AssetUrl.tryGetPackName("https://opensro.online/assets/packs/equipment-models-001-1f20cbd1ac41.bin")

        #expect(name == "equipment-models-001-1f20cbd1ac41.bin")
        #expect(AssetUrl.hashPrefix(name ?? "") == "1f20cbd1ac41")
    }

    @Test func acceptsTheDefaultPortAndAnyHostCase() {
        #expect(AssetUrl.tryGetPackName("https://opensro.online:443/assets/packs/a-001-1f20cbd1ac41.bin") != nil)
        #expect(AssetUrl.tryGetPackName("https://OpenSRO.Online/assets/packs/a-001-1f20cbd1ac41.bin") != nil)
    }

    @Test(arguments: [
        "http://opensro.online/assets/packs/a-001-1f20cbd1ac41.bin",
        "https://evil.example/assets/packs/a-001-1f20cbd1ac41.bin",
        "https://opensro.online:8443/assets/packs/a-001-1f20cbd1ac41.bin",
        "https://opensro.online/assets/packs/a-001-1f20cbd1ac41.bin?v=2",
        "https://opensro.online/assets/packs/a-001-1f20cbd1ac41.bin#x",
        "https://opensro.online/assets/packs/manifest.json",
        "https://opensro.online/assets/packs/../packs/a-001-1F20CBD1AC41.bin",
        "https://opensro.online/assets/packs/sub/a-001-1f20cbd1ac41.bin",
        "https://opensro.online/assets/packs/a-001-1f20cbd1ac41.bin/",
        "https://opensro.online.evil.example/assets/packs/a-001-1f20cbd1ac41.bin",
        "https://user@opensro.online/assets/packs/a-001-1f20cbd1ac41.bin",
        "https://opensro.online/assets/entry-C_ANlq-Y.js",
        "not a url",
        "",
    ])
    func rejectsOtherUrls(url: String) {
        #expect(AssetUrl.tryGetPackName(url) == nil)
    }

    @Test func rejectsNilAndBadNames() {
        #expect(AssetUrl.tryGetPackName(nil) == nil)
        #expect(!AssetUrl.isValidPackName("../a-001-1f20cbd1ac41.bin"))
        #expect(!AssetUrl.isValidPackName("A-001-1f20cbd1ac41.bin"))
        #expect(!AssetUrl.isValidPackName("a-001-1f20cbd1ac4.bin"))
        #expect(AssetUrl.isValidPackName("game-data-001-6501a3316be9.bin"))
        #expect(AssetUrl.packUrl(for: "game-data-001-6501a3316be9.bin") == "https://opensro.online/assets/packs/game-data-001-6501a3316be9.bin")
    }
}

struct PackStoreTests {
    @Test func storesRangesAndReopensThemAfterFlush() throws {
        let temp = TemporaryDirectory()
        do {
            let pack = try PackStore.create(directory: temp.url, name: zeroName, total: 1000)
            try pack.write(ByteRange(start: 100, end: 103), Data([1, 2, 3, 4]))
            #expect(pack.tryRead(ByteRange(start: 101, end: 102)) == Data([2, 3]))
            #expect(pack.tryRead(ByteRange(start: 99, end: 101)) == nil)
            pack.dispose()
        }

        let reopened = try #require(PackStore.tryOpen(directory: temp.url, name: zeroName))
        defer { reopened.dispose() }

        #expect(reopened.total == 1000)
        #expect(reopened.tryRead(ByteRange(start: 100, end: 103)) == Data([1, 2, 3, 4]))
    }

    @Test func unflushedRangesAreNotListedAfterACrash() throws {
        let temp = TemporaryDirectory()
        let crashed = TemporaryDirectory()
        let pack = try PackStore.create(directory: temp.url, name: zeroName, total: 100)
        try pack.write(ByteRange(start: 0, end: 1), Data([7, 7]))
        try pack.flush()
        try pack.write(ByteRange(start: 10, end: 11), Data([8, 8]))
        for file in try FileManager.default.contentsOfDirectory(atPath: temp.url.path) {
            try FileManager.default.copyItem(at: temp.file(file), to: crashed.file(file))
        }
        pack.dispose()

        let reopened = try #require(PackStore.tryOpen(directory: crashed.url, name: zeroName))
        defer { reopened.dispose() }

        #expect(reopened.has(ByteRange(start: 0, end: 1)))
        #expect(!reopened.has(ByteRange(start: 10, end: 11)))
    }

    @Test func deletesPacksWithACorruptIndex() throws {
        let temp = TemporaryDirectory()
        let pack = try PackStore.create(directory: temp.url, name: zeroName, total: 100)
        try pack.write(ByteRange(start: 0, end: 9), Data(count: 10))
        pack.dispose()
        var index = try Data(contentsOf: temp.file(zeroName + ".index"))
        index[10] ^= 0xFF
        try index.write(to: temp.file(zeroName + ".index"))

        #expect(PackStore.tryOpen(directory: temp.url, name: zeroName) == nil)
        #expect(!FileManager.default.fileExists(atPath: temp.file(zeroName + ".index").path))
        #expect(!FileManager.default.fileExists(atPath: temp.file(zeroName).path))
    }

    @Test(arguments: [0, 5, 20, 40])
    func deletesPacksWithATruncatedIndex(length: Int) throws {
        let temp = TemporaryDirectory()
        let pack = try PackStore.create(directory: temp.url, name: zeroName, total: 100)
        try pack.write(ByteRange(start: 0, end: 9), Data(count: 10))
        pack.dispose()
        let index = try Data(contentsOf: temp.file(zeroName + ".index"))
        try index.prefix(length).write(to: temp.file(zeroName + ".index"))

        #expect(PackStore.tryOpen(directory: temp.url, name: zeroName) == nil)
        #expect(!FileManager.default.fileExists(atPath: temp.file(zeroName).path))
    }

    @Test func deletesPacksWhoseDataFileIsShorterThanTheIndex() throws {
        let temp = TemporaryDirectory()
        let pack = try PackStore.create(directory: temp.url, name: zeroName, total: 100)
        try pack.write(ByteRange(start: 50, end: 59), Data(count: 10))
        pack.dispose()
        try Data(count: 20).write(to: temp.file(zeroName))

        #expect(PackStore.tryOpen(directory: temp.url, name: zeroName) == nil)
        #expect(!FileManager.default.fileExists(atPath: temp.file(zeroName + ".index").path))
    }

    @Test func deletesTheIndexWhenTheDataFileIsGone() throws {
        let temp = TemporaryDirectory()
        let pack = try PackStore.create(directory: temp.url, name: zeroName, total: 100)
        try pack.write(ByteRange(start: 0, end: 9), Data(count: 10))
        pack.dispose()
        try FileManager.default.removeItem(at: temp.file(zeroName))

        #expect(PackStore.tryOpen(directory: temp.url, name: zeroName) == nil)
        #expect(!FileManager.default.fileExists(atPath: temp.file(zeroName + ".index").path))
    }

    @Test func leavesPacksAloneWhileAnotherHandleHoldsThem() throws {
        let temp = TemporaryDirectory()
        let pack = try PackStore.create(directory: temp.url, name: zeroName, total: 100)
        defer { pack.dispose() }
        try pack.write(ByteRange(start: 0, end: 9), Data(count: 10))
        try pack.flush()

        #expect(PackStore.tryOpen(directory: temp.url, name: zeroName) == nil)
        #expect(FileManager.default.fileExists(atPath: temp.file(zeroName + ".index").path))
        #expect(pack.tryRead(ByteRange(start: 0, end: 9)) != nil)
    }

    @Test func rejectsWritesThatDoNotFit() throws {
        let temp = TemporaryDirectory()
        let pack = try PackStore.create(directory: temp.url, name: zeroName, total: 10)
        defer { pack.dispose() }

        #expect(throws: PackStoreError.self) { try pack.write(ByteRange(start: 8, end: 10), Data(count: 3)) }
        #expect(throws: PackStoreError.self) { try pack.write(ByteRange(start: 0, end: 3), Data(count: 2)) }
    }

    @Test func verifiesACompletePackAgainstTheHashInItsName() throws {
        let temp = TemporaryDirectory()
        let data = Data((0..<4096).map { _ in UInt8.random(in: .min ... .max) })
        let good = "p-001-\(hex(data).prefix(12)).bin"
        let pack = try PackStore.create(directory: temp.url, name: good, total: Int64(data.count))
        let wrong = try PackStore.create(directory: temp.url, name: "p-002-000000000000.bin", total: Int64(data.count))
        defer {
            pack.dispose()
            wrong.dispose()
        }

        #expect(!pack.verifyComplete())
        try pack.write(ByteRange(start: 0, end: 4095), data)
        try wrong.write(ByteRange(start: 0, end: 4095), data)

        #expect(pack.verifyComplete())
        #expect(pack.verified)
        #expect(!wrong.verifyComplete())
    }

    @Test func fillsASparsePackFromPartsInAnyOrder() throws {
        let temp = TemporaryDirectory()
        let data = Data((0..<3000).map { _ in UInt8.random(in: .min ... .max) })
        let name = "p-001-\(hex(data).prefix(12)).bin"
        let pack = try PackStore.create(directory: temp.url, name: name, total: 3000)
        defer { pack.dispose() }

        try pack.write(ByteRange(start: 2000, end: 2999), data.subdata(in: 2000..<3000))
        try pack.write(ByteRange(start: 0, end: 999), data.subdata(in: 0..<1000))
        #expect(!pack.isComplete)
        #expect(pack.storedBytes == 2000)
        try pack.write(ByteRange(start: 900, end: 2100), data.subdata(in: 900..<2101))

        #expect(pack.isComplete)
        #expect(pack.storedBytes == 3000)
        #expect(pack.tryRead(ByteRange(start: 0, end: 2999)) == data)
        #expect(pack.verifyComplete())
    }

    @Test func writesTheWindowsIndexFormat() throws {
        let temp = TemporaryDirectory()
        let pack = try PackStore.create(directory: temp.url, name: zeroName, total: 1000)
        try pack.write(ByteRange(start: 100, end: 103), Data([1, 2, 3, 4]))
        try pack.write(ByteRange(start: 500, end: 599), Data(count: 100))
        pack.dispose()

        let index = try Data(contentsOf: temp.file(zeroName + ".index"))

        var expected = Data()
        func put<Value: FixedWidthInteger>(_ value: Value) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { expected.append(contentsOf: $0) }
        }
        put(UInt32(0x4950_4D53))
        put(Int32(1))
        put(Int64(1000))
        expected.append(0)
        put(Int32(2))
        for (start, end) in [(100, 104), (500, 600)] as [(Int64, Int64)] {
            put(start)
            put(end)
        }
        expected.append(contentsOf: SHA256.hash(data: expected))
        #expect(index == expected)
        #expect(Array(index.prefix(4)) == [0x53, 0x4D, 0x50, 0x49])
        let size = try FileManager.default.attributesOfItem(atPath: temp.file(zeroName).path)[.size] as? NSNumber
        #expect(size?.int64Value == 600)
    }

    @Test func readsAnIndexWrittenInTheWindowsFormat() throws {
        let temp = TemporaryDirectory()
        var body = Data()
        func put<Value: FixedWidthInteger>(_ value: Value) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { body.append(contentsOf: $0) }
        }
        put(UInt32(0x4950_4D53))
        put(Int32(1))
        put(Int64(64))
        body.append(1)
        put(Int32(1))
        put(Int64(8))
        put(Int64(16))
        body.append(contentsOf: SHA256.hash(data: body))
        try body.write(to: temp.file(zeroName + ".index"))
        var file = Data(count: 64)
        file.replaceSubrange(8..<16, with: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        try file.write(to: temp.file(zeroName))

        let pack = try #require(PackStore.tryOpen(directory: temp.url, name: zeroName))
        defer { pack.dispose() }

        #expect(pack.total == 64)
        #expect(pack.verified)
        #expect(pack.tryRead(ByteRange(start: 8, end: 15)) == Data([1, 2, 3, 4, 5, 6, 7, 8]))
        #expect(!pack.has(ByteRange(start: 7, end: 15)))
    }
}

struct SharedAssetCacheTests {
    @Test func downloadsAMissOnceAndServesItFromDiskAfterwards() async throws {
        let temp = TemporaryDirectory()
        let fetcher = FakeFetcher(bytes(1000))
        let cache = SharedAssetCache(directory: temp.url, fetcher: fetcher, log: { _ in })
        defer { cache.dispose() }

        let first = await cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 10, end: 19))
        let second = await cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 12, end: 15))

        #expect(first?.fromDisk == false)
        #expect(second?.fromDisk == true)
        #expect(second?.bytes == fetcher.data.subdata(in: 12..<16))
        #expect(fetcher.callCount == 1)
        #expect(cache.counters == CacheCounters(diskBytes: 10, packs: 1, servedFromDisk: 4, downloaded: 10, failures: 0))
    }

    @Test func sharesOneDownloadBetweenConcurrentRequests() async throws {
        let temp = TemporaryDirectory()
        let gate = Gate()
        let fetcher = FakeFetcher(bytes(100), gate: gate)
        let cache = SharedAssetCache(directory: temp.url, fetcher: fetcher, log: { _ in })
        defer { cache.dispose() }

        async let a = cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 49))
        async let b = cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 49))
        async let c = cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 49))
        async let d = cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 49))
        async let e = cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 49))
        try await Task.sleep(nanoseconds: 300_000_000)
        await gate.release()
        let results = await [a, b, c, d, e]

        #expect(results.allSatisfy { $0?.bytes == fetcher.data.subdata(in: 0..<50) })
        #expect(fetcher.callCount == 1)
        #expect(cache.counters.downloaded == 50)
    }

    @Test func downloadsDifferentRangesOfOnePackSeparatelyAndKeepsBoth() async throws {
        let temp = TemporaryDirectory()
        let gate = Gate()
        let fetcher = FakeFetcher(bytes(1000), gate: gate)
        let cache = SharedAssetCache(directory: temp.url, fetcher: fetcher, log: { _ in })
        defer { cache.dispose() }

        async let a = cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 99))
        async let b = cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 50, end: 149))
        try await Task.sleep(nanoseconds: 300_000_000)
        await gate.release()
        _ = await (a, b)

        #expect(fetcher.callCount == 2)
        let inside = await cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 20, end: 140))
        #expect(inside?.fromDisk == true)
        #expect(inside?.bytes == fetcher.data.subdata(in: 20..<141))
        #expect(cache.counters.packs == 1)
        #expect(cache.counters.diskBytes == 150)
    }

    @Test func neverRunsMoreThanTwelveDownloadsAtOnce() async throws {
        let temp = TemporaryDirectory()
        let gate = Gate()
        let fetcher = FakeFetcher(bytes(4000), gate: gate)
        let cache = SharedAssetCache(directory: temp.url, fetcher: fetcher, log: { _ in })
        defer { cache.dispose() }

        var tasks: [Task<CachedRange?, Never>] = []
        for index in 0..<30 {
            let start = Int64(index) * 100
            let range = ByteRange(start: start, end: start + 49)
            let url = packUrl + zeroName
            tasks.append(Task { await cache.get(url: url, pack: zeroName, range: range) })
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(fetcher.peakConcurrency == 12)
        await gate.release()
        for task in tasks {
            _ = await task.value
        }

        #expect(fetcher.callCount == 30)
        #expect(fetcher.peakConcurrency == 12)
    }

    @Test func returnsNilWhenTheDownloadFails() async {
        let temp = TemporaryDirectory()
        let messages = Messages()
        let fetcher = FakeFetcher(bytes(100), failure: Offline())
        let cache = SharedAssetCache(directory: temp.url, fetcher: fetcher, log: messages.add)
        defer { cache.dispose() }

        let result = await cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 9))

        #expect(result == nil)
        #expect(cache.counters.failures == 1)
        #expect(messages.all.contains { $0.contains("offline") })
    }

    @Test func refusesARangeOutsideThePack() async {
        let temp = TemporaryDirectory()
        let cache = SharedAssetCache(directory: temp.url, fetcher: LyingFetcher(), log: { _ in })
        defer { cache.dispose() }

        let result = await cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 9))

        #expect(result == nil)
        #expect(cache.counters.failures == 1)
        #expect(cache.counters.packs == 0)
    }

    @Test func keepsStoredRangesForTheNextStart() async {
        let temp = TemporaryDirectory()
        let first = SharedAssetCache(directory: temp.url, fetcher: FakeFetcher(bytes(500)), log: { _ in })
        _ = await first.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 99))
        first.dispose()
        let offline = FakeFetcher(bytes(500), failure: Offline())
        let restarted = SharedAssetCache(directory: temp.url, fetcher: offline, log: { _ in })
        defer { restarted.dispose() }

        let hit = await restarted.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 50, end: 99))

        #expect(hit?.fromDisk == true)
        #expect(offline.callCount == 0)
        #expect(restarted.counters.packs == 1)
        #expect(restarted.counters.diskBytes == 100)
    }

    @Test func reloadsTheIndexWrittenByTheFlushTimerWithoutADispose() async throws {
        let temp = TemporaryDirectory()
        let cache = SharedAssetCache(directory: temp.url, fetcher: FakeFetcher(bytes(500)), flushInterval: 0.1, log: { _ in })
        _ = await cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 99))
        try await Task.sleep(nanoseconds: 600_000_000)

        let index = try Data(contentsOf: temp.file(zeroName + ".index"))
        cache.dispose()

        #expect(index.count == 69)
    }

    @Test func startsOverWhenThePackSizeChanges() async {
        let temp = TemporaryDirectory()
        let first = SharedAssetCache(directory: temp.url, fetcher: FakeFetcher(bytes(500)), log: { _ in })
        _ = await first.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 99))
        first.dispose()
        let changed = FakeFetcher(bytes(800))
        let replaced = SharedAssetCache(directory: temp.url, fetcher: changed, log: { _ in })
        defer { replaced.dispose() }

        _ = await replaced.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 600, end: 699))
        let old = await replaced.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 99))

        #expect(changed.callCount == 2)
        #expect(old?.fromDisk == false)
        #expect(replaced.counters.packs == 1)
        #expect(replaced.counters.diskBytes == 200)
    }

    @Test func removesACompletePackWhoseHashDoesNotMatch() async throws {
        let temp = TemporaryDirectory()
        let messages = Messages()
        let cache = SharedAssetCache(directory: temp.url, fetcher: FakeFetcher(bytes(256)), log: messages.add)
        defer { cache.dispose() }

        _ = await cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 255))
        for _ in 0..<100 where cache.counters.packs > 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(cache.counters.packs == 0)
        #expect(messages.all.contains { $0.contains("did not match") })
        #expect(!FileManager.default.fileExists(atPath: temp.file(zeroName).path))
    }

    @Test func keepsACompletePackWhoseHashMatchesAndMarksItVerified() async throws {
        let temp = TemporaryDirectory()
        let data = Data((0..<2048).map { _ in UInt8.random(in: .min ... .max) })
        let name = "p-001-\(hex(data).prefix(12)).bin"
        let messages = Messages()
        let cache = SharedAssetCache(directory: temp.url, fetcher: FakeFetcher(data), log: messages.add)

        _ = await cache.get(url: packUrl + name, pack: name, range: ByteRange(start: 0, end: 1023))
        _ = await cache.get(url: packUrl + name, pack: name, range: ByteRange(start: 1024, end: 2047))
        try await Task.sleep(nanoseconds: 500_000_000)
        cache.dispose()

        #expect(messages.all.isEmpty)
        let reopened = try #require(PackStore.tryOpen(directory: temp.url, name: name))
        defer { reopened.dispose() }
        #expect(reopened.verified)
        #expect(reopened.isComplete)
    }

    @Test func startsWithoutAPackWhoseIndexIsCorrupt() async throws {
        let temp = TemporaryDirectory()
        let first = SharedAssetCache(directory: temp.url, fetcher: FakeFetcher(bytes(500)), log: { _ in })
        _ = await first.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 99))
        first.dispose()
        var index = try Data(contentsOf: temp.file(zeroName + ".index"))
        index[12] ^= 0x55
        try index.write(to: temp.file(zeroName + ".index"))
        let fetcher = FakeFetcher(bytes(500))
        let restarted = SharedAssetCache(directory: temp.url, fetcher: fetcher, log: { _ in })
        defer { restarted.dispose() }

        let result = await restarted.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 99))

        #expect(restarted.counters.packs == 1)
        #expect(result?.fromDisk == false)
        #expect(fetcher.callCount == 1)
    }

    @Test func ignoresIndexFilesWithNamesThatAreNotPacks() async throws {
        let temp = TemporaryDirectory()
        try Data(count: 80).write(to: temp.file("escape.bin.index"))
        let cache = SharedAssetCache(directory: temp.url, fetcher: FakeFetcher(bytes(10)), log: { _ in })
        defer { cache.dispose() }

        #expect(cache.counters.packs == 0)
    }

    @Test func clearDeletesEveryPack() async {
        let temp = TemporaryDirectory()
        let cache = SharedAssetCache(directory: temp.url, fetcher: FakeFetcher(bytes(100)), log: { _ in })
        defer { cache.dispose() }
        _ = await cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 9))

        cache.clear()

        #expect(cache.counters == CacheCounters(diskBytes: 0, packs: 0, servedFromDisk: 0, downloaded: 0, failures: 0))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: temp.url.path)) ?? []).isEmpty)
    }

    @Test func answersNothingAfterItWasDisposed() async {
        let temp = TemporaryDirectory()
        let fetcher = FakeFetcher(bytes(100))
        let cache = SharedAssetCache(directory: temp.url, fetcher: fetcher, log: { _ in })
        cache.dispose()

        let result = await cache.get(url: packUrl + zeroName, pack: zeroName, range: ByteRange(start: 0, end: 9))

        #expect(result == nil)
        #expect(fetcher.callCount == 0)
    }

    private struct LyingFetcher: RangeFetcher {
        func fetch(url: String, range: ByteRange) async throws -> FetchedRange {
            FetchedRange(bytes: Data(count: Int(range.length)), total: 5)
        }
    }
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct URLSessionRangeFetcherTests {
    private let name = "p-001-1f20cbd1ac41.bin"

    private func fetcher() -> URLSessionRangeFetcher {
        let configuration = URLSessionRangeFetcher.makeConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.requests = []
        return URLSessionRangeFetcher(configuration: configuration)
    }

    private func answer(_ url: URL, status: Int, headers: [String: String], body: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2", headerFields: headers)!, body)
    }

    @Test func fetchesOneRangeWithARangeHeaderAndChecksTheAnswer() async throws {
        StubProtocol.handler = { [self] request in
            answer(request.url!, status: 206, headers: ["Content-Range": "bytes 10-19/1000"], body: Data(count: 10))
        }
        let fetched = try await fetcher().fetch(url: packUrl + name, range: ByteRange(start: 10, end: 19))

        #expect(fetched.total == 1000)
        #expect(fetched.bytes.count == 10)
        let request = try #require(StubProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.url?.absoluteString == packUrl + name)
        #expect(request.httpShouldHandleCookies == false || request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func usesAnEphemeralSessionWithoutCookiesOrCache() {
        let configuration = URLSessionRangeFetcher.makeConfiguration()

        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test(arguments: [
        (200, ["Content-Range": "bytes 10-19/1000"], 10),
        (206, [:], 10),
        (206, ["Content-Range": "bytes 10-18/1000"], 9),
        (206, ["Content-Range": "bytes 11-20/1000"], 10),
        (206, ["Content-Range": "bytes 10-19/*"], 10),
        (206, ["Content-Range": "bytes 10-19/1000", "Content-Encoding": "gzip"], 10),
        (206, ["Content-Range": "bytes 10-19/1000"], 4),
        (416, ["Content-Range": "bytes */1000"], 0),
    ] as [(Int, [String: String], Int)])
    func refusesAnythingButAnExactAnswer(status: Int, headers: [String: String], length: Int) async {
        StubProtocol.handler = { [self] request in answer(request.url!, status: status, headers: headers, body: Data(count: length)) }

        await #expect(throws: (any Error).self) {
            try await fetcher().fetch(url: packUrl + name, range: ByteRange(start: 10, end: 19))
        }
    }

    @Test(arguments: [
        "https://opensro.online/assets/entry.js",
        "https://evil.example/assets/packs/p-001-1f20cbd1ac41.bin",
        "http://opensro.online/assets/packs/p-001-1f20cbd1ac41.bin",
        "https://opensro.online/assets/packs/p-001-1f20cbd1ac41.bin?x=1",
    ])
    func neverRequestsAnythingButAGamePack(url: String) async {
        StubProtocol.handler = { [self] request in answer(request.url!, status: 206, headers: ["Content-Range": "bytes 0-0/1"], body: Data(count: 1)) }
        let session = fetcher()

        await #expect(throws: RangeFetchError.self) {
            try await session.fetch(url: url, range: ByteRange(start: 0, end: 0))
        }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func readsContentRangeHeaders() {
        #expect(URLSessionRangeFetcher.parse(contentRange: "bytes 0-9/100")?.total == 100)
        #expect(URLSessionRangeFetcher.parse(contentRange: "bytes 0-9/*") == nil)
        #expect(URLSessionRangeFetcher.parse(contentRange: "items 0-9/100") == nil)
    }
}
