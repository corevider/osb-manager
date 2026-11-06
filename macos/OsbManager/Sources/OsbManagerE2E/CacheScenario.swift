import AppKit
import CryptoKit
import Foundation
import OsbManagerApp
import OsbManagerCef
import OsbManagerCore

final class CountingFetcher: RangeFetcher, @unchecked Sendable {
    private let inner: RangeFetcher
    private let failing: Bool
    private let lock = NSLock()
    private var keys: [String: Int] = [:]
    private var bytes: Int64 = 0

    init(inner: RangeFetcher, failing: Bool) {
        self.inner = inner
        self.failing = failing
    }

    func fetch(url: String, range: ByteRange) async throws -> FetchedRange {
        lock.withLock { keys["\(url) \(range.start)-\(range.end)", default: 0] += 1 }
        if failing {
            throw RangeFetchError("forced failure (test switch)")
        }
        let fetched = try await inner.fetch(url: url, range: range)
        lock.withLock { bytes += Int64(fetched.bytes.count) }
        return fetched
    }

    var summary: [String: Any] {
        lock.withLock {
            [
                "calls": keys.values.reduce(0, +),
                "distinctRanges": keys.count,
                "duplicateRangeCalls": keys.values.filter { $0 > 1 }.reduce(0) { $0 + $1 - 1 },
                "bytes": bytes,
            ]
        }
    }
}

enum CacheScripts {
    static let state = """
    return {
      loginScreen: !!document.querySelector('[data-ui-id="frontend:reveal"]'),
      visibility: document.visibilityState,
      packEntries: [...performance.getEntriesByType('resource')].filter(e => e.name.includes('/assets/packs/')).length,
    };
    """

    static func startFetch(key: String, name: String, range: String) -> String {
        """
        window.__t9 = window.__t9 || {};
        window.__t9['\(key)'] = { state: 'pending' };
        (async () => {
          const hex = buffer => [...new Uint8Array(buffer)].map(byte => byte.toString(16).padStart(2, '0')).join('');
          try {
            const response = await fetch('/assets/packs/\(name)', { headers: { Range: '\(range)' } });
            const buffer = await response.arrayBuffer();
            window.__t9['\(key)'] = {
              state: 'done',
              status: response.status,
              contentRange: response.headers.get('content-range'),
              acceptRanges: response.headers.get('accept-ranges'),
              contentLength: response.headers.get('content-length'),
              bytes: buffer.byteLength,
              sha: hex(await crypto.subtle.digest('SHA-256', buffer)),
            };
          } catch (error) {
            window.__t9['\(key)'] = { state: 'error', message: String(error) };
          }
        })();
        return 'started';
        """
    }

    static func readFetch(key: String) -> String {
        "return (window.__t9 && window.__t9['\(key)']) || { state: 'missing' };"
    }
}

@MainActor
final class CacheScenario {
    private let app: AppDelegate
    private let config: E2EConfiguration
    private let log: JsonLog
    private let recorder = Recorder()
    private var summary: [String: Any] = [:]
    private var fetcher: CountingFetcher?

    init(app: AppDelegate, config: E2EConfiguration, log: JsonLog) {
        self.app = app
        self.config = config
        self.log = log
    }

    private var store: AccountStore { app.services.accounts }
    private var manager: GameManager { app.manager }

