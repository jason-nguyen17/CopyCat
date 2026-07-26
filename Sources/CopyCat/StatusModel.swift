import Foundation
import SwiftUI

/// Header state for the hot keys. The three not-working states are kept apart
/// because their recoveries have nothing in common: `off` is a toggle the user
/// set, `needsAccessibility` is a grant only System Settings can give, and
/// `unavailable` means something else on the system already owns the chord —
/// which is otherwise indistinguishable from the feature simply being off.
enum HotkeyStatus: Equatable, Sendable {
    case on
    case off
    case needsAccessibility
    case unavailable(chord: String)

    var menuLabel: String {
        switch self {
        case .on: "Hotkey on"
        case .off: "Hotkey off"
        case .needsAccessibility: "Hotkey needs Accessibility"
        case .unavailable(let chord): "\(chord) unavailable (another app may hold it)"
        }
    }
}

// Single source of truth for the menu header. The header used to read hot key
// and Secure Input state directly off PasteHandler, but those reads aren't
// observable — SwiftUI evaluated them once at launch and never refreshed, so
// the menu showed a permanently wrong state. Publishing here makes the header
// re-render whenever it actually changes. PasteHandler is the only writer
// (on the main thread).
@MainActor
final class StatusModel: ObservableObject {
    static let shared = StatusModel()

    /// Why the chords are or aren't intercepting — not whether one is armed
    /// this instant. Arming tracks the frontmost app, so surfacing it would
    /// make the header flicker on every app switch.
    @Published var hotkey: HotkeyStatus = .off
    /// Current Secure Input state for the menu; nil when clear. Includes
    /// benign holds (expected kind) so the menu can explain them quietly.
    @Published var secureInput: SecureInputPresentation?
    /// True only for alert-worthy blocks — drives the menu-bar icon badge and
    /// the orange menu treatment.
    @Published var secureInputAlerting = false

    // "CopyCat" for the release build, "CopyCat Dev" for the dev build. Read
    // from CFBundleDisplayName (set per-config in build-app.sh) so the two
    // builds are distinguishable in the menu without hardcoding either name.
    let appName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "CopyCat"
}
