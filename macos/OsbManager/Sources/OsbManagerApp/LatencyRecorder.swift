#if DEBUG
import Foundation

public final class LatencyRecorder: @unchecked Sendable {
    nonisolated(unsafe) public static var shared: LatencyRecorder?

    private let lock = NSLock()
    private let handle: FileHandle?
    private let started = DispatchTime.now().uptimeNanoseconds
    private var lastFire: UInt64 = 0
    private var buffer: [String] = []
    private var probe: DispatchSourceTimer?

    public init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    public func recordTimerFire() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let previous = lastFire
        lastFire = now
        lock.unlock()
        guard previous != 0 else { return }
        let lateness = max(0, Double(now - previous) / 1_000_000 - 1000)
        add("timer", lateness, at: now)
    }

    public func recordMessage(since start: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        add("message", Double(now - start) / 1_000_000, at: now)
    }

    public func startProbe() {
        let queue = DispatchQueue(label: "osb.latency.probe", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            let posted = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let now = DispatchTime.now().uptimeNanoseconds
                self?.add("hop", Double(now - posted) / 1_000_000, at: now)
            }
        }
        timer.resume()
        probe = timer
    }

    public func flush() {
        lock.lock()
        let lines = buffer
        buffer.removeAll()
        lock.unlock()
        guard !lines.isEmpty, let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        try? handle?.write(contentsOf: data)
    }

    private func add(_ kind: String, _ milliseconds: Double, at now: UInt64) {
        let seconds = Double(now - started) / 1_000_000_000
        lock.lock()
        buffer.append("{\"k\":\"\(kind)\",\"t\":\(String(format: "%.3f", seconds)),\"ms\":\(String(format: "%.3f", milliseconds))}")
        let full = buffer.count >= 200
        lock.unlock()
        if full { flush() }
    }
}
#endif
