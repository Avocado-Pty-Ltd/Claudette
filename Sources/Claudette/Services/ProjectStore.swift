import Foundation
import SwiftUI

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var selectedProjectId: UUID?

    private let storageURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = (appSupport ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Claudette", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("projects.json")
        load()
        if selectedProjectId == nil {
            selectedProjectId = projects.first?.id
        }
    }

    var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return projects.first(where: { $0.id == id })
    }

    func addProject(url: URL) {
        let path = url.path
        if let existing = projects.first(where: { $0.path == path }) {
            selectedProjectId = existing.id
            return
        }
        let project = Project(name: url.lastPathComponent, path: path)
        projects.append(project)
        sortAndPersist()
        selectedProjectId = project.id
    }

    func removeProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        if selectedProjectId == project.id {
            selectedProjectId = projects.first?.id
        }
        persist()
    }

    func markOpened(_ project: Project, sessionId: String? = nil) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx].lastOpenedAt = Date()
        if let sessionId {
            projects[idx].lastSessionId = sessionId
        }
        sortAndPersist()
    }

    func setPermissionMode(_ mode: PermissionMode, for project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx].permissionMode = mode
        persist()
    }

    private func sortAndPersist() {
        projects.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder.claudette.decode([Project].self, from: data) else { return }
        projects = decoded.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    private func persist() {
        do {
            let data = try JSONEncoder.claudette.encode(projects)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("Claudette: failed to persist projects: \(error)")
        }
    }
}

extension JSONEncoder {
    static let claudette: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let claudette: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
