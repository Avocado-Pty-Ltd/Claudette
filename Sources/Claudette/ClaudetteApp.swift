import SwiftUI
import AppKit

@main
struct ClaudetteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var voiceConfig = VoiceConfig()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(projectStore)
                .environmentObject(voiceConfig)
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
}
