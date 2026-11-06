import AppKit
import OsbManagerCore

public struct AccountForm {
    public var name: String
    public var startLight: Bool
    public var details: LoginDetails

    public init(name: String, startLight: Bool, details: LoginDetails) {
        self.name = name
        self.startLight = startLight
        self.details = details
    }
}

@MainActor
final class AccountPanel {
    let view = NSView()
    private let nameField = NSTextField()
    private let startLightBox = NSButton(checkboxWithTitle: "Start in light mode (no rendering, muted)", target: nil, action: nil)
    private let loginField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let serverField = NSTextField()
    private let characterField = NSTextField()
    private let autoLoginBox = NSButton(checkboxWithTitle: "Log in automatically", target: nil, action: nil)
    private let storeLabel = Layout.label("Select an account on the left.", secondary: true)
    private let passwordNote = Layout.label("", secondary: true)
    private let onSave: (AccountForm) -> Void
    private var controls: [NSControl] = []

    init(onSave: @escaping (AccountForm) -> Void, onForgetPassword: @escaping () -> Void, onStart: @escaping (Bool) -> Void, onToggleVisibility: @escaping () -> Void) {
        self.onSave = onSave
        for (field, label, width) in [(nameField, "Account name", 280.0), (loginField, "Login ID", 280.0), (passwordField, "Password", 200.0), (serverField, "Server", 280.0), (characterField, "Character", 280.0)] {
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        nameField.placeholderString = "Account name"
        serverField.placeholderString = "game default"
        characterField.placeholderString = "choose it yourself"
        let save = ActionButton("Save") { [unowned self] in self.save() }
        let start = ActionButton("Start") { onStart(false) }
        let startLight = ActionButton("Start light") { onStart(true) }
        let showHide = ActionButton("Show / Hide window", handler: onToggleVisibility)
        let forget = ActionButton("Forget password", handler: onForgetPassword)
        controls = [nameField, startLightBox, loginField, passwordField, serverField, characterField, autoLoginBox, save, start, startLight, showHide, forget]

        let grid = NSGridView(views: [
            [Layout.label("Name"), nameField],
            [NSView(), startLightBox],
            [Layout.label("Login ID"), loginField],
            [Layout.label("Password"), Layout.row([passwordField, forget])],
            [NSView(), passwordNote],
            [Layout.label("Server"), serverField],
            [Layout.label("Character"), characterField],
            [NSView(), autoLoginBox],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 80

        let hint = Layout.label(
            "Each account runs in its own browser profile: cookies, local storage and the game's own cache stay separate. " +
                "Hide keeps the account running with almost no CPU or GPU use. Removing an account deletes its browser profile.\n\n" +
                "Automatic login types the saved login ID and password into the game's login screen, picks the server and enters the character. " +
                "The password is kept in your macOS login Keychain and is sent only to the opensro.online page. " +
                "Leave Server empty for the game's default and Character empty to choose it yourself. " +
                "To resume hunting after an automatic login, turn on the bot's \"Start the bot when this character enters the game\".",
            secondary: true,
            wraps: true
        )
        hint.preferredMaxLayoutWidth = 560
        let stack = Layout.column([
            grid,
            Layout.row([save, start, startLight, showHide]),
            storeLabel,
            hint,
        ], spacing: 14)
        Layout.pin(stack, in: view, insets: NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18))
        show(nil, hasPassword: false)
    }

    func show(_ account: Account?, hasPassword: Bool) {
        controls.forEach { $0.isEnabled = account != nil }
        nameField.stringValue = account?.name ?? ""
        startLightBox.state = account?.startLight == true ? .on : .off
        loginField.stringValue = account?.loginId ?? ""
        passwordField.stringValue = ""
        let needsPassword = account?.autoLogin == true && !hasPassword
        passwordField.placeholderString = hasPassword ? "saved (leave empty to keep it)" : needsPassword ? "Enter the password again" : ""
        passwordNote.stringValue = needsPassword ? "Enter the password again: automatic login is on, but no password is saved on this Mac." : ""
        passwordNote.textColor = needsPassword ? .systemOrange : .secondaryLabelColor
        serverField.stringValue = account?.server ?? ""
        characterField.stringValue = account?.character ?? ""
        autoLoginBox.state = account?.autoLogin == true ? .on : .off
        storeLabel.stringValue = account.map { "Browser profile: \($0.dataStoreId.uuidString.lowercased())" } ?? "Select an account on the left."
    }

    var passwordNoteText: String { passwordNote.stringValue }

    func clearPasswordField() {
        passwordField.stringValue = ""
    }

    private func save() {
        let password = passwordField.stringValue
        onSave(AccountForm(
            name: nameField.stringValue,
            startLight: startLightBox.state == .on,
            details: LoginDetails(
                loginId: loginField.stringValue,
                password: password.isEmpty ? nil : password,
                server: serverField.stringValue,
                character: characterField.stringValue,
                autoLogin: autoLoginBox.state == .on
            )
        ))
    }
}
