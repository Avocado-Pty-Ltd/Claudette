import Foundation
import SwiftUI

enum PermissionMode: String, CaseIterable, Codable, Identifiable {
    case auto
    case acceptEdits
    case plan
    case `default`
    case bypassPermissions
    case dontAsk

    var id: String { rawValue }

    /// Value passed to `claude --permission-mode`.
    var cliValue: String { rawValue }

    var label: String {
        switch self {
        case .auto:              return "Auto"
        case .acceptEdits:       return "Accept edits"
        case .plan:              return "Plan"
        case .default:           return "Ask"
        case .bypassPermissions: return "Bypass"
        case .dontAsk:           return "Silent"
        }
    }

    var description: String {
        switch self {
        case .auto:
            return "Classifier decides when to auto-approve. Fast and safe for most tasks."
        case .acceptEdits:
            return "Auto-approve file edits. Prompts for shell + destructive tools."
        case .plan:
            return "Read-only planning. Claude sketches an approach without touching files."
        case .default:
            return "Prompt for every tool use — full manual control."
        case .bypassPermissions:
            return "Skip all permission checks. Use only in trusted sandboxes."
        case .dontAsk:
            return "Deny permission prompts silently. Claude works with what it can."
        }
    }

    var iconName: String {
        switch self {
        case .auto:              return "sparkles"
        case .acceptEdits:       return "pencil.and.list.clipboard"
        case .plan:              return "map"
        case .default:           return "hand.raised"
        case .bypassPermissions: return "bolt.circle"
        case .dontAsk:           return "moon"
        }
    }

    /// Colour used for the chip in the chat header.
    var tintHex: UInt32 {
        switch self {
        case .auto:              return 0xC96442  // accent
        case .acceptEdits:       return 0x4E8A7A  // teal
        case .plan:              return 0x6A8AAF  // blue
        case .default:           return 0x8A7B4E  // gold
        case .bypassPermissions: return 0xE5484D  // red
        case .dontAsk:           return 0x6C6459  // graphite
        }
    }

    static var initial: PermissionMode { .acceptEdits }
}
