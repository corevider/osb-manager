import Foundation

public struct WindowPlacement: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var maximized: Bool

    public init(x: Int, y: Int, width: Int, height: Int, maximized: Bool) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.maximized = maximized
    }
}

public struct Account: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var startLight: Bool
    public var window: WindowPlacement?
    public var dataStoreId: UUID
    public var loginId: String
    public var server: String
    public var character: String
    public var autoLogin: Bool

    public init(
        id: String,
        name: String,
        startLight: Bool = false,
        window: WindowPlacement? = nil,
        dataStoreId: UUID = UUID(),
        loginId: String = "",
        server: String = "",
        character: String = "",
        autoLogin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.startLight = startLight
        self.window = window
        self.dataStoreId = dataStoreId
        self.loginId = loginId
        self.server = server
        self.character = character
        self.autoLogin = autoLogin
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, startLight, window, dataStoreId, loginId, server, character, autoLogin
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        startLight = try values.decodeIfPresent(Bool.self, forKey: .startLight) ?? false
        window = try values.decodeIfPresent(WindowPlacement.self, forKey: .window)
        dataStoreId = try values.decodeIfPresent(UUID.self, forKey: .dataStoreId) ?? UUID()
        loginId = try values.decodeIfPresent(String.self, forKey: .loginId) ?? ""
        server = try values.decodeIfPresent(String.self, forKey: .server) ?? ""
        character = try values.decodeIfPresent(String.self, forKey: .character) ?? ""
        autoLogin = try values.decodeIfPresent(Bool.self, forKey: .autoLogin) ?? false
    }
}
