import CefBridge
import Foundation
import OsbManagerCore

public struct PackInterceptionStats: Equatable, Sendable {
    public var served = 0
    public var fellBack = 0
    public var bytesServed: Int64 = 0
    public var servedBySource: [String: Int] = [:]
}

public final class CefPackInterception: NSObject, SroCefPackProvider, @unchecked Sendable {
    public static let shared = CefPackInterception()

    private let lock = NSLock()
    private var cache: SharedAssetCache?
    private var counts = PackInterceptionStats()

    public var isActive: Bool {
        lock.withLock { cache != nil }
    }

    public var statistics: PackInterceptionStats {
        lock.withLock { counts }
    }

    public func use(_ cache: SharedAssetCache?) {
        lock.withLock { self.cache = cache }
    }

    public func resetStatistics() {
        lock.withLock { counts = PackInterceptionStats() }
    }

    public func wantsMethod(_ method: String, url: String, rangeHeader: String?) -> Bool {
        guard isActive else { return false }
        return PackRequest.match(method: method, url: url, rangeHeader: rangeHeader) != nil
    }

    public func serveUrl(_ url: String, rangeHeader: String, source: String, completion: @escaping (Data?, [String: String]?) -> Void) {
        guard let cache = lock.withLock({ self.cache }),
              let request = PackRequest.match(method: "GET", url: url, rangeHeader: rangeHeader) else {
            recordFallback()
            completion(nil, nil)
            return
        }
        Task.detached { [self] in
            if let cached = await cache.get(url: request.url, pack: request.pack, range: request.range),
               PackResponse.isServable(cached, for: request.range) {
                recordServed(bytes: Int64(cached.bytes.count), source: source)
                completion(cached.bytes, PackResponse.headers(range: request.range, total: cached.total))
            } else {
                recordFallback()
                completion(nil, nil)
            }
        }
    }

    private func recordServed(bytes: Int64, source: String) {
        lock.withLock {
            counts.served += 1
            counts.bytesServed += bytes
            counts.servedBySource[source, default: 0] += 1
        }
    }

    private func recordFallback() {
        lock.withLock { counts.fellBack += 1 }
    }
}