    func run() async {
        log.write("start", ["scenario": "cache", "phase": config.phase, "data": app.services.paths.root.path])
        guard await waitUntil(timeout: 1200, interval: 10, { !screenIsLocked() }) else {
            summary["skipped"] = "the screen stayed locked"
            finish()
            return
        }
        summary["screenLocked"] = screenIsLocked()
        summary["phase"] = config.phase
        summary["cef"] = CefRuntime.version
        recorder.start()
        let counting = CountingFetcher(inner: URLSessionRangeFetcher(), failing: config.phase == "fail")
        fetcher = counting
        if config.phase != "savedoff" {
            app.services.settings.shareGameFiles = config.phase != "off" && config.phase != "threeoff"
        }
        app.services.use(rangeFetcher: counting)
        CefPackInterception.shared.resetStatistics()
        summary["shareGameFiles"] = app.services.settings.shareGameFiles
        summary["interceptionActive"] = CefPackInterception.shared.isActive
        switch config.phase {
        case "off", "savedoff": await singleAccount(name: "alpha", hide: true)
        case "single", "fail": await singleAccount(name: "alpha", hide: false)
        case "on": await twoAccounts()
        case "warm": await singleAccount(name: "gamma\(Int(Date().timeIntervalSince1970) % 100000)", hide: true)
        case "three", "threeoff": await threeAtOnce()
        case "verify": await completeOnePack()
        case "probe": await probeResponses()
        case "clear": clearCache()
        default: summary["error"] = "unknown phase"
        }
        summary["fetcher"] = counting.summary
        summary["interception"] = interceptionSummary()
        summary["packcacheFolderExistsAtEnd"] = packcacheFolderExists()
        summary["cache"] = cacheSummary()
        summary["disk"] = diskSummary()
        summary["screenshotMain"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("main-window.png"))
        recorder.stop()
        finish()
    }

