import Foundation

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var addedAt: Date
    var lastOpenedAt: Date
    var lastSessionId: String?
    var permissionMode: PermissionMode?

    init(id: UUID = UUID(),
         name: String,
         path: String,
         addedAt: Date = Date(),
         lastOpenedAt: Date = Date(),
         lastSessionId: String? = nil,
         permissionMode: PermissionMode? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.lastSessionId = lastSessionId
        self.permissionMode = permissionMode
    }

    var url: URL { URL(fileURLWithPath: path) }
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
