import SwiftUI

struct ProjectRow: View {
    let project: Project
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Theme.Palette.accent : Theme.Palette.borderStrong.opacity(0.55))
                .frame(width: 3, height: 22)
                .animation(.easeInOut(duration: 0.15), value: isSelected)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium, design: .default))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(project.displayPath)
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private var background: Color {
        if isSelected {
            return Theme.Palette.bgElevated
        }
        if isHovered {
            return Theme.Palette.bgSecondary.opacity(0.8)
        }
        return .clear
    }
}
