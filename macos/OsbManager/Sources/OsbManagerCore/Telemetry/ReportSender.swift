import Foundation

public enum ReportResult: Equatable, Sendable {
    case sent
    case queued
    case queueFull
    case tooLarge
    case notSaved
    case rejected
    case cancelled
}

public struct ReportOutcome: Equatable, Sendable {
    public var result: ReportResult
    public var code: String?
    public var anonymous: Bool
    public var detail: String?

    public init(result: ReportResult, code: String? = nil, anonymous: Bool = true, detail: String? = nil) {
        self.result = result
        self.code = code
        self.anonymous = anonymous
        self.detail = detail
    }
}

public final class ReportSender: @unchecked Sendable {
    private let client: TelemetryClient
    private let settings: PrivacySettings
    private let outbox: ReportOutbox
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double

    public init(client: TelemetryClient, settings: PrivacySettings, outbox: ReportOutbox, now: @escaping @Sendable () -> Date, random: @escaping @Sendable () -> Double) {
        self.client = client
        self.settings = settings
        self.outbox = outbox
        self.now = now
        self.random = random
    }

    public var wouldBeAnonymous: Bool { credentials(forceAnonymous: false) == nil }

    public func sendNew(reportJson: Data, screenshot: Data?) async -> ReportOutcome {
        let auth = credentials(forceAnonymous: false)
        let anonymous = auth == nil
        if reportsSwitchedOff() {
            return enqueue(reportJson, screenshot, anonymous, "reports are switched off by the server")
        }
        let response = await client.sendReport(credentials: auth, reportJson: reportJson, screenshot: screenshot)
        if response.succeeded {
            return ReportOutcome(result: .sent, code: Self.code(response.body), anonymous: anonymous)
        }
        if response.outcome == .cancelled {
            return ReportOutcome(result: .cancelled, anonymous: anonymous)
        }
        if response.outcome == .httpError, [400, 403, 404, 413, 415].contains(response.statusCode) {
            return ReportOutcome(result: .rejected, anonymous: anonymous, detail: "HTTP \(response.statusCode)")
        }
        return enqueue(reportJson, screenshot, anonymous || response.isStatus(401), Self.describe(response))
    }

    public func trySendQueued(_ entry: OutboxEntry) async -> Bool {
        let auth = credentials(forceAnonymous: entry.anonymous)
        let anonymous = auth == nil
        if reportsSwitchedOff() {
            outbox.recordAttempt(id: entry.id, retryIn: Backoff.next(failures: entry.attempts + 1, random: random()).seconds, note: "reports are switched off by the server", anonymous: anonymous)
            return false
        }
        let screenshot = outbox.screenshot(for: entry, failed: false)
        let response = await client.sendReport(credentials: auth, reportJson: Data(entry.reportJson.utf8), screenshot: screenshot)
        if response.succeeded {
            outbox.remove(id: entry.id)
            return true
        }
        if response.outcome == .cancelled { return false }
        if response.outcome == .httpError, [400, 403, 404, 413, 415].contains(response.statusCode) {
            outbox.remove(id: entry.id)
            return false
        }
        let retryIn: Duration = response.outcome == .httpError && (response.statusCode == 429 || response.statusCode == 503)
            ? Backoff.retryAfter(response.retryAfter, random: random(), failures: entry.attempts + 1)
            : Backoff.next(failures: entry.attempts + 1, random: random())
        outbox.recordAttempt(id: entry.id, retryIn: retryIn.seconds, note: Self.describe(response), anonymous: anonymous || response.isStatus(401))
        return false
    }

    private func credentials(forceAnonymous: Bool) -> InstallCredentials? {
        let state = settings.state
        return !forceAnonymous && state.granted && state.registered ? settings.credentials : nil
    }

    private func reportsSwitchedOff() -> Bool {
        let state = settings.state
        guard let config = state.config, let fetched = state.configFetchedAt else { return false }
        return now().timeIntervalSince(fetched) < TelemetryLimits.configMaxAge && (!config.reportsEnabled || !config.clientOk)
    }

    private func enqueue(_ reportJson: Data, _ screenshot: Data?, _ anonymous: Bool, _ note: String) -> ReportOutcome {
        let retryIn = Backoff.next(failures: 1, random: random()).seconds
        switch outbox.enqueue(reportJson: reportJson, screenshot: screenshot, anonymous: anonymous, retryIn: retryIn, note: note).outcome {
        case .full: return ReportOutcome(result: .queueFull, anonymous: anonymous, detail: note)
        case .tooLarge: return ReportOutcome(result: .tooLarge, anonymous: anonymous, detail: note)
        case .failed: return ReportOutcome(result: .notSaved, anonymous: anonymous, detail: note)
        case .queued: return ReportOutcome(result: .queued, anonymous: anonymous, detail: note)
        }
    }

    private static func describe(_ response: ApiResponse) -> String {
        switch response.outcome {
        case .httpError: return "HTTP \(response.statusCode)"
        case .timeout: return "timed out"
        case .busy: return "another request was running"
        default: return "server unreachable"
        }
    }

    private static func code(_ body: Data) -> String? {
        guard let root = StrictJson.object(body, maxDepth: 4), let code = root["code"] as? String,
              !code.isEmpty, code.count <= 20,
              code.unicodeScalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0 == "-" })
        else { return nil }
        return code
    }
}
