import Foundation
import JavaScriptCore
import Testing
@testable import OsbManagerCore

enum RepositoryPaths {
    static let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
    static let sharedScripts = root.appendingPathComponent("src/OsbManager/Browser", isDirectory: true)
    static let resources = root.appendingPathComponent("macos/OsbManager/Resources", isDirectory: true)
}

func installPageScripts(_ sources: [String], into context: JSContext) {
    var rest = sources
    let shim = rest.removeFirst()
    context.evaluateScript("var __dispatchJson = (\(shim))(function (json) { posted.push(json); }); var __dispatch = function (data) { __dispatchJson(JSON.stringify(data)); };")
    for source in rest {
        context.evaluateScript(source)
    }
}

private func assembledLibrary() throws -> (PageScriptLibrary, URL) {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sro-scripts-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let names = PageScriptLibrary.bridgeParts + [PageScriptLibrary.bridgePage]
    for name in names {
        try FileManager.default.copyItem(at: RepositoryPaths.sharedScripts.appendingPathComponent(name), to: temp.appendingPathComponent(name))
    }
    for name in [PageScriptLibrary.browserShim] {
        try FileManager.default.copyItem(at: RepositoryPaths.resources.appendingPathComponent(name), to: temp.appendingPathComponent(name))
    }
    return (PageScriptLibrary(directory: temp), temp)
}

private func isValidJavaScript(_ source: String) -> Bool {
    let context = JSContext()!
    context.setObject(source, forKeyedSubscript: "source" as NSString)
    return context.evaluateScript("(() => { try { new Function(source); return true; } catch (error) { return String(error); } })()")?.toBool() ?? false
}

struct PageScriptLibraryTests {
    @Test func concatenatesTheBridgeLikeTheWindowsApp() throws {
        let (library, _) = try assembledLibrary()

        let bridge = try library.bridge(frameLimit: 60)

        #expect(bridge.hasPrefix("(() => {\nconst initialFrameLimit = 60;\n"))
        #expect(bridge.hasSuffix("})();\n"))
        let order = ["const createAutoLogin", "const createLightControl", "const installDeviceRetry", "const createDropReader", "window.top !== window || location.origin"]
        let positions = order.map { bridge.range(of: $0)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil })
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
    }

    @Test func neverSendsANegativeFrameLimit() throws {
        let (library, _) = try assembledLibrary()

        #expect(try library.bridge(frameLimit: -5).contains("const initialFrameLimit = 0;"))
        #expect(try library.bridge(frameLimit: 0).contains("const initialFrameLimit = 0;"))
        #expect(try library.bridge(frameLimit: 120).contains("const initialFrameLimit = 120;"))
    }

    @Test func ordersTheInjectedScriptsAsTheSpecSays() throws {
        let (library, _) = try assembledLibrary()

        let plain = try library.scripts(frameLimit: 60, userScripts: ["// user one", "// user two"])
        let probed = try library.scripts(frameLimit: 60, beforeBridge: ["// probe"], userScripts: ["// user one"])

        #expect(plain.count == 4)
        #expect(plain[0].contains("window.chrome"))
        #expect(plain[0].contains("Object.defineProperty(window.chrome, 'webview'"))
        #expect(plain[1].contains("initialFrameLimit"))
        #expect(Array(plain[2...]) == ["// user one", "// user two"])
        #expect(probed.count == 4)
        #expect(probed[1] == "// probe")
        #expect(probed[2].contains("initialFrameLimit"))
        #expect(!plain.contains { $0.contains("clock.postMessage") || $0.contains("initialMuted") })
    }

    @Test func reportsAMissingScript() throws {
        let temp = TemporaryDirectory()

        #expect(throws: ScriptFormatError.self) { try PageScriptLibrary(directory: temp.url).bridge(frameLimit: 60) }
    }

    @Test func everyInjectedScriptIsValidJavaScript() throws {
        let (library, _) = try assembledLibrary()
        let meta = try UserScriptMeta.parse(ScriptFixtures.botHeader)
        let userScript = try ScriptInjection.build(meta: meta, source: ScriptFixtures.botHeader)

        for source in try library.scripts(frameLimit: 60, userScripts: [userScript]) {
            #expect(isValidJavaScript(source))
        }
    }
}

struct BridgeContractTests {
    private func page() throws -> JSContext {
        let (library, _) = try assembledLibrary()
        let context = JSContext()!
        context.exceptionHandler = { _, exception in context.setObject(exception?.toString() ?? "", forKeyedSubscript: "failure" as NSString) }
        context.evaluateScript("""
        var window = this;
        window.top = window;
        var posted = [];
        var timers = [];
        var setInterval = callback => timers.push(callback);
        var setTimeout = callback => timers.push(callback);
        var performance = { now: () => 0 };
        var navigator = {};
        var location = { origin: 'https://opensro.online', href: 'https://opensro.online/play' };
        var appended = [];
        var document = {
          readyState: 'complete',
          documentElement: { append: element => appended.push(element) },
          querySelector: () => null,
          createElement: () => ({ style: {}, setAttribute: () => {}, remove: () => {} }),
          addEventListener: () => {},
        };
        window.requestAnimationFrame = callback => 1;
        window.cancelAnimationFrame = () => {};
        window.Worker = class {};
        var tick = () => timers.slice().forEach(callback => callback());
        """)
        installPageScripts(try library.scripts(frameLimit: 60, userScripts: []), into: context)
        return context
    }

    @Test func postsAStatusAsJsonTextThroughTheShim() throws {
        let context = try page()

        context.evaluateScript("tick()")

        #expect(context.objectForKeyedSubscript("failure").toString() == "undefined")
        #expect(context.evaluateScript("posted.length").toInt32() >= 1)
        let text = try #require(context.evaluateScript("posted[0]").toString())
        let status = try #require(BotStatus.parse(text))
        #expect(!status.light)
        #expect(status.gpuRetries == 0)
        #expect(!status.linked)
    }

    @Test func switchesLightModeWhenTheAppSendsTheMessage() throws {
        let context = try page()

        context.evaluateScript("__dispatch({ type: 'light', on: true }); tick();")
        let on = try #require(BotStatus.parse(context.evaluateScript("posted[posted.length - 1]").toString()))
        context.evaluateScript("__dispatch({ type: 'light', on: false }); tick();")
        let off = try #require(BotStatus.parse(context.evaluateScript("posted[posted.length - 1]").toString()))

        #expect(on.light)
        #expect(!off.light)
        #expect(context.objectForKeyedSubscript("failure").toString() == "undefined")
    }

    @Test func acceptsAFrameLimitAndAnAutoLoginMessage() throws {
        let context = try page()

        context.evaluateScript("""
        __dispatch({ type: 'frame-limit', fps: 30 });
        __dispatch({ type: 'auto-login', enabled: false, character: '', server: '' });
        tick();
        """)

        #expect(context.objectForKeyedSubscript("failure").toString() == "undefined")
        let status = try #require(BotStatus.parse(context.evaluateScript("posted[posted.length - 1]").toString()))
        #expect(status.loginStage == "off")
    }

    @Test func exposesTheWebviewObjectOnlyOnceAndKeepsDispatchAway() throws {
        let context = try page()

        let result = context.evaluateScript("""
        (() => { try { window.chrome.webview = {}; } catch (error) {}
        return typeof window.chrome.webview.postMessage + ',' + typeof window.chrome.webview.dispatch + ',' + Object.isFrozen(window.chrome.webview); })()
        """)

        #expect(result?.toString() == "function,undefined,true")
    }
}
