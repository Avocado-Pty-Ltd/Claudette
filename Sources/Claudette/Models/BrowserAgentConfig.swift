import Foundation
import SwiftUI

/// Which model drives the browser agent. Separate from the model Claude Code runs
/// on — this one reads pages and writes drafts, and it runs on whatever the user
/// is happy to pay for (or on Ollama, locally, for free).
enum BrowserAgentProvider: String, CaseIterable, Codable, Identifiable {
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

    /// Environment variable the provider's SDK reads. Nil for Ollama, which talks
    /// to localhost and needs no key.
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

/// Persistent settings for the browser agent. Keys live in the Keychain;
/// everything else in UserDefaults, matching how `VoiceConfig` does it.
///
/// Note what isn't here: anything about a particular website. Site-specific rules
/// belong in a user's recipe file, not in Claudette's settings.
@MainActor
final class BrowserAgentConfig: ObservableObject {
    private static let providerKey = "browserAgent.provider"
    private static let modelKey = "browserAgent.model"
    private static let pythonPathKey = "browserAgent.pythonPath"
    private static let chromePathKey = "browserAgent.chromePath"
    private static let profileDirKey = "browserAgent.profileDir"
    private static let headlessKey = "browserAgent.headless"
    private static let maxStepsKey = "browserAgent.maxSteps"
    private static let personaKey = "browserAgent.persona"
    private static let toneKey = "browserAgent.tone"
    private static let lastRecipeKey = "browserAgent.lastRecipe"

    private static func keychainAccount(for provider: BrowserAgentProvider) -> String {
        "browserAgent.apiKey.\(provider.rawValue)"
    }

    @Published var provider: BrowserAgentProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            apiKey = KeychainStore.get(Self.keychainAccount(for: provider)) ?? ""
        }
    }
    /// Key for the *currently selected* provider. Swapping provider swaps the key
    /// in and out, so someone with two keys doesn't have to re-paste when they
    /// toggle between them.
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
    /// Browser user-data directory. The user signs into whatever sites they care
    /// about once, by hand, in this profile; Claudette never sees a password.
    @Published var profileDir: String {
        didSet { UserDefaults.standard.set(profileDir, forKey: Self.profileDirKey) }
    }
    /// Off by default: the first few runs are much easier to trust when you can
    /// watch the browser do it.
    @Published var headless: Bool {
        didSet { UserDefaults.standard.set(headless, forKey: Self.headlessKey) }
    }
    /// Hard ceiling on agent steps — where the time and the token bill stop.
    @Published var maxSteps: Int {
        didSet { UserDefaults.standard.set(maxSteps, forKey: Self.maxStepsKey) }
    }
    /// How the user describes themselves. Feeds any drafts' voice so they read
    /// like the user rather than like a template.
    @Published var persona: String {
        didSet { UserDefaults.standard.set(persona, forKey: Self.personaKey) }
    }
    @Published var tone: String {
        didSet { UserDefaults.standard.set(tone, forKey: Self.toneKey) }
    }
    /// Recipe id selected last time, so the panel reopens where you left it.
    @Published var lastRecipeId: String {
        didSet { UserDefaults.standard.set(lastRecipeId, forKey: Self.lastRecipeKey) }
    }

    /// Application Support/Claudette, where the browser profile, the managed
    /// virtualenv and the user's recipes live.
    static var supportDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Claudette", isDirectory: true)
    }

    static var defaultProfileDir: String {
        supportDir.appendingPathComponent("browser-profile", isDirectory: true).path
    }

    /// Where the managed virtualenv lives when the user installs browser-use from
    /// Settings. Inside Application Support so uninstalling Claudette takes it too.
    static var managedVenvDir: URL {
        supportDir.appendingPathComponent("browser-use-venv", isDirectory: true)
    }

    init() {
        let d = UserDefaults.standard
        let prov = BrowserAgentProvider(rawValue: d.string(forKey: Self.providerKey) ?? "") ?? .anthropic
        self.provider = prov
        self.apiKey = KeychainStore.get(Self.keychainAccount(for: prov)) ?? ""
        self.model = d.string(forKey: Self.modelKey) ?? ""
        self.pythonPath = d.string(forKey: Self.pythonPathKey) ?? ""
        self.chromePath = d.string(forKey: Self.chromePathKey) ?? ""
        self.profileDir = d.string(forKey: Self.profileDirKey) ?? Self.defaultProfileDir
        self.headless = d.bool(forKey: Self.headlessKey)
        // UserDefaults hands back 0 for a missing integer, so treat 0 as "unset".
        let steps = d.integer(forKey: Self.maxStepsKey)
        self.maxSteps = steps > 0 ? steps : 60
        self.persona = d.string(forKey: Self.personaKey) ?? ""
        self.tone = d.string(forKey: Self.toneKey) ?? ""
        self.lastRecipeId = d.string(forKey: Self.lastRecipeKey) ?? ""
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
