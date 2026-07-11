import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            DetailContainer()
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.Palette.bgPrimary.ignoresSafeArea())
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudetteShowSettings)) { _ in
            showingSettings = true
        }
        .onAppear {
            configureAppearance()
        }
    }

    private func configureAppearance() {
        NSApp.appearance = nil // follow system
        for window in NSApp.windows {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(Theme.Palette.bgPrimary)
            window.isMovableByWindowBackground = false
        }
    }
}

struct DetailContainer: View {
    @EnvironmentObject var store: ProjectStore
    @StateObject private var sessionHolder = SessionHolder()

    var body: some View {
        Group {
            if let project = store.selectedProject {
                ChatView(project: project)
                    .id(project.id)
                    .environmentObject(sessionHolder.session(for: project))
            } else {
                EmptyStateView()
            }
        }
        .background(Theme.Palette.bgPrimary)
    }
}

@MainActor
final class SessionHolder: ObservableObject {
    private var sessions: [UUID: ClaudeChatSession] = [:]

    func session(for project: Project) -> ClaudeChatSession {
        if let s = sessions[project.id] { return s }
        let s = ClaudeChatSession(project: project)
        sessions[project.id] = s
        return s
    }
}
