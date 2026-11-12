import Foundation
import JavaScriptCore
import Testing
@testable import OsbManagerCore

enum ScriptFixtures {
    static let botHeader = """
    // ==UserScript==
    // @name         nixxane bot
    // @namespace    https://opensro.online/
    // @version      1.2.172
    // @updateURL    https://raw.githubusercontent.com/nixxane/opensro-bot-lean/main/bot.lean.meta.js
    // @downloadURL  https://raw.githubusercontent.com/nixxane/opensro-bot-lean/main/bot.lean.user.js
    // @match        https://opensro.online/play*
    // @run-at       document-start
    // @grant        none
    // @inject-into  page
    // @noframes
    // ==/UserScript==
    window.botLoaded = true;
    """

    static func matches(_ pattern: String, _ url: String) -> Bool {
        let context = JSContext()!
        context.setObject(pattern, forKeyedSubscript: "pattern" as NSString)
        context.setObject(url, forKeyedSubscript: "url" as NSString)
        return context.evaluateScript("new RegExp(pattern).test(url)")?.toBool() ?? false
    }
}

struct UserScriptMetaTests {
    @Test func readsTheBotHeader() throws {
        let meta = try UserScriptMeta.parse(ScriptFixtures.botHeader)

        #expect(meta.name == "nixxane bot")
        #expect(meta.namespace == "https://opensro.online/")
        #expect(meta.version == "1.2.172")
        #expect(meta.runAt == "document-start")
        #expect(meta.noFrames)
        #expect(meta.matches == ["https://opensro.online/play*"])
        #expect(meta.grants == ["none"])
        #expect(meta.unsupportedGrants.isEmpty)
        #expect(meta.downloadUrl?.hasSuffix("bot.lean.user.js") == true)
    }

    @Test func defaultsToDocumentIdleAndListsUnsupportedGrants() throws {
        let meta = try UserScriptMeta.parse("""
        // ==UserScript==
        // @name   other
        // @include https://opensro.online/*
        // @exclude https://opensro.online/admin*
        // @grant  GM_xmlhttpRequest
        // @grant  GM_getValue
        // @require https://example.com/lib.js
        // ==/UserScript==
        """)

        #expect(meta.runAt == "document-idle")
        #expect(!meta.noFrames)
        #expect(meta.includes == ["https://opensro.online/*"])
        #expect(meta.excludes == ["https://opensro.online/admin*"])
        #expect(meta.unsupportedGrants == ["GM_xmlhttpRequest"])
        #expect(meta.requires == ["https://example.com/lib.js"])
    }

    @Test func readsWindowsLineEndings() throws {
        let meta = try UserScriptMeta.parse(ScriptFixtures.botHeader.replacingOccurrences(of: "\n", with: "\r\n"))

        #expect(meta.name == "nixxane bot")
        #expect(meta.runAt == "document-start")
        #expect(meta.noFrames)
    }

    @Test(arguments: [
        "console.log(1);",
        "// ==UserScript==\n// @match https://a.example/*\n// ==/UserScript==",
        "// ==UserScript==\n// @name no targets\n// ==/UserScript==",
        "// ==UserScript==\n// @name unterminated\n// @match https://a.example/*",
    ])
    func rejectsIncompleteHeaders(source: String) {
        #expect(throws: ScriptFormatError.self) { try UserScriptMeta.parse(source) }
    }
}

struct UrlPatternTests {
    @Test(arguments: [
        ("https://opensro.online/play*", "https://opensro.online/play", true),
        ("https://opensro.online/play*", "https://opensro.online/play?server=1", true),
        ("https://opensro.online/play*", "https://opensro.online/", false),
        ("https://opensro.online/play*", "http://opensro.online/play", false),
        ("https://opensro.online/play*", "https://opensro.online.evil.example/play", false),
        ("*://*.example.com/*", "https://example.com/a", true),
        ("*://*.example.com/*", "http://a.b.example.com/", true),
        ("*://*.example.com/*", "https://badexample.com/", false),
        ("<all_urls>", "https://anything.example/x", true),
    ])
    func matchPatterns(pattern: String, url: String, expected: Bool) throws {
        #expect(ScriptFixtures.matches(try UrlPattern.fromMatch(pattern), url) == expected)
    }

