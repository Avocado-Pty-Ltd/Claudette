import SwiftUI

/// A visual, line-level diff of `old` → `new`. Used for Edit/MultiEdit/Write actions.
/// - `compact` mode shows a small windowed preview; expanding reveals full context.
struct DiffView: View {
    let old: String
    let new: String
    var language: String? = nil
    /// When true, added/removed lines stream in staggered ("video-like") when the view first appears.
    var animateIn: Bool = false
    @State private var revealedChangedCount: Int = 0
    @State private var flashIndex: Int? = nil

    var body: some View {
        let hunks = DiffEngine.hunks(old: old, new: new, contextLines: 2)
        // Global index of each *changed* line across all hunks (used for stagger + reveal).
        let changedOrder: [String: Int] = Self.changedGlobalIndex(hunks: hunks)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hunks.enumerated()), id: \.offset) { i, hunk in
                if i > 0 {
                    HStack(spacing: 6) {
                        Rectangle().fill(Theme.Palette.codeBorder).frame(height: 0.5)
                        Text("…")
                            .font(Theme.Font.monoSmall)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Rectangle().fill(Theme.Palette.codeBorder).frame(height: 0.5)
                    }
                    .padding(.vertical, 3)
                }
                hunkView(hunk, hunkIndex: i, changedOrder: changedOrder)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.codeBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.Palette.codeBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            if animateIn {
                streamInChangedLines(total: changedOrder.count)
            } else {
                revealedChangedCount = changedOrder.count
            }
        }
    }

    @ViewBuilder
    private func hunkView(_ hunk: DiffHunk, hunkIndex: Int, changedOrder: [String: Int]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { lineIdx, line in
                diffLineRow(line, key: "\(hunkIndex)-\(lineIdx)", changedOrder: changedOrder)
            }
        }
    }

    private func diffLineRow(_ line: DiffLine, key: String, changedOrder: [String: Int]) -> some View {
        let orderIdx = changedOrder[key]
        let revealed = line.kind == .unchanged || (orderIdx.map { $0 < revealedChangedCount } ?? true)
        let flashing = orderIdx != nil && orderIdx == flashIndex && line.kind == .added

        return HStack(alignment: .top, spacing: 0) {
            Text(line.marker)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(line.markerColor)
                .frame(width: 26, alignment: .center)
                .padding(.top, 3)
            Text(line.text.isEmpty ? " " : line.text)
                .font(Theme.Font.cinemaMono)
                .foregroundStyle(line.textColor)
                .strikethrough(line.kind == .removed, color: DiffLine.removedRed.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.trailing, 12)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                line.background
                if flashing {
                    DiffLine.addedGreen.opacity(0.4)
                }
            }
        )
        .opacity(revealed ? 1.0 : 0.0)
        .offset(x: revealed ? 0 : (line.kind == .added ? -10 : 10))
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: revealed)
        .animation(.easeOut(duration: 0.35), value: flashing)
    }

    private func streamInChangedLines(total: Int) {
        guard total > 0 else { return }
        // Cap total stagger duration so big diffs don't drag.
        let maxDuration: Double = 1.0
        let perLine = min(0.05, maxDuration / Double(total))
        for i in 0..<total {
            DispatchQueue.main.asyncAfter(deadline: .now() + perLine * Double(i)) {
                revealedChangedCount = i + 1
                flashIndex = i
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if flashIndex == i { flashIndex = nil }
                }
            }
        }
    }

    /// Assigns a stable, hunk-major index to every changed line so we can stagger + flash.
    private static func changedGlobalIndex(hunks: [DiffHunk]) -> [String: Int] {
        var out: [String: Int] = [:]
        var n = 0
        for (h, hunk) in hunks.enumerated() {
            for (l, line) in hunk.lines.enumerated() {
                if line.kind != .unchanged {
                    out["\(h)-\(l)"] = n
                    n += 1
                }
            }
        }
        return out
    }
}

// MARK: - Diff model

struct DiffLine: Equatable {
    enum Kind { case unchanged, added, removed }
    var kind: Kind
    var text: String

    var marker: String {
        switch kind {
        case .unchanged: return " "
        case .added: return "+"
        case .removed: return "−"
        }
    }

