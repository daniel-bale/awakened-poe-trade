import Foundation

public enum ItemCaptureFailure: Error, Equatable, LocalizedError {
    case gameChanged
    case keysStillHeld
    case clipboardTimeout
    case invalidItem
    case cancelled
    case accessibilityRequired
    case eventCreationFailed

    public var shouldPresentApp: Bool {
        self != .gameChanged && self != .cancelled
    }

    public var errorDescription: String? {
        switch self {
        case .gameChanged:
            return "Item capture stopped because Path of Exile is no longer the active app."
        case .keysStillHeld:
            return "Release the shortcut keys to copy the item, then try again."
        case .clipboardTimeout:
            return "Path of Exile did not copy an item. Hover an item and try the shortcut again."
        case .invalidItem:
            return "The newly copied text is not a Path of Exile item. Hover an item and try again."
        case .cancelled:
            return "Item capture was cancelled."
        case .accessibilityRequired:
            return "Enable Awakened PoE Trade in System Settings → Privacy & Security → Accessibility to copy the hovered item with one shortcut."
        case .eventCreationFailed:
            return "macOS could not create the copy shortcut. Try again."
        }
    }
}

public enum ItemCaptureDecision: Equatable {
    case waiting
    case sendCopy
    case captured(String, changeCount: Int)
    case failed(ItemCaptureFailure)
}

/// A single capture attempt. This type has no clipboard, keyboard, or UI access.
/// Callers supply observations, then carry out each returned action once.
public struct ItemCaptureSession {
    private enum Phase {
        case releasingKeys(deadline: TimeInterval)
        case awaitingClipboard(baseline: Int, deadline: TimeInterval)
        case finished
    }

    private let gameProcessID: Int32
    private let clipboardTimeout: TimeInterval
    private var phase: Phase

    public init(
        gameProcessID: Int32,
        startedAt: TimeInterval,
        keyReleaseTimeout: TimeInterval = 1,
        clipboardTimeout: TimeInterval = 1
    ) {
        self.gameProcessID = gameProcessID
        self.clipboardTimeout = clipboardTimeout
        phase = .releasingKeys(deadline: startedAt + keyReleaseTimeout)
    }

    public mutating func pollKeysReleased(
        _ released: Bool,
        frontmostProcessID: Int32?,
        now: TimeInterval,
        clipboardChangeCount: Int
    ) -> ItemCaptureDecision {
        guard case .releasingKeys(let deadline) = phase else { return .waiting }
        guard frontmostProcessID == gameProcessID else { return fail(.gameChanged) }
        guard now < deadline else { return fail(.keysStillHeld) }
        guard released else { return .waiting }
        phase = .awaitingClipboard(baseline: clipboardChangeCount, deadline: now + clipboardTimeout)
        return .sendCopy
    }

    public mutating func pollClipboard(
        frontmostProcessID: Int32?,
        now: TimeInterval,
        changeCount: Int,
        text: String?
    ) -> ItemCaptureDecision {
        guard case .awaitingClipboard(let baseline, let deadline) = phase else { return .waiting }
        guard frontmostProcessID == gameProcessID else { return fail(.gameChanged) }
        guard now < deadline else { return fail(.clipboardTimeout) }
        // Existing item text is never evidence that this attempt copied anything.
        guard changeCount != baseline else { return .waiting }
        // Some producers clear the pasteboard shortly before writing the text.
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .waiting }
        guard Self.isItemText(text) else { return fail(.invalidItem) }
        phase = .finished
        return .captured(text, changeCount: changeCount)
    }

    public mutating func cancel() -> ItemCaptureDecision {
        guard case .finished = phase else { return fail(.cancelled) }
        return .waiting
    }

    public static func isItemText(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let classPrefixes = ["Item Class:", "物品種類:", "物品種類：", "物品类别:", "物品类别："]
        let rarityPrefixes = ["Rarity:", "稀有度:", "稀有度："]
        func hasValue(prefixes: [String]) -> Bool {
            lines.contains { line in
                prefixes.contains { prefix in
                    line.hasPrefix(prefix) && !line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).isEmpty
                }
            }
        }
        return hasValue(prefixes: classPrefixes) && hasValue(prefixes: rarityPrefixes)
            && lines.contains("--------")
    }

    public static func shouldRestoreClipboard(capturedChangeCount: Int, currentChangeCount: Int) -> Bool {
        capturedChangeCount == currentChangeCount
    }

    private mutating func fail(_ error: ItemCaptureFailure) -> ItemCaptureDecision {
        phase = .finished
        return .failed(error)
    }
}
