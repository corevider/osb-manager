import Foundation

public final class WindowOrdinals: @unchecked Sendable {
    private let lock = NSLock()
    private var ordinals: [String: Int] = [:]

    public init() {}

    public func of(_ accountId: String) -> Int? {
        lock.withLock {
            if let known = ordinals[accountId] { return known }
            let next = ordinals.count + 1
            guard next <= DiagnosticFormats.maxEach else { return nil }
            ordinals[accountId] = next
            return next
        }
    }
}

public final class DiagnosticsCapture: @unchecked Sendable {
    public static let pageReadLead: TimeInterval = 120
    public static let pageReadTimeout: TimeInterval = 10

    public let hub: DiagnosticsHub
    public let perf: PerfCollector
    public let marker: RunMarker
    public let windowCache = PerfWindowCache()
    public let ordinals = WindowOrdinals()
    public let pageBatches: OsbPageBatchReceiver
    public var requestPageMemory: (@Sendable () -> Void)?

    private let appVersion: String
    private let startedAt: Date
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let sampleWindows: @Sendable ([PerfWindowInfo], Date) -> PerfSample
    private var config: @Sendable () -> DiagnosticsConfig = { .disabled }
    private var timer: DispatchSourceTimer?
    private var started = false
    private var runBegun = false

    public init(hub: DiagnosticsHub, perf: PerfCollector = PerfCollector(), appVersion: String, useSignals: Bool = true, vocabulary: OsbVocabulary? = nil, sampleWindows: @escaping @Sendable ([PerfWindowInfo], Date) -> PerfSample = { ProcessSampler.sample(windows: $0, at: $1) }) {
        let queue = DispatchQueue(label: "osb.diagnostics.capture", qos: .utility)
        self.queue = queue
        pageBatches = OsbPageBatchReceiver(hub: hub, vocabulary: vocabulary, queue: queue)
        self.hub = hub
        self.perf = perf
        self.appVersion = appVersion
        self.sampleWindows = sampleWindows
        startedAt = hub.now()
        marker = RunMarker(folder: hub.pending.folder, now: hub.now, recording: { [weak hub] in hub?.recording ?? false }, useSignals: useSignals)
        hub.onBegin { [weak self] in self?.beginRun() }
        hub.onWipe { [weak self] in self?.wiped() }
    }

    public func configure(_ source: @escaping @Sendable () -> DiagnosticsConfig) {
        lock.withLock { config = source }
    }

    public func start(sampling: Bool = true) {
        let first: Bool = lock.withLock {
            defer { started = true }
            return !started
        }
        guard first else { return }
        if sampling { startSampler() }
        if hub.recording { beginRun() }
    }

    public func tickOsbPerf() {
        let settings = lock.withLock { config }()
        let on = hub.recording && settings.enabled && settings.perf && DiagnosticRules.sampledIn(draw: hub.limiter.sampleDraw, percent: settings.samplePercent)
        pageBatches.rotation.tick(now: hub.now(), span: TimeInterval(settings.perfIntervalSeconds), enabled: on)
    }

    public func finish() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
        queue.sync {}
        marker.clean()
    }

    public func drain() {
        queue.sync {}
    }

    public func trail(_ level: String, _ code: String, window: Int? = nil) {
        guard hub.recording else { return }
        let moment = hub.now()
        queue.async { [hub] in hub.trail.add(level: level, code: code, window: window, at: moment) }
    }

    public func learn(_ term: String?) {
        guard let term, hub.recording else { return }
        queue.async { [hub] in hub.terms.add(term) }
    }

    public func learn(accounts: [Account]) {
        queue.async { [hub] in hub.terms.add(accounts: accounts) }
    }

    public func processFailed(status: Int32, errorCode: Int32, context: DiagnosticContext?) {
        record(.process(RendererTermination.detail(status: status, errorCode: errorCode)), context: context)
    }

    public func unresponsive(outcome: String, waitedSeconds: Int, context: DiagnosticContext?) {
        record(.hang(HangDetail(outcome: outcome, waitedSeconds: waitedSeconds)), context: context)
    }

    public func gpuFailed(_ text: String?, retries: Int, context: DiagnosticContext?) {
        let code = DiagnosticScrubber.gpuFailure(text) ?? DiagnosticScrubber.other
        record(.gpu(GpuDetail(code: code, retries: retries)), context: context)
    }

    public func caught(_ error: Error, context: DiagnosticContext? = nil) {
        guard hub.recording else { return }
        caught(error, frames: NativeStack.callerFrames(), context: context)
    }

    func caught(_ error: Error, frames: [String], context: DiagnosticContext?) {
        let detail = ErrorDetail(type: ErrorTypeNames.swiftError(error), origin: "caught", handled: true, frames: frames)
        record(.error(detail), context: context)
    }

    public func crash(exceptionName: String, returnAddresses: [NSNumber]) {
        guard hub.recording else { return }
        crash(exceptionName: exceptionName, frames: NativeStack.frames(returnAddresses))
    }

    func crash(exceptionName: String, frames: [String]) {
        guard hub.recording else { return }
        let detail = ErrorDetail(type: ErrorTypeNames.exception(named: exceptionName), origin: "appdomain", handled: false, frames: frames)
        hub.writePending(event(.error(detail), context: nil, trail: false, at: hub.now()))
        marker.markCrashed()
    }

    public func sampleOnce() {
        guard hub.recording else { return }
        if !marker.isWritten { marker.begin(version: appVersion) }
        marker.touch()
        let settings = lock.withLock { config }()
        guard settings.enabled, settings.perf, DiagnosticRules.sampledIn(draw: hub.limiter.sampleDraw, percent: settings.samplePercent) else { return }
        perf.add(sampleWindows(windowCache.windows, hub.now()))
        let interval = TimeInterval(settings.perfIntervalSeconds)
        if perf.needsPageMemory(interval: interval, lead: Self.pageReadLead) {
            requestPageMemory?()
        }
        perf.tryComplete(interval: interval)
    }

    private func record(_ detail: DiagnosticDetail, context: DiagnosticContext?) {
        guard hub.recording else { return }
        let moment = hub.now()
        queue.async { [weak self] in
            guard let self else { return }
            self.hub.record(self.event(detail, context: context, trail: true, at: moment))
        }
    }

    private func event(_ detail: DiagnosticDetail, context: DiagnosticContext?, trail: Bool, at moment: Date) -> DiagnosticEvent {
        var full = context ?? DiagnosticContext()
        full.uptimeSeconds = DiagnosticFormats.roundUptime(moment.timeIntervalSince(startedAt))
        return DiagnosticEvent.make(detail, at: DiagnosticFormats.minute(moment), context: full, trail: trail ? hub.trail.snapshot(before: moment) : nil)
    }

    private func beginRun() {
        let begin: Bool = lock.withLock {
            guard started, !runBegun else { return false }
            runBegun = true
            return true
        }
        guard begin else { return }
        queue.async { [weak self] in
            guard let self, self.hub.recording else { return }
            if let previous = self.marker.readPrevious() {
                let at = DiagnosticFormats.minute(previous.aliveAt)
                self.hub.writePending(DiagnosticEvent.make(.runEnd(previous.detail), at: at))
            }
            self.marker.begin(version: self.appVersion)
        }
    }

    private func wiped() {
        lock.withLock { runBegun = false }
        marker.forget()
        perf.clear()
    }

    private func startSampler() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + PerfCollector.sampleStep, repeating: PerfCollector.sampleStep, leeway: .seconds(5))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.sampleOnce()
        }
        lock.withLock { timer = source }
        source.resume()
    }
}
