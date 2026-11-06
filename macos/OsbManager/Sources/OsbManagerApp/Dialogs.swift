import AppKit

@MainActor
enum Dialogs {
    static func confirm(_ question: String, detail: String? = nil, yes: String = "Yes", no: String = "No", style: NSAlert.Style = .warning, defaultYes: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail ?? ""
        alert.alertStyle = style
        alert.addButton(withTitle: defaultYes ? yes : no)
        alert.addButton(withTitle: defaultYes ? no : yes)
        let response = alert.runModal()
        return (response == .alertFirstButtonReturn) == defaultYes
    }

    static func info(_ message: String, detail: String? = nil, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail ?? ""
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func ask(title: String, prompt: String, initial: String, validate: (String) -> String?) -> String? {
        var text = initial
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.stringValue = text
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            text = field.stringValue
            guard let problem = validate(text) else { return text }
            info(problem, style: .warning)
        }
    }
}
