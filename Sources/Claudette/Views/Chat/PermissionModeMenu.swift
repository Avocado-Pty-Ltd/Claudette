import SwiftUI

/// A compact chip that shows the current permission mode and opens a menu to change it.
struct PermissionModeMenu: View {
    let mode: PermissionMode
    let onSelect: (PermissionMode) -> Void

    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack {
                        Image(systemName: option.iconName)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                            Text(option.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if option == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 10, weight: .semibold))
                Text(mode.label)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .foregroundStyle(Color(hex: mode.tintHex))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(hex: mode.tintHex).opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(hex: mode.tintHex).opacity(0.35), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permission mode — \(mode.description)")
    }
}
