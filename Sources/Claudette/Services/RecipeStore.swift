import Foundation
import AppKit

/// Loads the user's browser-task recipes from disk.
///
/// Claudette ships no recipes and this file creates none beyond an empty folder
/// and, on request, a blank template. A recipe encodes one person's rules for one
/// website — which pages matter, what a good result looks like, how to write to
/// the people there — and that is user data. Keeping it out of the app means the
/// open-source repository stays a generic browser-agent tool, and anyone's
/// workflow rules stay theirs, in a private repo or a synced folder if they like.
@MainActor
final class RecipeStore: ObservableObject {
    @Published private(set) var recipes: [BrowserRecipe] = []
    @Published private(set) var loadErrors: [String] = []

    /// `~/Library/Application Support/Claudette/browser-recipes`
    nonisolated static var directory: URL {
        BrowserAgentConfig.supportDir.appendingPathComponent("browser-recipes", isDirectory: true)
    }

    init() {
        reload()
    }

    func reload() {
        var found: [BrowserRecipe] = []
        var errors: [String] = []

        let fm = FileManager.default
        let dir = Self.directory
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            // No folder yet is the normal first-run state, not an error.
            recipes = []
            loadErrors = []
            return
        }

        for url in entries where url.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: url)
                var recipe = try JSONDecoder().decode(BrowserRecipe.self, from: data)
                // The filename is the stable identity: two recipes may share a
                // display name, and renaming inside the file shouldn't lose the
                // "last used" selection.
                recipe.id = url.deletingPathExtension().lastPathComponent
                if recipe.name.isEmpty { recipe.name = recipe.id }
                found.append(recipe)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        recipes = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        loadErrors = errors
    }

    func recipe(id: String) -> BrowserRecipe? {
        recipes.first { $0.id == id }
    }

    /// Create the folder if needed and reveal it in Finder — the discovery path
    /// for "where do I put these?".
    func revealDirectory() {
        ensureDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([Self.directory])
    }

    /// Write a blank template and open it in the user's editor. Returns the file
    /// URL, or nil if it couldn't be written.
    @discardableResult
    func createTemplate(named rawName: String) -> URL? {
        write(json: BrowserRecipe.templateJSON(name: rawName), named: rawName, openAfterWriting: true)
    }

    /// Save a recipe's JSON under a filename derived from its name. Shared by the
    /// blank template and by `/recipe`, so both land the same way: slugged
    /// filename, no clobbering, list reloaded.
    @discardableResult
    func write(json: String, named rawName: String, openAfterWriting: Bool = false) -> URL? {
        ensureDirectory()
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = name.isEmpty ? "new-recipe" : name
        // Slugify: the filename becomes the recipe id, so keep it path-safe.
        let slug = safeName
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "new-recipe" : slug

        // Never overwrite: a recipe the user has edited is their work.
        var url = Self.directory.appendingPathComponent("\(base).json")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Self.directory.appendingPathComponent("\(base)-\(counter).json")
            counter += 1
        }

        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            loadErrors = ["Couldn't write \(url.lastPathComponent): \(error.localizedDescription)"]
            return nil
        }
        reload()
        if openAfterWriting { NSWorkspace.shared.open(url) }
        return url
    }

    /// The file backing a recipe, or nil if it's gone from disk.
    func fileURL(id: String) -> URL? {
        let url = Self.directory.appendingPathComponent("\(id).json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Open a recipe file in whatever app owns `.json`.
    func openInEditor(id: String) {
        guard let url = fileURL(id: id) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Select the recipe file in Finder.
    func reveal(id: String) {
        guard let url = fileURL(id: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Move a recipe to the Trash — recoverable, never a hard delete: it's the
    /// user's file and one mis-click shouldn't cost them their rules.
    func moveToTrash(id: String) {
        guard let url = fileURL(id: id) else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            loadErrors = ["Couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)"]
            return
        }
        reload()
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: Self.directory,
            withIntermediateDirectories: true
        )
    }
}
