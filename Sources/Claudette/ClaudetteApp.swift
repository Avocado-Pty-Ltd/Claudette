import SwiftUI
import AppKit

@main
struct ClaudetteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var voiceConfig = VoiceConfig()
    @StateObject private var permissions = PermissionsCoordinator()
    @StateObject private var prospectConfig = ProspectConfig()
    /// One prospecting runner for the whole app — it drives a real browser, and
    /// two of those racing each other on the same Chrome profile would collide.
    @StateObject private var prospectRunner = ProspectRunner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(projectStore)
                .environmentObject(voiceConfig)
                .environmentObject(permissions)
                .environmentObject(prospectConfig)
                .environmentObject(prospectRunner)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") {
                    NotificationCenter.default.post(name: .claudetteNewProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("New Chat") {
                    NotificationCenter.default.post(name: .claudetteNewChat, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command])

                Divider()

                Button("LinkedIn Prospecting…") {
                    NotificationCenter.default.post(name: .claudetteShowProspects, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .claudetteShowSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension Notification.Name {
    static let claudetteNewProject = Notification.Name("claudette.newProject")
    static let claudetteNewChat = Notification.Name("claudette.newChat")
    static let claudetteFillDraft = Notification.Name("claudette.fillDraft")
    static let claudetteShowResumeSheet = Notification.Name("claudette.showResumeSheet")
    static let claudetteShowSettings = Notification.Name("claudette.showSettings")
    /// Opens the LinkedIn prospecting panel. `userInfo["goal"]` pre-fills the
    /// goal field — that's how `/linkedin <goal>` hands off from the chat.
    static let claudetteShowProspects = Notification.Name("claudette.showProspects")
}