    @Test(arguments: [
        ("https://opensro.online/*", "https://opensro.online/play", true),
        ("https://opensro.online/*", "https://opensro.online.example/", false),
        ("/^https:\\/\\/opensro\\.online\\/play/", "https://opensro.online/play", true),
    ])
    func includeGlobsAndRegexes(glob: String, url: String, expected: Bool) {
        #expect(ScriptFixtures.matches(UrlPattern.fromGlob(glob), url) == expected)
    }

    @Test func rejectsMalformedMatchPatterns() {
        #expect(throws: ScriptFormatError.self) { try UrlPattern.fromMatch("opensro.online/play") }
    }
}

struct ScriptInjectionTests {
    @Test func wrapsTheSourceWithItsTargetsAndRunTime() throws {
        let meta = try UserScriptMeta.parse(ScriptFixtures.botHeader)

        let injection = try ScriptInjection.build(meta: meta, source: ScriptFixtures.botHeader)

        #expect(injection.hasPrefix("(() => {"))
        #expect(injection.contains("window.botLoaded = true;"))
        #expect(injection.contains("\"runAt\":\"document-start\""))
        #expect(injection.contains("\"noFrames\":true"))
        #expect(injection.contains(try JsonFile.string(UrlPattern.fromMatch("https://opensro.online/play*"))))
        #expect(injection.hasSuffix("})();\n"))
    }

    private func run(_ source: String, url: String, top: Bool = true) throws -> JSContext {
        let meta = try UserScriptMeta.parse(source)
        let injection = try ScriptInjection.build(meta: meta, source: source)
        let context = JSContext()!
        context.exceptionHandler = { _, exception in context.setObject(exception?.toString() ?? "", forKeyedSubscript: "failure" as NSString) }
        context.evaluateScript("""
        var isTop = \(top);
        var window = {}; window.top = isTop ? window : {};
        var console = { error: () => { failures.push('console.error'); } };
        var failures = [];
        var location = { href: '\(url)' };
        var storage = {};
        var localStorage = {
          getItem: key => key in storage ? storage[key] : null,
          setItem: (key, value) => { storage[key] = String(value); },
          removeItem: key => { delete storage[key]; },
          get length() { return Object.keys(storage).length; },
          key: index => Object.keys(storage)[index] ?? null,
        };
        var styles = [];
        var document = {
          readyState: 'complete',
          createElement: () => ({}),
          head: { appendChild: element => styles.push(element.textContent) },
          documentElement: {},
          addEventListener: () => {},
        };
        var setTimeout = callback => callback();
        var ran = [];
        """)
        context.evaluateScript(injection)
        return context
    }

    private func header(_ lines: String) -> String {
        "// ==UserScript==\n// @name t\n// @namespace n\n\(lines)\n// ==/UserScript==\nran.push(location.href);\n"
    }

    @Test func runsOnlyOnItsUrls() throws {
        let source = header("// @match https://opensro.online/play*\n// @exclude *debug*\n// @run-at document-start")

        #expect(try run(source, url: "https://opensro.online/play").evaluateScript("ran.length").toInt32() == 1)
        #expect(try run(source, url: "https://opensro.online/").evaluateScript("ran.length").toInt32() == 0)
        #expect(try run(source, url: "https://opensro.online/play?debug=1").evaluateScript("ran.length").toInt32() == 0)
    }

    @Test func skipsFramesWhenTheScriptAsksForIt() throws {
        let source = header("// @match https://opensro.online/*\n// @run-at document-start\n// @noframes")

        #expect(try run(source, url: "https://opensro.online/play", top: false).evaluateScript("ran.length").toInt32() == 0)
        #expect(try run(source, url: "https://opensro.online/play", top: true).evaluateScript("ran.length").toInt32() == 1)
    }

    @Test func keepsValuesWithTheGmFunctionsAndTheirPromiseForms() throws {
        let source = """
        // ==UserScript==
        // @name t
        // @namespace n
        // @match https://opensro.online/*
        // @run-at document-start
        // ==/UserScript==
        GM_setValue('count', 41);
        GM_setValue('count', GM_getValue('count', 0) + 1);
        GM_setValue('object', { a: [1, 2] });
        GM_setValue('gone', 1);
        GM_deleteValue('gone');
        ran.push(GM_getValue('count'), GM_getValue('missing', 'fallback'), JSON.stringify(GM_getValue('object')), GM_listValues().sort().join(','), GM_info.script.name, GM_info.scriptHandler);
        GM_addStyle('body { color: red }');
        GM.setValue('promised', 7).then(() => GM.getValue('promised')).then(value => ran.push('promise:' + value));
        """

        let context = try run(source, url: "https://opensro.online/play")

        #expect(context.evaluateScript("ran.slice(0, 6).join('|')").toString() == "42|fallback|{\"a\":[1,2]}|count,object|t|OSB Manager")
        #expect(context.evaluateScript("styles.join()").toString() == "body { color: red }")
        #expect(context.evaluateScript("Object.keys(storage).every(key => key.startsWith('sroMultiAcc.gm:n:t:'))").toBool())
    }

