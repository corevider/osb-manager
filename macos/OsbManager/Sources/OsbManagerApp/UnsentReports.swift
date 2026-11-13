import AppKit
import OsbManagerCore

@MainActor
enum UnsentReports {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func present(controller: TelemetryController) {
        let outbox = controller.service.outbox
        let interface = controller.interface
        let failed = outbox.failed()
        guard !failed.isEmpty else {
            let alert = NSAlert()
            alert.messageText = interface.unsentReports
            alert.informativeText = interface.noUnsentReports
            alert.addButton(withTitle: interface.ok)
            alert.runModal()
            return
        }
        for entry in failed {
            let alert = NSAlert()
            alert.messageText = interface.unsentReports
            let note = entry.lastNote.map { "\n\($0)" } ?? ""
            alert.informativeText = "\(dateFormatter.string(from: entry.createdAt))\(note)"
            alert.addButton(withTitle: interface.sendAgain)
            alert.addButton(withTitle: interface.deleteButton)
            alert.addButton(withTitle: interface.close)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if !outbox.sendAgain(id: entry.id) {
                    let full = NSAlert()
                    full.messageText = interface.queueFull
                    full.addButton(withTitle: interface.ok)
                    full.runModal()
                    return
                }
            case .alertSecondButtonReturn:
                outbox.deleteFailed(id: entry.id)
            default:
                return
            }
        }
    }
}
