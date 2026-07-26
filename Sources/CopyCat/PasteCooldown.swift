import Foundation

/// One physical keystroke must produce at most one typed path.
///
/// Two independent paths can observe the same ⌘V: the registered chord, and
/// the IOHID paste-attempt sensor that runs while Secure Input blocks. Whether
/// a registered hot key still fires under Secure Input is not documented, so
/// this guard is shared by both paths rather than owned by either — it has to
/// hold whichever way that behaves.
///
/// Scoped per action, because only same-action deliveries can be the same
/// keystroke. A local paste followed by a broadcast is two deliberate presses
/// and both must land.
@MainActor
final class PasteCooldown {
    static let shared = PasteCooldown()

    private let window: TimeInterval
    private var lastAt: [HotkeyAction: TimeInterval] = [:]

    /// Wide enough to cover both paths reacting to one keystroke. A physical
    /// double-tap of the same chord inside the window is collapsed — the
    /// accepted cost of never typing the same path twice from a single press.
    init(window: TimeInterval = 1) {
        self.window = window
    }

    /// Records this attempt and reports whether it may proceed. A rejected
    /// attempt does not extend the window, so a held-down key can't starve the
    /// next deliberate paste indefinitely.
    func claim(_ action: HotkeyAction, now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Bool {
        if let last = lastAt[action], now - last <= window { return false }
        lastAt[action] = now
        return true
    }
}