    private func finish() {
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("cache-summary.json"))
        log.write("quit-requested")
        NSApp.terminate(nil)
    }

    private func window(_ name: String) -> GameWindowController? {
        store.accounts.first { $0.name == name }.flatMap { manager.windows[$0.id] }
    }

    private func addAccount(_ name: String, index: Int) -> Account? {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(900, Int(visible.width) - 80)
        let height = min(560, Int(visible.height) - 80)
        guard let account = try? store.add(name: name) else { return nil }
        try? store.update(id: account.id) {
            $0.window = WindowPlacement(x: Int(visible.minX) + 20 + index * 40, y: Int(visible.minY) + 20 + index * 40, width: width, height: height, maximized: false)
        }
        return account
    }

    private func timings(_ controller: GameWindowController, since start: Date) async -> [String: Any] {
        var result: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            if result["phaseTitleSeconds"] == nil, controller.status?.phase == "signed-out" {
                result["phaseTitleSeconds"] = Date().timeIntervalSince(start)
            }
            let state = await evaluate(controller, CacheScripts.state, timeout: 5) as? [String: Any]
            if state?["loginScreen"] as? Bool == true {
                result["loginScreenSeconds"] = Date().timeIntervalSince(start)
                return result
            }
            await pause(0.5)
        }
        result["timedOut"] = true
        result["diagnostics"] = await evaluate(controller, CacheScripts.state, timeout: 10) ?? NSNull()
        return result
    }

    private func interceptionSummary() -> [String: Any] {
        let stats = CefPackInterception.shared.statistics
        return [
            "active": CefPackInterception.shared.isActive,
            "served": stats.served,
            "fellBack": stats.fellBack,
            "servedMB": Double(stats.bytesServed) / 1_048_576,
            "servedBySource": stats.servedBySource,
        ]
    }

    private func cacheSummary() -> [String: Any] {
        guard let cache = app.services.cacheIfCreated else { return ["created": false] }
        let counters = cache.counters
        return [
            "created": true,
            "diskMB": Double(counters.diskBytes) / 1_048_576,
            "packs": counters.packs,
            "servedFromDiskMB": Double(counters.servedFromDisk) / 1_048_576,
            "downloadedMB": Double(counters.downloaded) / 1_048_576,
            "failures": counters.failures,
            "footer": app.main.footerText,
            "packIndexes": packIndexes(),
            "packcacheFolderExists": FileManager.default.fileExists(atPath: app.services.paths.packCache.path),
        ]
    }

    private func packcacheFolderExists() -> Bool {
        FileManager.default.fileExists(atPath: app.services.paths.packCache.path)
    }

    private func packIndexes() -> [[String: Any]] {
        let directory = app.services.paths.packCache
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".bin.index") }.sorted()
        return names.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)), data.count >= 21 + 32 else { return nil }
            func int64(_ offset: Int) -> Int64 {
                (0..<8).reduce(Int64(0)) { $0 | Int64(data[offset + $1]) << Int64(8 * $1) }
            }
            let total = int64(8)
            let count = Int((0..<4).reduce(0) { $0 | Int(data[17 + $1]) << (8 * $1) })
            var covered: Int64 = 0
            for index in 0..<count {
                covered += int64(21 + index * 16 + 8) - int64(21 + index * 16)
            }
            return ["pack": String(name.dropLast(6)), "totalBytes": total, "coveredBytes": covered, "complete": covered == total, "verified": data[16] == 1, "ranges": count]
        }
    }

    private func allocatedBytes(_ url: URL) -> [String: Any] {
        var allocated: Int64 = 0
        var logical: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                allocated += Int64(values.totalFileAllocatedSize ?? 0)
                logical += Int64(values.fileSize ?? 0)
            }
        }
        return ["allocatedMB": Double(allocated) / 1_048_576, "logicalMB": Double(logical) / 1_048_576]
    }

    private func diskSummary() -> [String: Any] {
        var profiles: [String: Any] = [:]
        for account in store.accounts {
            profiles[account.name] = allocatedBytes(app.services.profiles.folder(for: account.dataStoreId))
        }
        return ["packcache": allocatedBytes(app.services.paths.packCache), "accountProfiles": profiles]
    }

    private func loadMetrics(from start: Date, to end: Date) -> [String: Any] {
        ["cpu": recorder.summary(from: start, to: end), "memory": recorder.peaks(from: start, to: end)]
    }

    private func hiddenCpu(_ windows: [GameWindowController]) async -> [String: Any] {
        windows.forEach { $0.hide() }
        await pause(8)
        let before = CefPackInterception.shared.statistics.served
        let begin = Date()
        await pause(30)
        let end = Date()
        let summary = recorder.summary(from: begin, to: end)
        var pages: [String: Any] = [:]
        for window in windows {
            let state = await evaluate(window, CacheScripts.state, timeout: 5) as? [String: Any]
            pages[window.accountName] = state?["visibility"] ?? NSNull()
        }
        return ["cpu": summary, "visibility": pages, "servedDuringMeasure": CefPackInterception.shared.statistics.served - before]
    }

    private func pageFetch(_ controller: GameWindowController, key: String, pack: String, range: String) async -> [String: Any] {
        _ = await evaluate(controller, CacheScripts.startFetch(key: key, name: pack, range: range), timeout: 10)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let state = await evaluate(controller, CacheScripts.readFetch(key: key), timeout: 10) as? [String: Any],
               let name = state["state"] as? String, name != "pending", name != "missing" {
                return state
            }
            await pause(0.5)
        }
        return ["state": "timeout"]
    }

    private func directHash(pack: String, range: ByteRange) async -> String? {
        guard let fetched = try? await URLSessionRangeFetcher().fetch(url: AssetUrl.packUrl(for: pack), range: range) else { return nil }
        return SHA256.hash(data: fetched.bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func correctness(on controller: GameWindowController, pack: String) async -> [String: Any] {
        let probe = await pageFetch(controller, key: "probe", pack: pack, range: "bytes=0-0")
        guard let contentRange = probe["contentRange"] as? String, let total = Int64(contentRange.split(separator: "/").last ?? "") else {
            return ["error": "no total", "probe": probe]
        }
        let ranges = [(0, 65535), (1_048_576, 2_097_151), (4_000_000, 9_000_000), (Int(total) - 4096, Int(total) - 1)]
        var cases: [[String: Any]] = []
        for (index, bounds) in ranges.enumerated() {
            let range = ByteRange(start: Int64(bounds.0), end: Int64(bounds.1))
            let before = CefPackInterception.shared.statistics.served
            let first = await pageFetch(controller, key: "first\(index)", pack: pack, range: range.header)
            let servedFirst = CefPackInterception.shared.statistics.served - before
            let second = await pageFetch(controller, key: "second\(index)", pack: pack, range: range.header)
            let servedBoth = CefPackInterception.shared.statistics.served - before
            let direct = await directHash(pack: pack, range: range)
            cases.append([
                "range": range.header,
                "bytes": range.length,
                "status": first["status"] ?? NSNull(),
                "contentRange": first["contentRange"] ?? NSNull(),
                "acceptRanges": first["acceptRanges"] ?? NSNull(),
                "contentLength": first["contentLength"] ?? NSNull(),
                "firstMatchesDirect": direct != nil && first["sha"] as? String == direct,
                "secondMatchesDirect": direct != nil && second["sha"] as? String == direct,
                "servedByInterceptionFirst": servedFirst,
                "servedByInterceptionBoth": servedBoth,
            ])
        }
        return ["total": total, "cases": cases]
    }

    private func clearCache() {
        let directory = app.services.paths.packCache
        let before = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count
        let footerBefore = app.main.footerText
        app.main.performClearSharedCache()
        let after = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count
        summary["clear"] = ["filesBefore": before, "filesAfter": after, "footerBefore": footerBefore, "footerAfter": app.main.footerText]
    }

    private func probeResponses() async {
        guard let account = addAccount("alpha", index: 0) else { return }
        app.main.refreshAll()
        manager.startOrShow(account.id, light: false)
        guard let controller = window("alpha") else {
            summary["error"] = "window did not open"
            return
        }
        _ = await waitUntil(timeout: 60, interval: 1) { controller.status?.phase == "signed-out" }
        let pack = "game-audio-003-fad21743ef36.bin"
        summary["pack"] = pack
        summary["correctness"] = await correctness(on: controller, pack: pack)
        summary["raw"] = await pageFetch(controller, key: "raw", pack: pack, range: "bytes=100-199")
        summary["interception"] = interceptionSummary()
        _ = manager.closeAll(prompt: false)
        await pause(2)
    }

    private func singleAccount(name: String, hide: Bool) async {
        guard let account = addAccount(name, index: 0) else { return }
        app.main.refreshAll()
        let began = Date()
        manager.startOrShow(account.id, light: false)
        guard let controller = window(name) else {
            summary["error"] = "window did not open"
            return
        }
        let timing = await timings(controller, since: began)
        await pause(6)
        let loadEnd = Date()
        var result: [String: Any] = ["timings": timing, "status": controller.status?.phase ?? NSNull()]
        result["load"] = loadMetrics(from: began, to: loadEnd)
        result["interceptionAtLoad"] = interceptionSummary()
        result["fetcherAtLoad"] = fetcher?.summary ?? [:]
        summary["account"] = result
        summary["logLines"] = app.services.log.recent.map(\.text).filter { $0.contains("cache") || $0.contains("download") || $0.contains("shared") }
        if hide {
            summary["hidden"] = await hiddenCpu([controller])
        }
        controller.show(activate: false)
        _ = manager.closeAll(prompt: false)
        await pause(2)
    }

    private func twoAccounts() async {
        guard let first = addAccount("alpha", index: 0), let second = addAccount("beta", index: 1) else { return }
        app.main.refreshAll()
        let beganA = Date()
        manager.startOrShow(first.id, light: false)
        guard let alpha = window("alpha") else { return }
        let timingA = await timings(alpha, since: beganA)
        await pause(6)
        summary["alpha"] = [
            "timings": timingA,
            "interceptionAfter": interceptionSummary(),
            "cacheAfter": cacheSummary(),
            "fetcherAfter": fetcher?.summary ?? [:],
            "load": loadMetrics(from: beganA, to: Date()),
        ] as [String: Any]
        await pause(max(0, 16 - Date().timeIntervalSince(beganA)))
        let before = CefPackInterception.shared.statistics
        let fetcherBefore = fetcher?.summary ?? [:]
        let beganB = Date()
        manager.startOrShow(second.id, light: false)
        _ = await waitUntil(timeout: 30) { window("beta") != nil }
        guard let beta = window("beta") else { return }
        let timingB = await timings(beta, since: beganB)
        await pause(6)
        let after = CefPackInterception.shared.statistics
        summary["beta"] = [
            "timings": timingB,
            "servedByInterceptionDuring": after.served - before.served,
            "fellBackDuring": after.fellBack - before.fellBack,
            "fetcherBefore": fetcherBefore,
            "fetcherAfter": fetcher?.summary ?? [:],
            "cacheAfter": cacheSummary(),
            "load": loadMetrics(from: beganB, to: Date()),
        ] as [String: Any]
        if let pack = app.services.cacheIfCreated?.packNames.first {
            summary["correctnessPack"] = pack
            summary["correctness"] = await correctness(on: beta, pack: pack)
        }
        summary["logLines"] = app.services.log.recent.map(\.text).filter { $0.contains("cache") || $0.contains("download") || $0.contains("hash") || $0.contains("shared") }
        summary["hidden"] = await hiddenCpu([alpha, beta])
        _ = manager.closeAll(prompt: false)
        await pause(2)
    }

    private func completeOnePack() async {
        let cache = app.services.sharedCache()
        guard let pack = cache.packNames.filter({ $0.hasPrefix("particle-textures") }).first ?? cache.packNames.min(by: { $0.count < $1.count }) else {
            summary["error"] = "no pack in the cache"
            return
        }
        cache.flushAll()
        let indexUrl = app.services.paths.packCache.appendingPathComponent(pack + ".index")
        guard let index = try? Data(contentsOf: indexUrl), index.count >= 53 else {
            summary["error"] = "no index"
            return
        }
        func int64(_ offset: Int) -> Int64 {
            (0..<8).reduce(Int64(0)) { $0 | Int64(index[offset + $1]) << Int64(8 * $1) }
        }
        let total = int64(8)
        let count = (0..<4).reduce(0) { $0 | Int(index[17 + $1]) << (8 * $1) }
        var gaps: [ByteRange] = []
        var position: Int64 = 0
        for item in 0..<count {
            let start = int64(21 + item * 16)
            let end = int64(21 + item * 16 + 8)
            if start > position { gaps.append(ByteRange(start: position, end: start - 1)) }
            position = end
        }
        if position < total { gaps.append(ByteRange(start: position, end: total - 1)) }
        let before = cache.counters
        var requests = 0
        for gap in gaps {
            var from = gap.start
            while from <= gap.end {
                let to = min(from + (8 << 20) - 1, gap.end)
                _ = await cache.get(url: AssetUrl.packUrl(for: pack), pack: pack, range: ByteRange(start: from, end: to))
                requests += 1
                from = to + 1
            }
        }
        await pause(4)
        cache.flushAll()
        let after = cache.counters
        let file = app.services.paths.packCache.appendingPathComponent(pack)
        var hasher = SHA256()
        if let handle = try? FileHandle(forReadingFrom: file) {
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            try? handle.close()
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        summary["verify"] = [
            "pack": pack,
            "totalBytes": total,
            "gapsBytes": gaps.reduce(Int64(0)) { $0 + $1.length },
            "requests": requests,
            "downloadedMB": Double(after.downloaded - before.downloaded) / 1_048_576,
            "failures": after.failures,
            "indexAfter": packIndexes().first { $0["pack"] as? String == pack } ?? [:],
            "independentSha256MatchesName": hash.hasPrefix(AssetUrl.hashPrefix(pack)),
            "logLines": app.services.log.recent.map(\.text).filter { $0.contains("hash") },
        ] as [String: Any]
    }

    private func threeAtOnce() async {
        var controllers: [GameWindowController] = []
        var starts: [Date] = []
        let accounts = ["alpha", "beta", "gamma"].enumerated().compactMap { index, name in addAccount(name, index: index) }
        app.main.refreshAll()
        let began = Date()
        for (index, account) in accounts.enumerated() {
            let controller = GameWindowController(services: app.services, account: account, light: false, cascadeIndex: index)
            controllers.append(controller)
            starts.append(Date())
            controller.start()
            controller.show(activate: false)
        }
        var timings: [[String: Any]] = []
        for (index, controller) in controllers.enumerated() {
            timings.append(await self.timings(controller, since: starts[index]))
        }
        await pause(6)
        summary["three"] = [
            "timings": timings,
            "load": loadMetrics(from: began, to: Date()),
        ] as [String: Any]
        summary["logLines"] = app.services.log.recent.map(\.text).filter { $0.contains("cache") || $0.contains("download") || $0.contains("shared") }
        controllers.forEach { $0.closeWithoutPrompt() }
        await pause(2)
    }
}