    var background: Color {
        switch kind {
        case .unchanged: return .clear
        case .added:    return Self.addedGreen.opacity(0.22)
        case .removed:  return Self.removedRed.opacity(0.22)
        }
    }

    var textColor: Color {
        switch kind {
        case .unchanged: return Theme.Palette.textPrimary
        case .added:     return Self.addedGreen
        case .removed:   return Self.removedRed
        }
    }

    var markerColor: Color {
        switch kind {
        case .unchanged: return Theme.Palette.textTertiary
        case .added:     return Self.addedGreen
        case .removed:   return Self.removedRed
        }
    }

    // Standard git / GitHub diff palette — saturated so it reads on either theme.
    static let addedGreen   = Color(hex: 0x2EA043)
    static let removedRed   = Color(hex: 0xE5484D)
}

struct DiffHunk: Equatable {
    var lines: [DiffLine]
}

enum DiffEngine {
    /// Computes hunks from an LCS diff, keeping `contextLines` lines around each change.
    static func hunks(old: String, new: String, contextLines: Int = 2) -> [DiffHunk] {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let ops = lcsDiff(old: oldLines, new: newLines)

        var allLines: [DiffLine] = []
        allLines.reserveCapacity(ops.count)
        for op in ops {
            switch op {
            case .keep(let s): allLines.append(DiffLine(kind: .unchanged, text: s))
            case .add(let s): allLines.append(DiffLine(kind: .added, text: s))
            case .remove(let s): allLines.append(DiffLine(kind: .removed, text: s))
            }
        }

        // Slice into hunks around change clusters
        var hunks: [DiffHunk] = []
        var i = 0
        while i < allLines.count {
            // Find next change
            guard let firstChange = (i..<allLines.count).first(where: { allLines[$0].kind != .unchanged }) else {
                break
            }
            let start = max(0, firstChange - contextLines)
            var end = firstChange
            var runLast = firstChange
            while end < allLines.count {
                if allLines[end].kind != .unchanged {
                    runLast = end
                    end += 1
                } else {
                    // Look ahead: if the next change is within 2*context lines, keep going.
                    var lookahead = end
                    var foundNext = false
                    while lookahead < allLines.count && lookahead - runLast <= contextLines * 2 {
                        if allLines[lookahead].kind != .unchanged {
                            foundNext = true
                            break
                        }
                        lookahead += 1
                    }
                    if foundNext {
                        end = lookahead
                    } else {
                        break
                    }
                }
            }
            let hunkEnd = min(allLines.count, runLast + 1 + contextLines)
            hunks.append(DiffHunk(lines: Array(allLines[start..<hunkEnd])))
            i = hunkEnd
        }

        if hunks.isEmpty {
            // Pure add or pure keep — just show everything (bounded).
            let bounded = Array(allLines.prefix(200))
            return [DiffHunk(lines: bounded)]
        }
        return hunks
    }

    enum Op {
        case keep(String)
        case add(String)
        case remove(String)
    }

    static func lcsDiff(old: [String], new: [String]) -> [Op] {
        let m = old.count
        let n = new.count
        // Guard: large diffs get truncated to keep the UI snappy.
        if m + n > 4000 {
            var ops: [Op] = old.map { .remove($0) }
            ops.append(contentsOf: new.map { .add($0) })
            return ops
        }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if old[i] == new[j] {
                    dp[i+1][j+1] = dp[i][j] + 1
                } else {
                    dp[i+1][j+1] = max(dp[i][j+1], dp[i+1][j])
                }
            }
        }
        var i = m, j = n
        var out: [Op] = []
        while i > 0 && j > 0 {
            if old[i-1] == new[j-1] {
                out.append(.keep(old[i-1])); i -= 1; j -= 1
            } else if dp[i-1][j] >= dp[i][j-1] {
                out.append(.remove(old[i-1])); i -= 1
            } else {
                out.append(.add(new[j-1])); j -= 1
            }
        }
        while i > 0 { out.append(.remove(old[i-1])); i -= 1 }
        while j > 0 { out.append(.add(new[j-1])); j -= 1 }
        return out.reversed()
    }
}
