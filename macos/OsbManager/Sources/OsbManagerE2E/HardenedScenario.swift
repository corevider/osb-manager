import AppKit
import Foundation
import OsbManagerApp
import OsbManagerCore

@MainActor
struct HardenedScenario {
    let app: AppDelegate
    let config: E2EConfiguration
    let log: JsonLog

    private static let webAssemblyProbe = """
    const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11]);
    const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes));
    let sum = 0;
    for (let index = 0; index < 2000000; index++) { sum = (sum + index * 3) % 1000003; }
    return { wasmAdd: instance.exports.add(20, 22), loopSum: sum };
    """

    func run() async {
        var summary: [String: Any] = [
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "version": AppVersion.current(),
        ]
        app.services.preBridgeScripts = [Probe.gpuScript]
        let sampler = ProcessSampler()
        guard let account = try? app.services.accounts.add(name: "alpha") else {
            summary["error"] = "could not add the account"
            finish(summary)
            return
        }
        app.manager.startOrShow(account.id, light: false)
        _ = await waitUntil(timeout: 30) { app.manager.windows[account.id] != nil }
        guard let game = app.manager.windows[account.id] else {
            summary["error"] = "no game window"
            finish(summary)
            return
        }
        summary["loginScreenReached"] = await waitForLoginScreen(game, timeout: 240)
        await pause(5)
        summary["pageState"] = await evaluate(game, Probe.pageState) ?? NSNull()
        summary["webAssemblyAndJit"] = await evaluate(game, Self.webAssemblyProbe) ?? NSNull()
        summary["phase"] = game.status?.phase ?? NSNull()
        summary["gpuRetries"] = game.status?.gpuRetries ?? NSNull()
        summary["gpuFailed"] = game.status?.gpuFailed ?? NSNull()
        summary["rendererProcessId"] = game.rendererProcessId ?? 0
        summary["screenshot"] = await snapshotGame(game, to: config.out.appendingPathComponent("game-hardened.png"))
        summary["processes"] = sampler.read().map { ["pid": Int($0.pid), "kind": $0.kind] }
        finish(summary)
    }

    private func finish(_ summary: [String: Any]) {
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("hardened-summary.json"))
        Task { @MainActor in
            _ = app.manager.closeAll(prompt: false)
            _ = await waitUntil(timeout: 30) { app.manager.windows.isEmpty }
            log.write("quit-requested")
            NSApp.terminate(nil)
        }
    }
}
