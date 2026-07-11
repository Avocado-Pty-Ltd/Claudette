import SwiftUI
import AppKit

/// Renders assistant text with a light-touch Markdown parser: paragraphs, headings,
/// bullet/numbered lists, inline code + emphasis, and fenced code blocks with a distinct card.
struct MarkdownText: View {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parse().enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MarkdownSegment) -> some View {
        switch segment {
        case .paragraph(let text):
            attributedText(text, style: .body)
        case .heading(let level, let text):
            attributedText(text, style: .heading(level))
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 12, alignment: .center)
                        attributedText(item, style: .body)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).")
                            .font(Theme.Font.body.monospacedDigit())
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .frame(width: 22, alignment: .trailing)
                        attributedText(item, style: .body)
                    }
                }
            }
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Theme.Palette.borderStrong)
                    .frame(width: 2)
                attributedText(text, style: .quote)
            }
        }
    }

    enum TextStyle {
        case body
        case heading(Int)
        case quote
    }

    private func attributedText(_ raw: String, style: TextStyle) -> some View {
        let attr = attributedString(from: raw, style: style)
        return Text(attr)
            .textSelection(.enabled)
            .lineSpacing(style.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attributedString(from raw: String, style: TextStyle) -> AttributedString {
        var result = AttributedString()
        let baseFont: Font
        let baseColor: Color
        switch style {
        case .body:
            baseFont = Theme.Font.bodySerif
            baseColor = Theme.Palette.textPrimary
        case .heading(let level):
            switch level {
            case 1: baseFont = .system(size: 22, weight: .semibold, design: .serif)
            case 2: baseFont = .system(size: 18, weight: .semibold, design: .default)
            case 3: baseFont = .system(size: 15, weight: .semibold, design: .default)
            default: baseFont = .system(size: 14, weight: .semibold, design: .default)
            }
            baseColor = Theme.Palette.textPrimary
        case .quote:
            baseFont = Theme.Font.bodySerif.italic()
            baseColor = Theme.Palette.textSecondary
        }

        for token in InlineParser.tokenize(raw) {
            var piece = AttributedString(token.text)
            piece.font = baseFont
            piece.foregroundColor = baseColor

            if token.bold { piece.font = piece.font?.weight(.semibold) }
            if token.italic {
                piece.font = piece.font?.italic()
            }
            if token.code {
                piece.font = .system(size: 13, weight: .regular, design: .monospaced)
                piece.backgroundColor = Theme.Palette.codeBg
                piece.foregroundColor = Theme.Palette.textPrimary
            }
            if let link = token.link, let url = URL(string: link) {
                piece.link = url
                piece.foregroundColor = Theme.Palette.accent
                piece.underlineStyle = .single
            }
            result.append(piece)
        }
        return result
    }
}

extension MarkdownText.TextStyle {
    var lineSpacing: CGFloat {
        switch self {
        case .body: return 4
        case .heading: return 2
        case .quote: return 3
        }
    }
}

// MARK: - Segment parser

enum MarkdownSegment: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case bulletList([String])
    case orderedList([String])
    case codeBlock(language: String, code: String)
    case quote(String)
}

extension MarkdownText {
    func parse() -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var paragraphLines: [String] = []
        var bulletItems: [String] = []
        var numberedItems: [String] = []
        var quoteLines: [String] = []
        var inFence = false
        var fenceLang = ""
        var fenceLines: [String] = []