    @Test func addsStylesOnlyOnceThePageHasARootElement() throws {
        let source = header("// @match https://opensro.online/*\n// @run-at document-start").replacingOccurrences(of: "ran.push(location.href);", with: "GM_addStyle('body { color: blue }');")
        let meta = try UserScriptMeta.parse(source)
        let injection = try ScriptInjection.build(meta: meta, source: source)
        let context = JSContext()!
        context.exceptionHandler = { _, exception in context.setObject(exception?.toString() ?? "", forKeyedSubscript: "failure" as NSString) }
        context.evaluateScript("""
        var window = {}; window.top = window;
        var console = { error: () => {} };
        var location = { href: 'https://opensro.online/play' };
        var styles = []; var observers = []; var disconnected = 0;
        var MutationObserver = class {
          constructor(callback) { this.callback = callback; observers.push(this); }
          observe() {}
          disconnect() { disconnected++; }
        };
        var document = { readyState: 'loading', createElement: () => ({}), head: null, documentElement: null, addEventListener: () => {} };
        """)

        context.evaluateScript(injection)

        #expect(context.objectForKeyedSubscript("failure").toString() == "undefined")
        #expect(context.evaluateScript("styles.length").toInt32() == 0)
        #expect(context.evaluateScript("observers.length").toInt32() == 1)

        context.evaluateScript("document.documentElement = { appendChild: element => styles.push(element.textContent) }; observers[0].callback([], observers[0]);")

        #expect(context.objectForKeyedSubscript("failure").toString() == "undefined")
        #expect(context.evaluateScript("styles.join()").toString() == "body { color: blue }")
        #expect(context.evaluateScript("disconnected").toInt32() == 1)
    }

    @Test func reportsAFailingScriptWithoutStoppingTheHost() throws {
        let source = header("// @match https://opensro.online/*\n// @run-at document-start").replacingOccurrences(of: "ran.push(location.href);", with: "throw new Error('boom');")

        let context = try run(source, url: "https://opensro.online/play")

        #expect(context.objectForKeyedSubscript("failure").toString() == "undefined")
        #expect(context.evaluateScript("failures.join()").toString() == "console.error")
    }
}

@MainActor
struct ScriptStoreTests {
    private struct FakeDownloader: ScriptDownloading {
        let text: String

        func download(_ url: URL, maxBytes: Int) async throws -> String { text }
    }

    @Test func installsReplacesByNameAndReloads() throws {
        let temp = TemporaryDirectory()
        let store = ScriptStore(directory: temp.url, log: { _ in })
        let first = try store.install(source: ScriptFixtures.botHeader, sourceUrl: "https://example.com/bot.user.js")
        try store.setEnabled(first.id, false)

        let updated = try store.install(source: ScriptFixtures.botHeader.replacingOccurrences(of: "1.2.172", with: "1.2.173"), sourceUrl: nil)
        let reloaded = ScriptStore(directory: temp.url, log: { _ in })

        #expect(first.id == updated.id)
        #expect(reloaded.scripts.count == 1)
        let script = try #require(reloaded.scripts.first)
        #expect(script.meta.version == "1.2.173")
        #expect(!script.enabled)
        #expect(script.sourceUrl == "https://example.com/bot.user.js")
        #expect(reloaded.enabledInjections.isEmpty)
    }

    @Test func listsEnabledInjectionsInInstallOrder() throws {
        let temp = TemporaryDirectory()
        let store = ScriptStore(directory: temp.url, log: { _ in })
        let other = ScriptFixtures.botHeader.replacingOccurrences(of: "nixxane bot", with: "second")
        try store.install(source: ScriptFixtures.botHeader, sourceUrl: nil)
        let second = try store.install(source: other, sourceUrl: nil)

        #expect(store.enabledInjections.count == 2)
        try store.setEnabled(second.id, false)
        #expect(store.enabledInjections.count == 1)
    }

