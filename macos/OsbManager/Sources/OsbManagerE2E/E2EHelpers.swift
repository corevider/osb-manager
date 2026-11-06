import AppKit
import Foundation
import OsbManagerApp
import OsbManagerCore

struct E2EConfiguration {
    var out = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("sro/t008/out", isDirectory: true)
    var measureSeconds = 60.0
    var settleSeconds = 8.0
    var skipHidden = false
    var scenario = "full"
    var phase = "first"
    var compare: URL?
    var share: Bool?

    static func parse(_ arguments: [String]) -> (E2EConfiguration, [String]) {
        var configuration = E2EConfiguration()
        var rest: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : ""
            switch argument {
            case "--out":
                configuration.out = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
                index += 1
            case "--measure":
                configuration.measureSeconds = Double(value) ?? 60
                index += 1
            case "--settle":
                configuration.settleSeconds = Double(value) ?? 8
                index += 1
            case "--scenario":
                configuration.scenario = value
                index += 1
            case "--phase":
                configuration.phase = value
                index += 1
            case "--compare":
                configuration.compare = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                index += 1
            case "--share":
                configuration.share = value == "on"
                index += 1
            case "--skip-hidden":
                configuration.skipHidden = true
            default:
                rest.append(argument)
            }
            index += 1
        }
        return (configuration, rest)
    }
}

func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

func screenIsLocked() -> Bool {
    let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
    return (dictionary?["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

@MainActor
func waitUntil(timeout: Double, interval: Double = 0.5, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        await pause(interval)
    }
    return await condition()
}

@MainActor
func evaluate(_ game: GameWindowController, _ source: String, timeout: Double = 10) async -> Any? {
    await withTaskGroup(of: Any?.self) { group in
        group.addTask { @MainActor in
            guard let browser = game.browser else { return ["error": "no browser"] }
            let text: String
            do {
                text = try await browser.evaluate(source)
            } catch {
                return ["error": error.localizedDescription]
            }
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return text }
            return value
        }
        group.addTask {
            await pause(timeout)
            return ["error": "timeout"]
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

@MainActor
func evaluateObject(_ game: GameWindowController, _ source: String) async -> [String: Any]? {
    await evaluate(game, source) as? [String: Any]
}

@MainActor
func snapshotGame(_ game: GameWindowController, to url: URL) async -> String {
    guard let png = await game.screenshot() else { return "failed: no image" }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        try png.write(to: url)
        return "ok \(png.count) bytes"
    } catch {
        return "failed: \(error.localizedDescription)"
    }
}

@MainActor
func snapshotWindow(_ window: NSWindow, to url: URL) -> String {
    guard let view = window.contentView?.superview ?? window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "failed: no bitmap" }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return "failed: no png" }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? png.write(to: url)
    return "ok \(rep.pixelsWide)x\(rep.pixelsHigh)"
}

@MainActor
func waitForLoginScreen(_ window: GameWindowController, timeout: Double) async -> Bool {
    await waitUntil(timeout: timeout, interval: 2) {
        (await evaluate(window, Probe.loginScreen, timeout: 5) as? NSNumber)?.boolValue == true
    }
}

func jsonString(_ value: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("null".utf8)
    return String(decoding: data, as: UTF8.self)
}

enum Probe {
    static let loginScreen = "return !!document.querySelector('[data-ui-id=\"frontend:reveal\"]');"

    static let userScript = """
    // ==UserScript==
    // @name         E2E probe
    // @namespace    https://osb-manager.test/
    // @version      1.0
    // @match        https://opensro.online/play*
    // @run-at       document-start
    // @grant        GM_getValue
    // @grant        GM_setValue
    // @grant        GM_listValues
    // @grant        GM_addStyle
    // @grant        GM_info
    // ==/UserScript==
    (() => {
      const token = GM_getValue('token') || ('t' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36));
      GM_setValue('token', token);
      GM_setValue('runs', (GM_getValue('runs', 0) || 0) + 1);
      GM_addStyle('html { --e2e: 1; }');
      const state = { token, runs: GM_getValue('runs'), values: GM_listValues().sort(), handler: GM_info.scriptHandler, frames: 0, ticks: 0, promised: null };
      GM.setValue('promised', 41).then(() => GM.getValue('promised')).then(value => { state.promised = value + 1; });
      window.__sroE2E = state;
      const nativeFrame = window.requestAnimationFrame;
      window.requestAnimationFrame = callback => nativeFrame.call(window, time => { state.frames++; callback(time); });
      setInterval(() => { state.ticks++; }, 100);
    })();
    """

    static let gpuScript = """
    (() => {
      window.__sroGpu = { state: 'pending' };
      if (!navigator.gpu) { window.__sroGpu = { state: 'navigator.gpu is missing' }; return; }
      navigator.gpu.requestAdapter().then(adapter => {
        if (!adapter) { window.__sroGpu = { state: 'no adapter' }; return; }
        const info = adapter.info || {};
        window.__sroGpu = { state: 'ok', vendor: info.vendor, architecture: info.architecture, device: info.device, description: info.description, features: [...adapter.features].length };
      }).catch(error => { window.__sroGpu = { state: 'error: ' + error }; });
    })();
    """

    static let pageState = """
    const probe = window.__sroE2E || null;
    const webview = window.chrome && window.chrome.webview;
    return {
      origin: location.origin,
      visibility: document.visibilityState,
      hidden: document.hidden,
      clock: performance.now(),
      ticks: probe ? probe.ticks : null,
      frames: probe ? probe.frames : null,
      token: probe ? probe.token : null,
      runs: probe ? probe.runs : null,
      values: probe ? probe.values : null,
      handler: probe ? probe.handler : null,
      promised: probe ? probe.promised : null,
      style: getComputedStyle(document.documentElement).getPropertyValue('--e2e').trim(),
      storageKeys: Object.keys(localStorage).filter(key => key.startsWith('sroMultiAcc.gm:')),
      gpu: window.__sroGpu || { state: navigator.gpu ? 'not probed' : 'navigator.gpu is missing' },
      webviewKeys: webview ? Object.keys(webview).sort() : null,
      webviewDispatchExposed: webview ? typeof webview.dispatch : null,
      inner: [window.innerWidth, window.innerHeight],
      userAgent: navigator.userAgent
    };
    """

    static let counters = """
    const probe = window.__sroE2E || null;
    return { clock: performance.now(), ticks: probe ? probe.ticks : null, frames: probe ? probe.frames : null, visibility: document.visibilityState };
    """
}
