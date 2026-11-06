import Foundation

public enum PageMessage: Equatable {
    case status(BotStatus)
    case credentialsRequest
    case rendererSlot(RendererSlotMessage)
}

/// A page asking for the renderer slot ("gpu-slot") or handing it back ("gpu-slot-done"). Only short alphanumeric
/// request ids are accepted.
public struct RendererSlotMessage: Equatable {
    public static let requestType = "gpu-slot"
    public static let doneType = "gpu-slot-done"

    public let done: Bool
    public let id: String

    public init(done: Bool, id: String) {
        self.done = done
        self.id = id
    }

    public static func parse(_ json: String?) -> RendererSlotMessage? {
        guard let json, json.utf8.count <= 256, let root = BoundedJson.object(json),
              let type = root["type"] as? String, let id = root["id"] as? String,
              type == requestType || type == doneType,
              (1...32).contains(id.count),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return RendererSlotMessage(done: type == doneType, id: id)
    }
}

public enum PageMessageInbox {
    public static let gameHost = "opensro.online"

    public static func accept(body: Any, isMainFrame: Bool, scheme: String, host: String, port: Int) -> PageMessage? {
        guard isMainFrame, scheme == "https", host == gameHost, port == 0 || port == 443,
              let json = body as? String else { return nil }
        if let status = BotStatus.parse(json) {
            return .status(status)
        }
        if let slot = RendererSlotMessage.parse(json) {
            return .rendererSlot(slot)
        }
        switch BotStatus.messageType(of: json) {
        case "credentials-request":
            return .credentialsRequest
        default:
            return nil
        }
    }
}

public enum PageMessages {
    public static func light(on: Bool) -> [String: Any] {
        ["type": "light", "on": on]
    }

    public static func frameLimit(_ fps: Int) -> [String: Any] {
        ["type": "frame-limit", "fps": fps]
    }

    public static func autoLogin(enabled: Bool, character: String, server: String) -> [String: Any] {
        ["type": "auto-login", "enabled": enabled, "character": character, "server": server]
    }

    public static func credentials(id: String, password: String) -> [String: Any] {
        ["type": "credentials", "id": id, "password": password]
    }

    public static func credentialsDenied(reason: String) -> [String: Any] {
        ["type": "credentials", "reason": reason]
    }

    public static func rendererSlotGrant(id: String) -> [String: Any] {
        ["type": RendererSlotMessage.requestType, "id": id]
    }
}
