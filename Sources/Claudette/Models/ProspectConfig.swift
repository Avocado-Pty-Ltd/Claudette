import Foundation
import SwiftUI

/// Which model drives the browser-use agent. Separate from the model Claude Code
/// runs on — this one reads pages and writes drafts, and it runs on whatever the
/// user is happy to pay for (or on Ollama, locally, for free).
enum ProspectProvider: String, CaseIterable, Codable, Identifiable {
    case anthropic, openai, google, ollama

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .google: return "Google"
        case .ollama: return "Ollama (local)"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-5"
        case .openai: return "gpt-4.1-mini"
        case .google: return "gemini-2.5-flash"
        case .ollama: return "qwen2.5:7b"
        }
    }

    /// Environment variable the provider's SDK reads. Nil for Ollama, which
    /// talks to localhost and needs no key.
    var apiKeyEnvVar: String? {
        switch self {
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        case .google: return "GOOGLE_API_KEY"
        case .ollama: return nil
        }
    }

    var needsKey: Bool { apiKeyEnvVar != nil }

    var keyHelp: String {
        switch self {
        case .anthropic: return "console.anthropic.com → API keys."
        case .openai: return "platform.openai.com → API keys."
        case .google: return "aistudio.google.com → Get API key."
        case .ollama: return "No key needed — Claudette talks to Ollama on localhost."
        }
    }
}

/// What a run should look for.
enum ProspectMode: String, CaseIterable, Codable, Identifiable {
    case both, contacts, comments

    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: return "Contacts + comments"
        case .contacts: return "Contacts to add"
        case .comments: return "Posts to comment on"
        }
    }

    var iconName: String {
        switch self {
        case .both: return "person.2.badge.plus"
        case .contacts: return "person.badge.plus"
        case .comments: return "bubble.left.and.text.bubble.right"
        }
    }
}

/// Persistent settings for LinkedIn prospecting. Keys live in the Keychain;
/// everything else in UserDefaults, matching how `VoiceConfig` does it.
@MainActor
final class ProspectConfig: ObservableObject {
    private static let providerKey = "prospect.provider"
    private static let modelKey = "prospect.model"
    private static let pythonPathKey = "prospect.pythonPath"
    private static let chromePathKey = "prospect.chromePath"
    private static let profileDirKey = "prospect.profileDir"
    private static let headlessKey = "prospect.headless"
    private static let maxContactsKey = "prospect.maxContacts"
    private static let maxCommentsKey = "prospect.maxComments"
    private static let maxStepsKey = "prospect.maxSteps"
    private static let aboutMeKey = "prospect.aboutMe"
    private static let toneKey = "prospect.tone"
    private static let modeKey = "prospect.mode"

    private static func keychainAccount(for provider: ProspectProvider) -> String {
        "prospect.apiKey.\(provider.rawValue)"
    }

    @Published var provider: ProspectProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            apiKey = KeychainStore.get(Self.keychainAccount(for: provider)) ?? ""
        }
    }
    /// Key for the *currently selected* provider. Swapping provider swaps the
    /// key in and out, so someone with both an Anthropic and an OpenAI key
    /// doesn't have to re-paste when they toggle.
    @Published var apiKey: String {
        didSet { KeychainStore.set(Self.keychainAccount(for: provider), value: apiKey) }
    }
    /// Empty means "use the provider's default model".
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }
    /// Empty means "find a Python with browser-use installed" — see BrowserUseService.
    @Published var pythonPath: String {
        didSet { UserDefaults.standard.set(pythonPath, forKey: Self.pythonPathKey) }
    }
    /// Empty means "let browser-use pick its own Chromium".
    @Published var chromePath: String {
        didSet { UserDefaults.standard.set(chromePath, forKey: Self.chromePathKey) }
    }
    /// Chrome user-data directory holding the LinkedIn login. Claudette never
    /// stores LinkedIn credentials — the user signs in once, by hand, in this
    /// profile, and the agent reuses that session.
    @Published var profileDir: String {
        didSet { UserDefaults.standard.set(profileDir, forKey: Self.profileDirKey) }
    }
    /// Off by default: the first few runs are much easier to trust when you can
    /// watch the browser do it.
    @Published var headless: Bool {
        didSet { UserDefaults.standard.set(headless, forKey: Self.headlessKey) }
    }
    @Published var maxContacts: Int {
        didSet { UserDefaults.standard.set(maxContacts, forKey: Self.maxContactsKey) }
    }
    @Published var maxComments: Int {
        didSet { UserDefaults.standard.set(maxComments, forKey: Self.maxCommentsKey) }
    }
    /// Hard ceiling on agent steps — the cost and time stop here even if the
    /// model would happily keep browsing.
    @Published var maxSteps: Int {
        didSet { UserDefaults.standard.set(maxSteps, forKey: Self.maxStepsKey) }
    }
    /// How the user describes themselves. Feeds the drafts' voice, so a note
    /// reads like them rather than like a template.
    @Published var aboutMe: String {
        didSet { UserDefaults.standard.set(aboutMe, forKey: Self.aboutMeKey) }
    }
    @Published var tone: String {
        didSet { UserDefaults.standard.set(tone, forKey: Self.toneKey) }
    }
    @Published var mode: ProspectMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    static var defaultProfileDir: String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("Claudette", isDirectory: true)
            .appendingPathComponent("linkedin-profile", isDirectory: true)
            .path
    }

    /// Where the managed virtualenv lives when the user installs browser-use
    /// from Settings. Kept inside Application Support so uninstalling Claudette
    /// takes it with them.
    static var managedVenvDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("Claudette", isDirectory: true)
            .appendingPathComponent("browser-use-venv", isDirectory: true)
    }

    init() {
        let d = UserDefaults.standard
        let prov = ProspectProvider(rawValue: d.string(forKey: Self.providerKey) ?? "") ?? .anthropic
        self.provider = prov
        self.apiKey = KeychainStore.get(Self.keychainAccount(for: prov)) ?? ""
        self.model = d.string(forKey: Self.modelKey) ?? ""
        self.pythonPath = d.string(forKey: Self.pythonPathKey) ?? ""
        self.chromePath = d.string(forKey: Self.chromePathKey) ?? ""
        self.profileDir = d.string(forKey: Self.profileDirKey) ?? Self.defaultProfileDir
        self.headless = d.bool(forKey: Self.headlessKey)
        // UserDefaults hands back 0 for a missing integer, so treat 0 as "unset".
        let contacts = d.integer(forKey: Self.maxContactsKey)
        self.maxContacts = contacts > 0 ? contacts : 8
        let comments = d.integer(forKey: Self.maxCommentsKey)
        self.maxComments = comments > 0 ? comments : 5
        let steps = d.integer(forKey: Self.maxStepsKey)
        self.maxSteps = steps > 0 ? steps : 60
        self.aboutMe = d.string(forKey: Self.aboutMeKey) ?? ""
        self.tone = d.string(forKey: Self.toneKey) ?? ""
        self.mode = ProspectMode(rawValue: d.string(forKey: Self.modeKey) ?? "") ?? .both
    }

    /// The model name actually passed to the sidecar.
    var effectiveModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    /// True when a run can start: a provider key is present, or the provider
    /// doesn't need one.
    var hasCredentials: Bool {
        !provider.needsKey || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
