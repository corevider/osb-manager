#if DEBUG
import AppKit
import OsbManagerCore

@MainActor
enum DialogShots {
    static func capture(controller: TelemetryController, main: MainWindowController, into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let code = controller.language.code
        main.show()
        await pause(0.8)
        save(main.window, folder.appendingPathComponent("banner-\(code).png"))

        controller.showPrivacy()
        await pause(0.8)
        if let window = controller.privacyWindowForShots { save(window, folder.appendingPathComponent("privacy-off-\(code).png")) }

        await controller.service.accept(characters: false)
        await controller.service.setCharacters(true)
        controller.showPrivacy(revealPayload: true)
        await pause(1.0)
        if let window = controller.privacyWindowForShots { save(window, folder.appendingPathComponent("privacy-on-\(code).png")) }

        controller.showReport()
        controller.reportWindowForShots?.prefill(description: code == "tr" ? "Otomatik giriş sunucu listesinde duruyor." : "Auto login stops at the server list.")
        await pause(0.8)
        if let window = controller.reportWindowForShots?.window { save(window, folder.appendingPathComponent("report-\(code).png")) }
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
