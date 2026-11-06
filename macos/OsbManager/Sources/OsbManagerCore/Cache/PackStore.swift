import CryptoKit
import Darwin
import Foundation

struct PackStoreError: Error, Equatable {
    let message: String
}

final class PackStore {
    private static let indexMagic: UInt32 = 0x4950_4D53
    private static let indexVersion: Int32 = 1
    private static let digestLength = 32

    let name: String
    let total: Int64
    let dataUrl: URL

    private let descriptor: Int32
    private let indexUrl: URL
    private let lock = NSLock()
    private var stored = IntervalSet()
    private var dirty = false
    private var isVerified = false
    private var closed = false

    private init(name: String, total: Int64, descriptor: Int32, dataUrl: URL, indexUrl: URL) {
        self.name = name
        self.total = total
        self.descriptor = descriptor
        self.dataUrl = dataUrl
        self.indexUrl = indexUrl
    }

    var verified: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isVerified
    }

    var storedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return stored.coveredBytes
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored.contains(0, total)
    }

    static func create(directory: URL, name: String, total: Int64) throws -> PackStore {
        let (dataUrl, indexUrl) = urls(directory, name)
        try? FileManager.default.removeItem(at: indexUrl)
        let descriptor = open(dataUrl.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw PackStoreError(message: "Could not create \(name): errno \(errno).") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw PackStoreError(message: "Could not prepare \(name): errno \(errno).")
        }
        return PackStore(name: name, total: total, descriptor: descriptor, dataUrl: dataUrl, indexUrl: indexUrl)
    }

    static func tryOpen(directory: URL, name: String) -> PackStore? {
        let (dataUrl, indexUrl) = urls(directory, name)
        let index: (total: Int64, verified: Bool, ranges: [Interval])
        do {
            index = try readIndex(indexUrl)
        } catch {
            tryDelete(directory: directory, name: name)
            return nil
        }
        let descriptor = open(dataUrl.path, O_RDWR)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                tryDelete(directory: directory, name: name)
            }
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        var info = stat()
        let end = index.ranges.last?.end ?? 0
        guard fstat(descriptor, &info) == 0, Int64(info.st_size) >= end else {
            close(descriptor)
            tryDelete(directory: directory, name: name)
            return nil
        }
        let pack = PackStore(name: name, total: index.total, descriptor: descriptor, dataUrl: dataUrl, indexUrl: indexUrl)
        pack.isVerified = index.verified
        for range in index.ranges {
            pack.stored.add(range.start, range.end)
        }
        return pack
    }

    static func delete(directory: URL, name: String) {
        let (dataUrl, indexUrl) = urls(directory, name)
        try? FileManager.default.removeItem(at: indexUrl)
        try? FileManager.default.removeItem(at: dataUrl)
    }

    func has(_ range: ByteRange) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return range.end < total && stored.contains(range.start, range.endExclusive)
    }

    func tryRead(_ range: ByteRange) -> Data? {
        guard has(range), range.length <= Int64(Int32.max) else { return nil }
        var buffer = Data(count: Int(range.length))
        var read = 0
        let length = buffer.count
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while read < length {
                let count = pread(descriptor, base + read, length - read, off_t(range.start) + off_t(read))
                if count <= 0 { return false }
                read += count
            }
            return true
        }
        return ok ? buffer : nil
    }

    func write(_ range: ByteRange, _ data: Data) throws {
        guard Int64(data.count) == range.length, range.end < total else {
            throw PackStoreError(message: "The data does not fit the pack.")
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = pwrite(descriptor, base + written, data.count - written, off_t(range.start) + off_t(written))
                if count <= 0 { throw PackStoreError(message: "Could not write \(name): errno \(errno).") }
                written += count
            }
        }
        lock.lock()
        stored.add(range.start, range.endExclusive)
        dirty = true
        lock.unlock()
    }

    func verifyComplete() -> Bool {
        guard isComplete else { return false }
        var hasher = SHA256()
        let chunk = 1 << 20
        var position: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunk)
        while position < total {
            let want = Int(min(Int64(chunk), total - position))
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, want, off_t(position)) }
            if count <= 0 { return false }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            position += Int64(count)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let valid = hash.hasPrefix(AssetUrl.hashPrefix(name))
        if valid {
            lock.lock()
            isVerified = true
            dirty = true
            lock.unlock()
        }
        return valid
    }

    func flush() throws {
        lock.lock()
        guard dirty, !closed else {
            lock.unlock()
            return
        }
        let snapshot = stored.items
        let verified = isVerified
        dirty = false
        lock.unlock()
        do {
            if fsync(descriptor) != 0 {
                throw PackStoreError(message: "Could not flush the cache file: errno \(errno).")
            }
            try Self.writeIndex(indexUrl, total: total, verified: verified, ranges: snapshot)
        } catch {
            lock.lock()
            dirty = true
            lock.unlock()
            throw error
        }
    }

    func dispose() {
        try? flush()
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    private static func urls(_ directory: URL, _ name: String) -> (URL, URL) {
        (directory.appendingPathComponent(name), directory.appendingPathComponent(name + ".index"))
    }

    private static func tryDelete(directory: URL, name: String) {
        delete(directory: directory, name: name)
    }

    private static func writeIndex(_ url: URL, total: Int64, verified: Bool, ranges: [Interval]) throws {
        var body = Data()
        body.append(littleEndian: indexMagic)
        body.append(littleEndian: indexVersion)
        body.append(littleEndian: total)
        body.append(UInt8(verified ? 1 : 0))
        body.append(littleEndian: Int32(ranges.count))
        for range in ranges {
            body.append(littleEndian: range.start)
            body.append(littleEndian: range.end)
        }
        body.append(contentsOf: SHA256.hash(data: body))
        try body.write(to: url, options: .atomic)
    }

    private static func readIndex(_ url: URL) throws -> (total: Int64, verified: Bool, ranges: [Interval]) {
        let bytes = try Data(contentsOf: url)
        guard bytes.count >= digestLength + 21 else { throw PackStoreError(message: "The cache index is too short.") }
        let content = bytes.prefix(bytes.count - digestLength)
        guard Data(SHA256.hash(data: content)) == bytes.suffix(digestLength) else {
            throw PackStoreError(message: "The cache index checksum does not match.")
        }
        var reader = IndexReader(data: Data(content))
        guard try reader.uint32() == indexMagic, try reader.int32() == indexVersion else {
            throw PackStoreError(message: "Unknown cache index format.")
        }
        let total = try reader.int64()
        let verified = try reader.byte() != 0
        let count = try reader.int32()
        guard total > 0, total <= ByteRange.maxLength * 4, count >= 0, count <= 1_000_000 else {
            throw PackStoreError(message: "The cache index header is out of range.")
        }
        var ranges: [Interval] = []
        var previousEnd: Int64 = -1
        for _ in 0..<Int(count) {
            let start = try reader.int64()
            let end = try reader.int64()
            guard start > previousEnd, end > start, end <= total else {
                throw PackStoreError(message: "The cache index ranges are invalid.")
            }
            ranges.append(Interval(start, end))
            previousEnd = end
        }
        return (total, verified, ranges)
    }
}

private struct IndexReader {
    let data: Data
    var position = 0

    init(data: Data) {
        self.data = data
    }

    mutating func byte() throws -> UInt8 {
        guard position < data.count else { throw PackStoreError(message: "The cache index ended early.") }
        defer { position += 1 }
        return data[data.startIndex + position]
    }

    mutating func uint32() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            value |= UInt32(try byte()) << UInt32(shift)
        }
        return value
    }

    mutating func int32() throws -> Int32 {
        Int32(bitPattern: try uint32())
    }

    mutating func int64() throws -> Int64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            value |= UInt64(try byte()) << UInt64(shift)
        }
        return Int64(bitPattern: value)
    }
}

private extension Data {
    mutating func append<Value: FixedWidthInteger>(littleEndian value: Value) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
