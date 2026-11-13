import Foundation

public final class DiagnosticsHub: @unchecked Sendable {
    public static let faultLimit = 3

    public let terms: PrivateTerms
    public let run: String
    public let trail: DiagnosticTrail
    public let limiter: DiagnosticLimiter
    public let pending: PendingDiagnostics
    public let now: @Sendable () -> Date

    private let lock = NSLock()
    private let consentOn: @Sendable () -> Bool
    private var active: Bool
    private var serverOn = false
    private var faults = 0
    private var epoch = 0
    private var osbPerf: OsbPerfEntry?
    private var wipeObservers: [@Sendable () -> Void] = []
    private var beginObservers: [@Sendable () -> Void] = []

    public init(folder: URL, terms: PrivateTerms, now: @escaping @Sendable () -> Date = { Date() }, sampleDraw: Int = Int.random(in: 0...99), run: String = DiagnosticFormats.newRunKey(), consentOn: @escaping @Sendable () -> Bool) {
        self.terms = terms
        self.now = now
        self.consentOn = consentOn
        self.run = run
        active = consentOn()
        let gate = Gate()
        trail = DiagnosticTrail(now: now, recording: { gate.isOpen })
        limiter = DiagnosticLimiter(now: now, sampleDraw: sampleDraw)
        pending = PendingDiagnostics(folder: folder, now: now, consentOn: { gate.isOpen })
        gate.check = { [weak self] in self?.recording ?? false }
        if !active {
            pending.wipeAll()
        }
    }

    public var recording: Bool {
        lock.withLock { active && serverOn && faults < Self.faultLimit } && consentOn()
    }

    public var serverAllows: Bool {
        lock.withLock { serverOn }
    }

    public func applyServer(_ config: DiagnosticsConfig) {
        limiter.samplePercent = config.samplePercent
        let allow = config.enabled && DiagnosticRules.sampledIn(draw: limiter.sampleDraw, percent: config.samplePercent)
        let leftovers = !allow && FileManager.default.fileExists(atPath: pending.folder.path)
        let (begin, end): (Bool, Bool) = lock.withLock {
            let was = serverOn
            serverOn = allow
            return (allow && !was && active, !allow && (was || leftovers))
        }
        if begin, consentOn() {
            startRecording()
        } else if end {
            wipe()
        }
    }

    public var faulted: Bool {
        lock.withLock { faults >= Self.faultLimit }
    }

    public var session: Int {
        lock.withLock { epoch }
    }

    public func isCurrent(session: Int) -> Bool {
        recording && self.session == session
    }

    public func reportFault() {
        lock.withLock { faults += 1 }
    }

    public func onWipe(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { wipeObservers.append(observer) }
    }

    public func onBegin(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { beginObservers.append(observer) }
    }

    @discardableResult
    public func record(_ candidate: DiagnosticEvent) -> RecordOutcome? {
        guard recording, let clean = DiagnosticScrubber.scrub(candidate, terms) else { return nil }
        return limiter.record(clean)
    }

    public func keepOsbPerf(_ entry: OsbPerfEntry, session: Int) {
        guard consentOn() else { return }
        lock.withLock {
            if active && serverOn && faults < Self.faultLimit && epoch == session { osbPerf = entry }
        }
    }

    public func peekOsbPerf() -> OsbPerfEntry? {
        lock.withLock { osbPerf }
    }

    public func takeOsbPerf() -> OsbPerfEntry? {
        lock.withLock {
            defer { osbPerf = nil }
            return osbPerf
        }
    }

    public func returnOsbPerf(_ entry: OsbPerfEntry) {
        lock.withLock {
            if osbPerf == nil { osbPerf = entry }
        }
    }

    @discardableResult
    public func writePending(_ candidate: DiagnosticEvent) -> Bool {
        guard recording, let data = DiagnosticJson.event(candidate, terms: terms) else { return false }
        return pending.write(data)
    }

    public func pendingEvents() -> [(id: String, event: DiagnosticEvent)] {
        guard recording else {
            pending.wipeAll()
            return []
        }
        return pending.load().compactMap { file in DiagnosticJsonReader.event(file.content).map { (file.id, $0) } }
    }

    public func consentChanged() {
        let on = consentOn()
        let begin: Bool = lock.withLock {
            let starting = on && !active && serverOn
            active = on
            if !on { serverOn = false }
            return starting
        }
        if begin {
            startRecording()
        } else if !on {
            wipe()
        }
    }

    private func startRecording() {
        clearBuffers()
        let observers = lock.withLock { beginObservers }
        observers.forEach { $0() }
    }

    public func wipe() {
        let observers: [@Sendable () -> Void] = lock.withLock {
            epoch += 1
            return wipeObservers
        }
        clearBuffers()
        pending.wipeAll()
        observers.forEach { $0() }
    }

    private func clearBuffers() {
        trail.clear()
        limiter.clear()
        lock.withLock { osbPerf = nil }
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var checker: (@Sendable () -> Bool)?

    var check: (@Sendable () -> Bool)? {
        get { lock.withLock { checker } }
        set { lock.withLock { checker = newValue } }
    }

    var isOpen: Bool { check?() ?? false }
}
