import Foundation

public enum ApiOutcome: Equatable, Sendable {
    case success
    case httpError
    case networkError
    case timeout
    case busy
    case cancelled
}

public struct ApiResponse: Sendable {
    public let outcome: ApiOutcome
    public let statusCode: Int
    public let code: String?
    public let retryAfter: TimeInterval?
    public let body: Data

    public init(outcome: ApiOutcome, statusCode: Int = 0, code: String? = nil, retryAfter: TimeInterval? = nil, body: Data = Data()) {
        self.outcome = outcome
        self.statusCode = statusCode
        self.code = code
        self.retryAfter = retryAfter
        self.body = body
    }

    public static func of(_ outcome: ApiOutcome) -> ApiResponse {
        ApiResponse(outcome: outcome)
    }

    public var succeeded: Bool { outcome == .success }

    public func isStatus(_ status: Int) -> Bool {
        outcome == .httpError && statusCode == status
    }
}

public struct TelemetryClientError: Error, LocalizedError, Equatable {
    public let message: String

    public var errorDescription: String? { message }
}

final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public actor TelemetryClient {
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    private let session: URLSession
    private let baseUrl: String
    private let userAgent: String
    private let clock: SchedulerClock
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var invalidated = false
    private var running: Task<ApiResponse, Never>?

    public init(
        baseUrl: URL,
        userAgent: String,
        configuration: URLSessionConfiguration = TelemetryClient.makeConfiguration(),
        clock: SchedulerClock = .continuous
    ) throws {
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(baseUrl.host?.lowercased() ?? "")
        guard baseUrl.scheme == "https" || (baseUrl.scheme == "http" && loopback) else {
            throw TelemetryClientError(message: "The API address must use https.")
        }
        var text = baseUrl.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        self.baseUrl = text
        self.userAgent = userAgent
        self.clock = clock
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func close() {
        closed = true
        running?.cancel()
        if !busy { invalidate() }
    }

    private func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        session.invalidateAndCancel()
    }

    public func getConfig(version: String, background: Bool) async -> ApiResponse {
        var components = URLComponents(string: baseUrl + "/config")
        components?.queryItems = [URLQueryItem(name: "app", value: TelemetryLimits.appName), URLQueryItem(name: "version", value: version)]
        guard let url = components?.url else { return .of(.networkError) }
        return await send(baseRequest(url, method: "GET"), background: background)
    }

    public func register(_ credentials: InstallCredentials, version: String, locale: String, characters: Bool, background: Bool) async -> ApiResponse {
        let body: [String: Any] = [
            "install_id": credentials.id,
            "install_key": credentials.key,
            "app": TelemetryLimits.appName,
            "app_version": version,
            "os": TelemetryLimits.osName,
            "locale": locale,
            "consent": ["usage_version": TelemetryLimits.consentVersion, "characters": characters],
        ]
        guard let request = jsonRequest("installs", method: "POST", body: body, credentials: nil) else { return .of(.networkError) }
        return await send(request, background: background)
    }

    public func updateConsent(_ credentials: InstallCredentials, characters: Bool, background: Bool) async -> ApiResponse {
        let body: [String: Any] = ["usage_version": TelemetryLimits.consentVersion, "characters": characters]
        guard let request = jsonRequest("installs/me/consent", method: "PUT", body: body, credentials: credentials) else { return .of(.networkError) }
        return await send(request, background: background)
    }

    public func sendTelemetry(_ credentials: InstallCredentials, body: Data) async -> ApiResponse {
        guard var request = makeRequest("telemetry", method: "POST", credentials: credentials) else { return .of(.networkError) }
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return await send(request, background: true)
    }

    public func sendDiagnostics(_ credentials: InstallCredentials, body: Data) async -> ApiResponse {
        guard var request = makeRequest("diagnostics", method: "POST", credentials: credentials) else { return .of(.networkError) }
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return await send(request, background: true)
    }

    public func sendReport(credentials: InstallCredentials?, reportJson: Data, screenshot: Data?) async -> ApiResponse {
        guard var request = makeRequest("reports", method: "POST", credentials: credentials) else { return .of(.networkError) }
        let boundary = "osb-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipart(boundary: boundary, reportJson: reportJson, screenshot: screenshot)
        return await send(request, background: false)
    }

    public func deleteInstall(_ credentials: InstallCredentials) async -> ApiResponse {
        guard let request = makeRequest("installs/me", method: "DELETE", credentials: credentials) else { return .of(.networkError) }
        return await send(request, background: false)
    }

    public func export(_ credentials: InstallCredentials) async -> ApiResponse {
        guard let request = makeRequest("installs/me/export", method: "GET", credentials: credentials) else { return .of(.networkError) }
        return await send(request, background: false, limit: TelemetryLimits.maxExportBytes)
    }

    static func multipart(boundary: String, reportJson: Data, screenshot: Data?) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"report\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(reportJson)
        append("\r\n")
        if let screenshot {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"screenshot\"; filename=\"screenshot.png\"\r\nContent-Type: image/png\r\n\r\n")
            body.append(screenshot)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    private func makeRequest(_ relative: String, method: String, credentials: InstallCredentials?) -> URLRequest? {
        guard let url = URL(string: baseUrl + "/" + relative) else { return nil }
        var request = baseRequest(url, method: method)
        if let credentials {
            request.setValue("Bearer " + credentials.bearer, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func jsonRequest(_ relative: String, method: String, body: [String: Any], credentials: InstallCredentials?) -> URLRequest? {
        guard var request = makeRequest(relative, method: method, credentials: credentials),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes, .sortedKeys]) else {
            return nil
        }
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func baseRequest(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest, background: Bool, limit: Int = TelemetryLimits.maxResponseBytes) async -> ApiResponse {
        guard !closed else { return .of(.cancelled) }
        if background {
            guard !busy else { return .of(.busy) }
            busy = true
        } else {
            await acquire()
            if closed || Task.isCancelled {
                release()
                return .of(.cancelled)
            }
        }
        let response = await execute(request, limit: limit)
        release()
        return response
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
            if closed { invalidate() }
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func execute(_ request: URLRequest, limit: Int) async -> ApiResponse {
        guard !closed else { return .of(.cancelled) }
        let session = self.session
        let clock = self.clock
        let task = Task { await Self.race(session, request, limit: limit, clock: clock) }
        running = task
        let response = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        running = nil
        return response
    }

    private static func race(_ session: URLSession, _ request: URLRequest, limit: Int, clock: SchedulerClock) async -> ApiResponse {
        await withTaskGroup(of: ApiResponse.self) { group in
            group.addTask { await Self.perform(session, request, limit: limit) }
            group.addTask {
                do {
                    try await clock.sleep(for: TelemetryLimits.requestTimeout)
                    return .of(.timeout)
                } catch {
                    return .of(.cancelled)
                }
            }
            let first = await group.next() ?? .of(.networkError)
            group.cancelAll()
            while await group.next() != nil {}
            return first
        }
    }

    private static func perform(_ session: URLSession, _ request: URLRequest, limit: Int) async -> ApiResponse {
        do {
            var body = Data()
            let response: URLResponse
            if limit > TelemetryLimits.maxResponseBytes {
                let loaded = try await session.data(for: request)
                body = loaded.0
                response = loaded.1
            } else {
                let streamed = try await session.bytes(for: request)
                response = streamed.1
                for try await byte in streamed.0 {
                    if body.count >= limit { break }
                    body.append(byte)
                }
            }
            guard let http = response as? HTTPURLResponse else { return .of(.networkError) }
            if (200..<300).contains(http.statusCode) {
                return ApiResponse(outcome: .success, statusCode: http.statusCode, body: body)
            }
            return ApiResponse(outcome: .httpError, statusCode: http.statusCode, code: problemCode(body), retryAfter: retryAfter(http), body: body)
        } catch {
            if Task.isCancelled { return .of(.cancelled) }
            return .of(.networkError)
        }
    }

    private static func problemCode(_ body: Data) -> String? {
        guard !body.isEmpty, let root = StrictJson.object(body, maxDepth: 4), let code = root["code"] as? String, code.count <= 40 else { return nil }
        return code
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds.isFinite { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { $0.timeIntervalSinceNow }
    }
}
