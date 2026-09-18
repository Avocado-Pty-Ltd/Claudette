import SwiftUI
import AppKit

/// Describe a browser task in plain English; Claude writes the recipe file.
///
/// The JSON is shown before anything is saved. A recipe is a file in the user's
/// own folder that may run unattended on a schedule — they should see what it
/// says before it lands, not discover it later.
struct RecipeComposerSheet: View {
    @EnvironmentObject var recipes: RecipeStore
    @StateObject private var composer = RecipeComposer()
    @Environment(\.dismiss) private var dismiss

    /// Pre-filled from `/recipe <description>`.
    let initialDescription: String
    /// Handed the new recipe's id so the panel can select it.
    let onSaved: (String) -> Void

    @State private var description: String = ""
    @State private var didAutoCompose = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch composer.state {
                    case .idle, .working:
                        promptSection
                    case .ready(let json, let recipe):
                        preview(json: json, recipe: recipe)
                    case .failed(let message):
                        promptSection
                        failureBanner(message)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: 660, height: 620)
        .background(Theme.Palette.bgPrimary)
        .onAppear {
            if description.isEmpty { description = initialDescription }
            // `/recipe <description>` should just go — the user already typed
            // their intent once; making them press a button again is friction.
            if !didAutoCompose, !initialDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                didAutoCompose = true
                composer.compose(description: initialDescription)
            }
        }
        .onDisappear { composer.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("New recipe")
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(subtitle)
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if composer.state.isWorking {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Palette.bgSecondary))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        switch composer.state {
        case .working: return "Claude is writing it…"
        case .ready: return "Read it before you save — this file is yours."
        case .failed: return "That didn't work."
        case .idle: return "Describe the task; Claude writes the file."
        }
    }

    // MARK: - Prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT SHOULD THIS RECIPE DO?")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextEditor(text: $description)
                    .font(Theme.Font.bodySerif)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(height: 140)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.bgElevated))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.border, lineWidth: 0.75))
                    .disabled(composer.state.isWorking)
                Text("Say which site, what a good result looks like, anything to ignore, whether you want text drafted, and when it should run. Claude fills in the rest.")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.examples, id: \.self) { example in
                        Button { description = example } label: {
                            Text(example)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.bgSecondary))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("Uses the Claude Code you're already signed into — no extra API key. Nothing is saved until you press Save.")
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private static let examples = [
        "Watch the pricing pages of three competitors on example.com every Tuesday and Thursday morning, and tell me anything that changed since last time.",
        "Search my council's planning portal for new applications within 2km of my address, and draft a short objection note for any that mention demolition.",
        "Check the arXiv listings for new papers on retrieval-augmented generation, skip anything that's just a benchmark, and summarise what's actually new."
    ]

    // MARK: - Preview

    private func preview(json: String, recipe: BrowserRecipe) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: recipe.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text(recipe.name)
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            VStack(alignment: .leading, spacing: 6) {
                summaryRow("Starts at", recipe.startURL.isEmpty ? "wherever the goal leads" : recipe.startURL)
                summaryRow("Stays on", recipe.allowedDomains.isEmpty
                           ? "anywhere — no domain fence"
                           : recipe.allowedDomains.joined(separator: ", "))
                summaryRow("Mode", recipe.readOnly
                           ? "read and draft only"
                           : "can interact — check this is what you want")
                summaryRow("Results", "up to \(recipe.maxFindings)")
                if !recipe.drafts.isEmpty {
                    summaryRow("Drafts", recipe.drafts.map { slot in
                        slot.limit.map { "\(slot.label) (\($0))" } ?? slot.label
                    }.joined(separator: ", "))
                }
                if let schedule = recipe.schedule, schedule.isActive {
                    summaryRow("Runs", schedule.summary)
                }
            }

            ForEach(recipe.scheduleProblems, id: \.self) { problem in
                warningRow(problem)
            }
            if !recipe.readOnly {
                warningRow("This recipe can interact with pages — it may click through forms and flows. Check the instructions below before saving.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("THE FILE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.textSecondary)
                ScrollView {
                    Text(json)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.codeBg))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.codeBorder, lineWidth: 0.75))
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func warningRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x8A7B4E))
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Metric.cornerMd).fill(Color(hex: 0x8A7B4E, alpha: 0.10)))
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DiffLine.removedRed)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Metric.cornerMd).fill(Color(hex: 0xE5484D, alpha: 0.08)))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if case .ready = composer.state {
                Button("Start over") { composer.reset() }
            }
            Spacer()
            switch composer.state {
            case .idle, .failed:
                Button("Cancel") { dismiss() }
                Button {
                    composer.compose(description: description)
                } label: {
                    Label("Write it", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .working:
                Button("Stop") { composer.cancel() }
            case .ready(let json, let recipe):
                Button("Save & open in editor") { save(json: json, recipe: recipe, thenEdit: true) }
                Button {
                    save(json: json, recipe: recipe, thenEdit: false)
                } label: {
                    Label("Save", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.Palette.bgSecondary)
        .overlay(Divider().overlay(Theme.Palette.border), alignment: .top)
    }

    private func save(json: String, recipe: BrowserRecipe, thenEdit: Bool) {
        guard let url = recipes.write(json: json, named: recipe.name, openAfterWriting: thenEdit) else { return }
        onSaved(url.deletingPathExtension().lastPathComponent)
        dismiss()
    }
}