    @Test func removesTheScriptFile() throws {
        let temp = TemporaryDirectory()
        let store = ScriptStore(directory: temp.url, log: { _ in })
        let script = try store.install(source: ScriptFixtures.botHeader, sourceUrl: nil)

        try store.remove(script.id)

        #expect(store.scripts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temp.file(script.id + ".user.js").path))
    }

    @Test func skipsBrokenEntriesOnLoad() throws {
        let temp = TemporaryDirectory()
        try #"[{"id":"../../evil","enabled":true},{"id":"aaaaaaaaaaaa","enabled":true}]"#.write(to: temp.file("scripts.json"), atomically: true, encoding: .utf8)
        try "no header".write(to: temp.file("aaaaaaaaaaaa.user.js"), atomically: true, encoding: .utf8)
        var messages: [String] = []

        let store = ScriptStore(directory: temp.url, log: { messages.append($0) })

        #expect(store.scripts.isEmpty)
        #expect(messages.count == 1)
    }

    @Test func installsFromAFile() throws {
        let temp = TemporaryDirectory()
        let store = ScriptStore(directory: temp.file("scripts"), log: { _ in })
        try ScriptFixtures.botHeader.write(to: temp.file("bot.user.js"), atomically: true, encoding: .utf8)

        let script = try store.install(fromFile: temp.file("bot.user.js"))

        #expect(script.meta.name == "nixxane bot")
        #expect(script.sourceUrl == nil)
    }

    @Test func refusesPlainHttpAddresses() async throws {
        let temp = TemporaryDirectory()
        let store = ScriptStore(directory: temp.url, log: { _ in })

        await #expect(throws: ScriptFormatError.self) {
            try await store.install(fromUrl: "http://example.com/x.user.js", downloader: FakeDownloader(text: ScriptFixtures.botHeader))
        }
        await #expect(throws: ScriptFormatError.self) {
            try await store.install(fromUrl: "file:///etc/passwd", downloader: FakeDownloader(text: ScriptFixtures.botHeader))
        }
        #expect(store.scripts.isEmpty)
    }

    @Test func installsFromAnHttpsAddressAndKeepsTheSource() async throws {
        let temp = TemporaryDirectory()
        let store = ScriptStore(directory: temp.url, log: { _ in })

        let script = try await store.install(fromUrl: "https://example.com/bot.user.js", downloader: FakeDownloader(text: ScriptFixtures.botHeader))

        #expect(script.sourceUrl == "https://example.com/bot.user.js")
        #expect(script.updateSource?.hasSuffix("bot.lean.user.js") == true)
    }

    @Test func warnsAboutUnsupportedGrantsAndRequires() throws {
        let temp = TemporaryDirectory()
        let store = ScriptStore(directory: temp.url, log: { _ in })

        let script = try store.install(source: """
        // ==UserScript==
        // @name w
        // @match https://a.example/*
        // @grant GM_xmlhttpRequest
        // @require https://example.com/lib.js
        // ==/UserScript==
        """, sourceUrl: nil)

        #expect(script.warnings == ["unsupported @grant GM_xmlhttpRequest", "@require is not loaded"])
    }

    @Test func notifiesAboutChanges() throws {
        let temp = TemporaryDirectory()
        let store = ScriptStore(directory: temp.url, log: { _ in })
        var changes = 0
        store.onChange = { changes += 1 }

        let script = try store.install(source: ScriptFixtures.botHeader, sourceUrl: nil)
        try store.setEnabled(script.id, false)
        try store.remove(script.id)

        #expect(changes == 3)
    }

    @Test func updatesFromAnAddressAndNotifiesOnTheMainThread() async throws {
        let temp = TemporaryDirectory()
        let store = ScriptStore(directory: temp.url, log: { _ in })
        try store.install(source: ScriptFixtures.botHeader, sourceUrl: "https://example.com/bot.user.js")
        var notifiedOnMainThread: [Bool] = []
        store.onChange = { notifiedOnMainThread.append(Thread.isMainThread) }
        let newer = ScriptFixtures.botHeader.replacingOccurrences(of: "1.2.172", with: "1.2.173")

        let updated = try await store.install(fromUrl: "https://example.com/bot.user.js", downloader: FakeDownloader(text: newer))

        #expect(updated.meta.version == "1.2.173")
        #expect(store.scripts.map(\.meta.version) == ["1.2.173"])
        #expect(notifiedOnMainThread == [true])
    }
}
