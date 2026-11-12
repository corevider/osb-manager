import Darwin
import Foundation

final class FakeHttpServer: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String: String] = [:]
    private var statuses: [String: Int] = [:]
    private var gates: [String: DispatchSemaphore] = [:]
    private var arrived: [String: DispatchSemaphore] = [:]
    private var seen: [String] = []
    private var stopped = false
    private let listener: Int32
    let port: UInt16

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FakeHttpServerError.socket }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            close(descriptor)
            throw FakeHttpServerError.socket
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        listener = descriptor
        port = UInt16(bigEndian: assigned.sin_port)
        Thread.detachNewThread { [weak self] in self?.acceptLoop(descriptor) }
    }

    var base: String { "http://127.0.0.1:\(port)" }

    func serve(_ path: String, _ body: String, status: Int = 200) {
        lock.lock()
        defer { lock.unlock() }
        bodies[path] = body
        statuses[path] = status
    }

    func hold(_ path: String) -> (arrived: DispatchSemaphore, release: DispatchSemaphore) {
        lock.lock()
        defer { lock.unlock() }
        let release = DispatchSemaphore(value: 0)
        let reached = DispatchSemaphore(value: 0)
        gates[path] = release
        arrived[path] = reached
        return (reached, release)
    }

    func count(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.filter { $0 == path }.count
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        if !already {
            Thread.sleep(forTimeInterval: 0.25)
            close(listener)
        }
    }

    deinit {
        stop()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(_ descriptor: Int32) {
        while !isStopped {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0, !isStopped else { continue }
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else { continue }
            DispatchQueue.global().async { [weak self] in self?.handle(connection) }
        }
    }

    private func handle(_ connection: Int32) {
        defer { close(connection) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !received.suffix(4).elementsEqual([13, 10, 13, 10]) && received.count < 65536 {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            received.append(contentsOf: buffer[0..<count])
        }
        let line = String(decoding: received, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"
        lock.lock()
        seen.append(path)
        let gate = gates[path]
        let reached = arrived[path]
        lock.unlock()
        reached?.signal()
        gate?.wait()
        gate?.signal()
        lock.lock()
        let body = bodies[path]
        let status = statuses[path] ?? 404
        lock.unlock()
        let payload = Data((body ?? "").utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\nContent-Type: text/javascript; charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(payload)
        response.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let written = write(connection, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if written <= 0 { break }
                sent += written
            }
        }
    }
}

enum FakeHttpServerError: Error {
    case socket
}
