import SwiftUI
import AppKit

@main
struct ClaudetteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var voiceConfig = VoiceConfig()
    @StateObject private var permissions = PermissionsCoordinator()
    // These four are built together in `init` because the scheduler needs the
    // other three — so none of them declares an inline initial value.
    @StateObject private var browserConfig: BrowserAgentConfig
    @StateObject private var recipeStore: RecipeStore
    /// One browser-task runner for the whole app — it drives a real browser, and
    /// two of those racing each other on the same profile would collide.
    @StateObject private var browserRunner: BrowserTaskRunner
    @StateObject private var scheduler: TaskScheduler

    init() {
        let config = BrowserAgentConfig()
        let recipes = RecipeStore()
        let runner = BrowserTaskRunner()
        _browserConfig = StateObject(wrappedValue: config)
        _recipeStore = StateObject(wrappedValue: recipes)
        _browserRunner = StateObject(wrappedValue: runner)
        _scheduler = StateObject(wrappedValue: TaskScheduler(recipes: recipes, runner: runner, config: config))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(projectStore)
                .environmentObject(voiceConfig)
                .environmentObject(permissions)
                .environmentObject(browserConfig)
                .environmentObject(recipeStore)
                .environmentObject(browserRunner)
                .environmentObject(scheduler)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { scheduler.start() }
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

                Button("Browser Task…") {
                    NotificationCenter.default.post(name: .claudetteShowBrowserTask, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("New Recipe…") {
                    NotificationCenter.default.post(name: .claudetteComposeRecipe, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
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
    /// Opens the browser-task panel. `userInfo["goal"]` pre-fills the goal field
    /// — that's how `/browse <goal>` hands off from the chat.
    static let claudetteShowBrowserTask = Notification.Name("claudette.showBrowserTask")
    /// Opens the browser-task panel straight into the recipe composer.
    /// `userInfo["description"]` is what `/recipe <description>` was given.
    static let claudetteComposeRecipe = Notification.Name("claudette.composeRecipe")
}
