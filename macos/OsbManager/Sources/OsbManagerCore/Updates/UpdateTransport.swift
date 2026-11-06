import Foundation

public struct UpdateHop: Sendable {
    public let status: Int
    public let location: String?

    public init(status: Int, location: String? = nil) {
        self.status = status
        self.location = location
    }
}

public protocol UpdateTransport: Sendable {
    func send(_ request: URLRequest, limit: Int64, timeout: TimeInterval, sink: @escaping @Sendable (Data) throws -> Void) async throws -> UpdateHop
}

public final class UrlSessionUpdateTransport: UpdateTransport {
    public static let idleTimeout: TimeInterval = 30

    public init() {}

    public static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = min(idleTimeout, timeout)
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = nil
        return configuration
    }

    public func send(_ request: URLRequest, limit: Int64, timeout: TimeInterval, sink: @escaping @Sendable (Data) throws -> Void) async throws -> UpdateHop {
        let delegate = SingleHopDelegate(limit: limit, sink: sink)
        let session = URLSession(configuration: Self.configuration(timeout: timeout), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(session.dataTask(with: request), continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

private final class SingleHopDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int64
    private let sink: @Sendable (Data) throws -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UpdateHop, Error>?
    private var task: URLSessionTask?
    private var hop: UpdateHop?
    private var failure: Error?
    private var received: Int64 = 0

    init(limit: Int64, sink: @escaping @Sendable (Data) throws -> Void) {
        self.limit = limit
        self.sink = sink
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<UpdateHop, Error>) {
        lock.withLock {
            self.task = task
            self.continuation = continuation
        }
        task.resume()
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(UpdateError("The answer was not HTTP."))
            completionHandler(.cancel)
            return
        }
        let result = UpdateHop(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"))
        lock.withLock { hop = result }
        if http.statusCode != 200 {
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > limit {
            fail(UpdateError("\(response.url?.host ?? "The server") offered \(http.expectedContentLength) bytes, more than the \(limit) allowed."))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let total: Int64 = lock.withLock {
            received += Int64(data.count)
            return received
        }
        if total > limit {
            fail(UpdateError("\(dataTask.currentRequest?.url?.host ?? "The server") sent more than the \(limit) bytes allowed."))
            dataTask.cancel()
            return
        }
        do {
            try sink(data)
        } catch {
            fail(error)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, hop, failure) = lock.withLock { () -> (CheckedContinuation<UpdateHop, Error>?, UpdateHop?, Error?) in
            let pending = self.continuation
            self.continuation = nil
            return (pending, self.hop, self.failure)
        }
        guard let continuation else { return }
        if let failure {
            continuation.resume(throwing: failure)
        } else if let hop, hop.status != 200 {
            continuation.resume(returning: hop)
        } else if let error {
            continuation.resume(throwing: error)
        } else if let hop {
            continuation.resume(returning: hop)
        } else {
            continuation.resume(throwing: UpdateError("The request ended without an answer."))
        }
    }

    private func fail(_ error: Error) {
        lock.withLock {
            if failure == nil {
                failure = error
            }
        }
    }
}

public struct UpdateHttp: Sendable {
    public static let maxRedirects = 5

    private let transport: UpdateTransport
    private let hosts: UpdateHosts
    private let userAgent: String

    public init(transport: UpdateTransport, hosts: UpdateHosts = .gitHub, userAgent: String) {
        self.transport = transport
        self.hosts = hosts
        self.userAgent = userAgent
    }

    public func data(_ url: URL, limit: Int64, timeout: TimeInterval, accept: String) async throws -> Data {
        let buffer = DataBuffer()
        try await fetch(url, limit: limit, timeout: timeout, accept: accept) { buffer.append($0) }
        return buffer.data
    }

    public func download(_ url: URL, to file: URL, limit: Int64, timeout: TimeInterval, accept: String) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try await fetch(url, limit: limit, timeout: timeout, accept: accept) { try handle.write(contentsOf: $0) }
    }

    public func fetch(_ url: URL, limit: Int64, timeout: TimeInterval, accept: String, sink: @escaping @Sendable (Data) throws -> Void) async throws {
        var current = url
        let deadline = Date().addingTimeInterval(timeout)
        for hop in 0... {
            guard hosts.allows(current) else {
                throw UpdateError(hop == 0 ? "Refused to contact \(Self.describe(current))." : "Refused a redirect to \(Self.describe(current)).")
            }
            var request = URLRequest(url: current, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(accept, forHTTPHeaderField: "Accept")
            if current.host?.lowercased() == "api.github.com" {
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw UpdateError("The request to \(url.host ?? "GitHub") timed out.") }
            let answer: UpdateHop
            do {
                answer = try await transport.send(request, limit: limit, timeout: remaining, sink: sink)
            } catch let error as UpdateError {
                throw error
            } catch let error as URLError where error.code == .timedOut {
                throw UpdateError("The request to \(current.host ?? "GitHub") timed out.")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw UpdateError("The request to \(current.host ?? "GitHub") failed: \(error.localizedDescription)")
            }
            if [301, 302, 303, 307, 308].contains(answer.status) {
                guard let location = answer.location, let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw UpdateError("\(current.host ?? "GitHub") sent a redirect without a target.")
                }
                guard hop < Self.maxRedirects else { throw UpdateError("Too many redirects from \(url.host ?? "GitHub").") }
                current = next
                continue
            }
            guard answer.status == 200 else { throw UpdateError("\(current.host ?? "GitHub") answered HTTP \(answer.status).") }
            return
        }
    }

    private static func describe(_ url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else { return "a relative address" }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}

private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.withLock { storage.append(chunk) }
    }

    var data: Data { lock.withLock { storage } }
}
