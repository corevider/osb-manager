#if DEBUG
import AppKit
import OsbManagerCore

@MainActor
enum DialogShots {
    static func capture(controller: TelemetryController, main: MainWindowController, into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        main.show()
        await pause(0.8)
        save(main.window, folder.appendingPathComponent("start.png"))

        if controller.settings.state.sharedBefore {
            controller.answerDecline()
            await pause(2.0)
            save(main.window, folder.appendingPathComponent("after-no-thanks.png"))
        }

        controller.hideConsentPromptForShots()
        controller.showConsentPromptForShots(sharedBefore: false)
        await pause(0.6)
        save(main.window, folder.appendingPathComponent("first-run.png"))

        controller.hideConsentPromptForShots()
        controller.showConsentPromptForShots(sharedBefore: true)
        await pause(0.6)
        save(main.window, folder.appendingPathComponent("first-run-changed.png"))
        controller.hideConsentPromptForShots()

        controller.showPrivacy()
        await pause(0.8)
        if let window = controller.privacyWindowForShots { save(window, folder.appendingPathComponent("privacy-off.png")) }

        await controller.service.accept(characters: false)
        await controller.service.setCharacters(true)
        controller.showPrivacy(revealPayload: true)
        await pause(1.0)
        if let window = controller.privacyWindowForShots { save(window, folder.appendingPathComponent("privacy-on.png")) }

        controller.showReport()
        controller.reportWindowForShots?.prefill(description: "Auto login stops at the server list.")
        await pause(0.8)
        if let window = controller.reportWindowForShots?.window { save(window, folder.appendingPathComponent("report.png")) }
        controller.reportWindowForShots?.window.close()

        _ = await controller.service.withdraw()
        controller.showPrivacy()
        await pause(1.0)
        if let window = controller.privacyWindowForShots { save(window, folder.appendingPathComponent("privacy-switched-off.png")) }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func save(_ window: NSWindow, _ url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
