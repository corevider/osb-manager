import AppKit
import CefBridge
import Foundation

public enum CefRuntime {
    public static func loadFramework() -> Bool {
        SroCefRuntime.loadFramework()
    }

    public static func start(rootCache: URL, logFile: URL, ready: @escaping () -> Void) throws {
        try FileManager.default.createDirectory(at: rootCache, withIntermediateDirectories: true)
        SroCefRuntime.setPackProvider(CefPackInterception.shared)
        guard SroCefRuntime.initialize(withRootCachePath: rootCache.path, logFile: logFile.path, ready: ready) else {
            throw GameBrowserError("CEF could not start. Another copy may be using the same data folder.")
        }
    }

    public static func run() {
        SroCefRuntime.runMessageLoop()
    }

    public static func quit() {
        SroCefRuntime.quitMessageLoop()
    }

    public static func shutdown() {
        SroCefRuntime.shutdown()
    }

    public static var version: String {
        SroCefRuntime.cefVersion()
    }
}

@MainActor
public final class CefGameBrowserFactory: GameBrowserFactory {
    public init() {}

    public func makeBrowser(in view: NSView, configuration: GameBrowserConfiguration, delegate: GameBrowserDelegate) throws -> GameBrowser {
        try CefGameBrowser(view: view, configuration: configuration, delegate: delegate)
    }
}

@MainActor
final class CefGameBrowser: NSObject, GameBrowser, SroCefBrowserDelegate {
    weak var delegate: GameBrowserDelegate?
    private var browser: SroCefBrowser?

    init(view: NSView, configuration: GameBrowserConfiguration, delegate: GameBrowserDelegate) throws {
        self.delegate = delegate
        super.init()
        try FileManager.default.createDirectory(at: configuration.dataFolder, withIntermediateDirectories: true)
        guard let created = SroCefBrowser(
            parentView: view,
            cachePath: configuration.dataFolder.path,
            url: configuration.startUrl.absoluteString,
            scripts: configuration.scripts,
            allowEvaluate: configuration.allowEvaluate,
            delegate: self
        ) else {
            throw GameBrowserError("CEF could not create the browser.")
        }
        browser = created
    }

    var isClosed: Bool { browser?.isClosed ?? true }

    var currentUrl: URL? { browser?.currentUrl.flatMap(URL.init(string:)) }

    var rejectedMessageCount: Int { Int(browser?.rejectedMessageCount ?? 0) }

    var rendererProcessId: Int { Int(browser?.rendererProcessId ?? 0) }

    var isMuted: Bool { browser?.isAudioMuted() ?? false }

    func load(_ url: URL) {
        browser?.loadUrl(url.absoluteString)
    }

    func reload() {
        browser?.reload()
    }

    func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        browser?.sendMessageJson(json)
    }

    func setMuted(_ muted: Bool) {
        browser?.setAudioMuted(muted)
    }

    func updateScripts(_ scripts: [String]) {
        browser?.updateScripts(scripts)
    }

    func evaluate(_ code: String) async throws -> String {
        guard let browser else { throw GameBrowserError("The browser is closed.") }
        return try await withCheckedThrowingContinuation { continuation in
            browser.evaluate(code) { ok, text in
                if ok {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: GameBrowserError(text))
                }
            }
        }
    }

    func captureScreenshot() async throws -> Data {
        guard let browser else { throw GameBrowserError("The browser is closed.") }
        return try await withCheckedThrowingContinuation { continuation in
            browser.captureScreenshot { png in
                if let png {
                    continuation.resume(returning: png)
                } else {
                    continuation.resume(throwing: GameBrowserError("The screenshot failed."))
                }
            }
        }
    }

    func perform(_ command: GameEditCommand) {
        switch command {
        case .undo: browser?.perform(.undo)
        case .redo: browser?.perform(.redo)
        case .cut: browser?.perform(.cut)
        case .copy: browser?.perform(.copy)
        case .paste: browser?.perform(.paste)
        case .selectAll: browser?.perform(.selectAll)
        }
    }

    func close() {
        browser?.close()
    }

    nonisolated func cefBrowser(_ browser: SroCefBrowser, didReceivePageMessage json: String, fromMainFrame mainFrame: Bool, pageUrl: String) {
        MainActor.assumeIsolated {
            delegate?.gameBrowser(self, didReceivePageMessage: json, from: PageOrigin(isMainFrame: mainFrame, pageUrl: pageUrl))
        }
    }

    nonisolated func cefBrowser(_ browser: SroCefBrowser, didFinishLoadingUrl url: String) {
        MainActor.assumeIsolated {
            delegate?.gameBrowserDidFinishLoading(self)
        }
    }

    nonisolated func cefBrowser(_ browser: SroCefBrowser, didFailLoadingUrl url: String, description: String) {
        MainActor.assumeIsolated {
            delegate?.gameBrowser(self, didFailLoading: "\(description) (\(url))")
        }
    }

    nonisolated func cefBrowser(_ browser: SroCefBrowser, rendererDidTerminate reason: String) {
        MainActor.assumeIsolated {
            delegate?.gameBrowser(self, rendererDidTerminate: reason)
        }
    }

    nonisolated func cefBrowser(_ browser: SroCefBrowser, wantsToOpenPopupToUrl url: String) {
        MainActor.assumeIsolated {
            if let address = URL(string: url), address.scheme == "https" || address.scheme == "http" {
                delegate?.gameBrowser(self, wantsToOpen: address)
            }
        }
    }

    nonisolated func cefBrowser(_ browser: SroCefBrowser, didLogConsoleMessage message: String, level: Int32) {
        MainActor.assumeIsolated {
            delegate?.gameBrowser(self, didLog: message, level: Int(level))
        }
    }

    nonisolated func cefBrowser(_ browser: SroCefBrowser, didReportScriptError description: String) {
        MainActor.assumeIsolated {
            delegate?.gameBrowser(self, didReportScriptError: description)
        }
    }

    nonisolated func cefBrowserDidClose(_ browser: SroCefBrowser) {
        MainActor.assumeIsolated {
            delegate?.gameBrowserDidClose(self)
        }
    }
}
