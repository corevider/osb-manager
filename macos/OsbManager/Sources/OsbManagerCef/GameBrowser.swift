import AppKit
import Foundation

public struct PageOrigin: Equatable {
    public let isMainFrame: Bool
    public let scheme: String
    public let host: String
    public let port: Int

    public init(isMainFrame: Bool, scheme: String, host: String, port: Int) {
        self.isMainFrame = isMainFrame
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    public init(isMainFrame: Bool, pageUrl: String) {
        let components = URLComponents(string: pageUrl)
        self.init(
            isMainFrame: isMainFrame,
            scheme: components?.scheme?.lowercased() ?? "",
            host: components?.host?.lowercased() ?? "",
            port: components?.port ?? 0
        )
    }
}

public struct GameBrowserError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct GameBrowserConfiguration {
    public var dataFolder: URL
    public var startUrl: URL
    public var scripts: [String]
    public var allowEvaluate: Bool

    public init(dataFolder: URL, startUrl: URL, scripts: [String], allowEvaluate: Bool = false) {
        self.dataFolder = dataFolder
        self.startUrl = startUrl
        self.scripts = scripts
        self.allowEvaluate = allowEvaluate
    }
}

public enum GameEditCommand {
    case undo, redo, cut, copy, paste, selectAll
}

@MainActor
public protocol GameBrowserDelegate: AnyObject {
    func gameBrowser(_ browser: GameBrowser, didReceivePageMessage json: String, from origin: PageOrigin)
    func gameBrowserDidFinishLoading(_ browser: GameBrowser)
    func gameBrowser(_ browser: GameBrowser, didFailLoading description: String)
    func gameBrowser(_ browser: GameBrowser, rendererDidTerminate reason: String)
    func gameBrowser(_ browser: GameBrowser, wantsToOpen url: URL)
    func gameBrowser(_ browser: GameBrowser, didLog message: String, level: Int)
    func gameBrowser(_ browser: GameBrowser, didReportScriptError description: String)
    func gameBrowserDidClose(_ browser: GameBrowser)
}

public extension GameBrowserDelegate {
    func gameBrowser(_ browser: GameBrowser, didLog message: String, level: Int) {}
    func gameBrowser(_ browser: GameBrowser, didReportScriptError description: String) {}
}

@MainActor
public protocol GameBrowser: AnyObject {
    var delegate: GameBrowserDelegate? { get set }
    var isClosed: Bool { get }
    var currentUrl: URL? { get }
    var rejectedMessageCount: Int { get }
    var rendererProcessId: Int { get }
    var isMuted: Bool { get }

    func load(_ url: URL)
    func reload()
    func send(_ message: [String: Any])
    func setMuted(_ muted: Bool)
    func updateScripts(_ scripts: [String])
    func evaluate(_ code: String) async throws -> String
    func captureScreenshot() async throws -> Data
    func perform(_ command: GameEditCommand)
    func close()
}

@MainActor
public protocol GameBrowserFactory {
    func makeBrowser(in view: NSView, configuration: GameBrowserConfiguration, delegate: GameBrowserDelegate) throws -> GameBrowser
}
