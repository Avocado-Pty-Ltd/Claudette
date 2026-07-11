import SwiftUI
import AppKit

struct ProjectSidebar: View {
    @EnvironmentObject var store: ProjectStore
    @State private var hoveredId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Palette.border)
            projectList
            Spacer(minLength: 0)
            footer
        }
        .background(Theme.Palette.bgSidebar)
        .onReceive(NotificationCenter.default.publisher(for: .claudetteNewProject)) { _ in
            pickProject()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.Palette.accent)
                    .frame(width: 30, height: 30)
                Text("C")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Claudette")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Claude Code, made lovely")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("PROJECTS")
                        .font(.system(size: 10, weight: .semibold, design: .default))
                        .tracking(1.4)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Spacer()
                    Button {
                        pickProject()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Theme.Palette.bgElevated.opacity(0.6))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Add project folder (⌘N)")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

                if store.projects.isEmpty {
                    emptyProjectHint
                } else {
                    ForEach(store.projects) { project in
                        ProjectRow(
                            project: project,
                            isSelected: store.selectedProjectId == project.id,
                            isHovered: hoveredId == project.id
                        )
                        .onHover { hovered in
                            hoveredId = hovered ? project.id : nil
                        }
                        .onTapGesture {
                            store.selectedProjectId = project.id
                        }
                        .contextMenu {
                            Button("Reveal in Finder") { reveal(project) }
                            Button("Copy Path") { copyPath(project) }
                            Divider()
                            Button("Remove from Claudette", role: .destructive) {
                                store.removeProject(project)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyProjectHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No projects yet.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Button {
                pickProject()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                    Text("Add a folder")
                }
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.Palette.border)
            HStack(spacing: 8) {
                Circle()
                    .fill(claudeBinaryFound ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(claudeBinaryFound ? "claude CLI ready" : "claude CLI not found")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var claudeBinaryFound: Bool {
        ClaudeChatSession.locateClaudeBinary() != nil
    }

    private func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder to build with Claudette."
        panel.prompt = "Add Project"
        if panel.runModal() == .OK, let url = panel.url {
            store.addProject(url: url)
        }
    }

    private func reveal(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }

    private func copyPath(_ project: Project) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.path, forType: .string)
    }
}