        func flushParagraph() {
            if !paragraphLines.isEmpty {
                let text = paragraphLines.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { segments.append(.paragraph(text)) }
                paragraphLines.removeAll()
            }
        }
        func flushBullets() {
            if !bulletItems.isEmpty {
                segments.append(.bulletList(bulletItems))
                bulletItems.removeAll()
            }
        }
        func flushNumbered() {
            if !numberedItems.isEmpty {
                segments.append(.orderedList(numberedItems))
                numberedItems.removeAll()
            }
        }
        func flushQuote() {
            if !quoteLines.isEmpty {
                segments.append(.quote(quoteLines.joined(separator: " ")))
                quoteLines.removeAll()
            }
        }
        func flushAll() {
            flushParagraph()
            flushBullets()
            flushNumbered()
            flushQuote()
        }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            if inFence {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    segments.append(.codeBlock(language: fenceLang, code: fenceLines.joined(separator: "\n")))
                    fenceLines.removeAll()
                    fenceLang = ""
                    inFence = false
                } else {
                    fenceLines.append(line)
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushAll()
                inFence = true
                fenceLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if let (level, text) = parseHeading(trimmed) {
                flushAll()
                segments.append(.heading(level, text))
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph(); flushBullets(); flushNumbered()
                quoteLines.append(String(trimmed.dropFirst(2)))
                continue
            }
            if let bullet = parseBullet(trimmed) {
                flushParagraph(); flushNumbered(); flushQuote()
                bulletItems.append(bullet)
                continue
            }
            if let numbered = parseNumbered(trimmed) {
                flushParagraph(); flushBullets(); flushQuote()
                numberedItems.append(numbered)
                continue
            }
            flushBullets(); flushNumbered(); flushQuote()
            paragraphLines.append(trimmed)
        }
        if inFence {
            segments.append(.codeBlock(language: fenceLang, code: fenceLines.joined(separator: "\n")))
        }
        flushAll()
        return segments
    }

    private func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        return (level, String(line[line.index(after: idx)...]))
    }

    private func parseBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] {
            if line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
        }
        return nil
    }

    private func parseNumbered(_ line: String) -> String? {
        // e.g. "1. text" or "12. text"
        var idx = line.startIndex
        var count = 0
        while idx < line.endIndex, line[idx].isNumber, count < 4 {
            idx = line.index(after: idx)
            count += 1
        }
        guard count > 0, idx < line.endIndex, line[idx] == "." else { return nil }
        let next = line.index(after: idx)
        guard next < line.endIndex, line[next] == " " else { return nil }
        return String(line[line.index(after: next)...])
    }
}

// MARK: - Inline token parser

struct InlineToken {
    var text: String
    var bold: Bool = false
    var italic: Bool = false
    var code: Bool = false
    var link: String? = nil
}

enum InlineParser {
    static func tokenize(_ input: String) -> [InlineToken] {
        var tokens: [InlineToken] = []
        let chars = Array(input)
        var i = 0
        var current = ""

        func flush() {
            if !current.isEmpty {
                tokens.append(InlineToken(text: current))
                current = ""
            }
        }

        while i < chars.count {
            let c = chars[i]
            // Inline code `x`
            if c == "`" {
                flush()
                var j = i + 1
                while j < chars.count && chars[j] != "`" {
                    j += 1
                }
                if j < chars.count {
                    let inner = String(chars[(i+1)..<j])
                    tokens.append(InlineToken(text: inner, code: true))
                    i = j + 1
                    continue
                }
            }
            // Bold **x**
            if c == "*" && i + 1 < chars.count && chars[i+1] == "*" {
                flush()
                var j = i + 2
                while j + 1 < chars.count && !(chars[j] == "*" && chars[j+1] == "*") {
                    j += 1
                }
                if j + 1 < chars.count {
                    let inner = String(chars[(i+2)..<j])
                    tokens.append(contentsOf: applyStyle(to: tokenize(inner)) { $0.bold = true })
                    i = j + 2
                    continue
                }
            }
            // Italic *x* or _x_
            if (c == "*" || c == "_") {
                flush()
                let marker = c
                var j = i + 1
                while j < chars.count && chars[j] != marker {
                    j += 1
                }
                if j < chars.count && j > i + 1 {
                    let inner = String(chars[(i+1)..<j])
                    tokens.append(contentsOf: applyStyle(to: tokenize(inner)) { $0.italic = true })
                    i = j + 1
                    continue
                }
            }
            // Link [label](url)
            if c == "[" {
                if let close = firstIndex(of: "]", in: chars, from: i + 1),
                   close + 1 < chars.count, chars[close + 1] == "(",
                   let urlEnd = firstIndex(of: ")", in: chars, from: close + 2) {
                    flush()
                    let label = String(chars[(i+1)..<close])
                    let url = String(chars[(close+2)..<urlEnd])
                    var t = InlineToken(text: label)
                    t.link = url
                    tokens.append(t)
                    i = urlEnd + 1
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        flush()
        return tokens
    }

    private static func firstIndex(of char: Character, in chars: [Character], from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == char { return i }
            i += 1
        }
        return nil
    }

    private static func applyStyle(to tokens: [InlineToken], _ modify: (inout InlineToken) -> Void) -> [InlineToken] {
        tokens.map { t in
            var t = t
            modify(&t)
            return t
        }
    }
}
