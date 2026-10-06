import AppKit
import CoreGraphics

// Registers CopyCat's chords with the system instead of tapping the keystroke
// stream, and arms them only in the narrow window where CopyCat would actually
// act: a target terminal frontmost, an image on the clipboard, Accessibility
// granted.
//
// The arming is not an optimization, it's the whole design. A Carbon hot key is
// all-or-nothing — once registered the OS matches and swallows the chord before
// any app sees it, with no way to decline and let the keystroke through — and
// the chord in question is plain ⌘V. Holding it unconditionally would break
// paste in every app on the system. Registering only across the window where
// the keystroke was ours anyway reproduces the old conditional behavior.
//
// The gate inputs are all observable outside the keystroke path (workspace
// activation notifications, pasteboard change count, TCC trust), so nothing
// here sits between the user and their input. A handler that hangs can only
// delay CopyCat's own paste.
//
// The gate is sampled up to one poll interval before the keystroke lands, so
// it can be stale by the time a chord fires. That case is not a no-op: the
// keystroke is already gone, and `passThrough` has to hand it back.

/// The system inputs the arming decision reads. Injectable so the gate — the
/// rule standing between "⌘V works everywhere" and "⌘V is dead system-wide" —
/// can be exercised without a frontmost app, a real clipboard, a granted
/// Accessibility permission, or posting events at the live session.
@MainActor
struct HotkeyEnvironment {
    var frontmostBundleID: @MainActor () -> String?
    var clipboardHasImage: @MainActor () -> Bool
    var clipboardChangeCount: @MainActor () -> Int
    var accessibilityTrusted: @MainActor () -> Bool
    var postChord: @MainActor (HotkeyBinding) -> Void
    /// Shared with the Secure Input sensor in production, per-instance in
    /// tests: a process-global wall-clock window would make anything that
    /// reaches the paste itself depend on how fast the suite runs.
    var pasteCooldown: PasteCooldown
    var performPaste: @MainActor (HotkeyAction) -> Void

    static let system = HotkeyEnvironment(
        frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        clipboardHasImage: { NSPasteboard.general.hasImageType },
        clipboardChangeCount: { NSPasteboard.general.changeCount },
        accessibilityTrusted: { AXIsProcessTrusted() },
        postChord: { Typer.postChord($0) },
        pasteCooldown: .shared,
        performPaste: { action in
            // The clipboard is re-read on the worker, which bails cleanly if
            // the image vanished; keeping the read off the hot key handler
            // keeps it short.
            switch action {
            case .localPaste:
                DispatchQueue.global(qos: .userInitiated).async {
                    ImagePaste.handleLocal()
                }
            case .broadcast:
                DispatchQueue.global(qos: .userInitiated).async {
                    Broadcast.handle()
                }
            }
        })
}

@MainActor
final class PasteHandler {
    private let hotkeys: HotkeyManager
    private let environment: HotkeyEnvironment
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultsObservers: [NSObjectProtocol] = []
    private var clipboardPoll: Timer?
    private var lastClipboardChangeCount = 0

    // The pasteboard posts no change notification, so this poll bounds how
    // stale the arming decision can be — "screenshot, then immediately ⌘V"
    // has to land. A tick costs one integer read unless the clipboard moved,
    // and the timer only runs while a target app is frontmost.
    private static let clipboardPollInterval: TimeInterval = 0.25

    init(hotkeys: HotkeyManager = HotkeyManager(), environment: HotkeyEnvironment = .system) {
        self.hotkeys = hotkeys
        self.environment = environment
    }

    isolated deinit {
        // The run loop retains the poll timer, so without this it keeps ticking
        // against a dead weak self for the life of the process.
        removeObservers()
        setClipboardPolling(false)
    }

    func start() {
        hotkeys.onFire = { [weak self] action in
            self?.fire(action)
        }
        promptForAccessibilityIfNeeded()
        installObservers()
        reconcile(reason: "startup")
    }

    func stop() {
        removeObservers()
        setClipboardPolling(false)
        hotkeys.onFire = nil
        hotkeys.invalidate()
    }

    /// What the menu header should say about interception. Not "armed right
    /// now", which flips with every app switch and would read as breakage.
    /// Every not-working answer names its own cause: the alternative is one
    /// "off" that could mean a toggle, a missing grant, or a chord another app
    /// permanently owns, none of which are fixed the same way.
    var hotkeyStatus: HotkeyStatus {
        guard Settings.enableLocalPaste || Settings.enableBroadcast else { return .off }
        guard environment.accessibilityTrusted() else { return .needsAccessibility }
        if let failure = hotkeys.lastFailure {
            return .unavailable(chord: failure.binding.displayString)
        }
        return .on
    }

    // MARK: - Arming

    private func installObservers() {
        let wnc = NSWorkspace.shared.notificationCenter
        func workspace(_ name: Notification.Name, _ reason: String) {
            let token = wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reconcile(reason: reason)
                }
            }
            workspaceObservers.append(token)
        }

        workspace(NSWorkspace.didActivateApplicationNotification, "app activated")
        // Lock and sleep post no activation notification, so a chord armed in a
        // terminal is still held when the machine comes back — possibly with a
        // different app frontmost and a different clipboard. Re-derive it from
        // what is true now.
        workspace(NSWorkspace.didWakeNotification, "wake")
        workspace(NSWorkspace.screensDidWakeNotification, "screens woke")

        // Every user-facing toggle lands in UserDefaults, so one observer covers
        // enabling/disabling a chord, changing the broadcast chord, and editing
        // the target app list.
        let defaults = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcile(reason: "settings changed")
            }
        }
        defaultsObservers.append(defaults)
    }

    private func removeObservers() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        defaultsObservers.forEach { NotificationCenter.default.removeObserver($0) }
        defaultsObservers = []
    }

    func reconcile(reason: String) {
        let frontmost = environment.frontmostBundleID()
        let targets = Settings.targetBundleIDs
        let targetFrontmost = frontmost.map(targets.contains) ?? false

        setClipboardPolling(targetFrontmost)
        lastClipboardChangeCount = environment.clipboardChangeCount()

        // Only ask the pasteboard when the answer could change the plan; this
        // runs on every app switch and every clipboard change.
        let clipboardHasImage = targetFrontmost && environment.clipboardHasImage()

        // Re-read on every reconcile rather than caching from startup: the
        // grant can land while CopyCat is running, and this is what makes it
        // take effect without a restart.
        let accessibilityTrusted = environment.accessibilityTrusted()

        hotkeys.apply(
            HotkeyPlan.desired(
                frontmostBundleID: frontmost,
                targetBundleIDs: targets,
                clipboardHasImage: clipboardHasImage,
                accessibilityTrusted: accessibilityTrusted,
                localPasteEnabled: Settings.enableLocalPaste,
                broadcastEnabled: Settings.enableBroadcast,
                broadcastBinding: Settings.broadcastHotkey.binding),
            reason: reason)

        publishStatus()
    }

    var isPollingClipboard: Bool { clipboardPoll != nil }

    private func setClipboardPolling(_ enabled: Bool) {
        guard enabled != (clipboardPoll != nil) else { return }
        guard enabled else {
            clipboardPoll?.invalidate()
            clipboardPoll = nil
            return
        }
        clipboardPoll = Timer.scheduledTimer(
            withTimeInterval: Self.clipboardPollInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollClipboard()
            }
        }
    }

    private func pollClipboard() {
        let count = environment.clipboardChangeCount()
        guard count != lastClipboardChangeCount else { return }
        reconcile(reason: "clipboard changed")
    }

    // Push readiness into the observable menu model. The menu can't read it
    // live (the read isn't observable, so SwiftUI froze it at launch — the old
    // permanently-wrong header bug), so publish on every state change;
    // SecureInputWatcher also refreshes it on its own poll. Secure Input state
    // is owned end-to-end by SecureInputWatcher.
    private func publishStatus() {
        let status = hotkeyStatus
        let model = StatusModel.shared
        if model.hotkey != status { model.hotkey = status }
    }

    // MARK: - Dispatch

    func fire(_ action: HotkeyAction) {
        let category = action == .broadcast ? Log.cmdOptV : Log.cmdV

        // Both gate inputs are re-read rather than trusted from arming time:
        // an activation notification or a clipboard change can land after a
        // keystroke the user already pressed, and typing a file path into the
        // wrong app is worse than not pasting.
        let outcome = HotkeyFire.outcome(
            frontmostBundleID: environment.frontmostBundleID(),
            targetBundleIDs: Settings.targetBundleIDs,
            clipboardHasImage: environment.clipboardHasImage())

        if case .passThrough(let reason) = outcome {
            passThrough(action, reason: reason, category: category)
            return
        }

        guard environment.pasteCooldown.claim(action) else {
            category.info("ignored — this chord already pasted moments ago, so this is one keystroke arriving twice")
            return
        }

        environment.performPaste(action)
    }

    /// Hands back a keystroke CopyCat swallowed but won't act on. Without this
    /// the user's ⌘V is destroyed: the OS consumed it on our behalf and the
    /// focused app never saw it.
    private func passThrough(_ action: HotkeyAction, reason: HotkeyBailReason, category: AppLogger) {
        let binding = hotkeys.activeBindings[action]

        // Release before posting, always. The synthetic event carries the same
        // modifiers the hot key matches on, so posting it while the chord is
        // still claimed feeds it straight back into this handler — this
        // ordering is the entire loop guard.
        let released = binding != nil
            && hotkeys.release(action, reason: "passthrough (\(reason.rawValue))")

        // The gate that just failed is shared by every chord, not only the one
        // that fired. A sibling left armed goes on swallowing keystrokes for a
        // window that has already closed, so drop them in the same pass rather
        // than waiting for the next reconcile — including when the fired chord
        // itself turned out not to be held.
        for sibling in hotkeys.activeBindings.keys where sibling != action {
            guard let siblingBinding = hotkeys.activeBindings[sibling] else { continue }
            if hotkeys.release(sibling, reason: "passthrough sibling (\(reason.rawValue))") {
                category.info("also released \(siblingBinding.displayString) — the gate is closed for every chord")
            } else {
                category.error("could not release \(siblingBinding.displayString) on passthrough — it stays claimed")
            }
        }

        guard let binding else {
            category.info("bail (\(reason.rawValue)) — no chord held for this action, nothing to hand back")
            return
        }

        guard released, hotkeys.activeBindings[action] == nil else {
            category.error("passthrough aborted — \(binding.displayString) is still registered; posting it would re-enter this handler")
            return
        }

        category.info("bail (\(reason.rawValue)) — released \(binding.displayString) and handed the keystroke back")
        environment.postChord(binding)
        // Re-arming is left to the normal reconcile path. The gate just failed,
        // so it stays down until the conditions actually return.
    }

    // The hot key itself needs no TCC grant, but the paste does: typing the
    // file path posts synthetic key events, which the OS silently drops for an
    // untrusted process. Prompting at startup turns that into a permission
    // dialog rather than a menu that says "needs Accessibility" with no
    // explanation of when it was asked for.
    private func promptForAccessibilityIfNeeded() {
        // Hardcoded value of kAXTrustedCheckOptionPrompt — referencing the
        // global var trips Swift 6 strict concurrency (it's non-Sendable).
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(opts) else { return }
        Log.hotkey.error("Accessibility not granted — chords stay unregistered until it is. Grant in System Settings → Privacy & Security → Accessibility.")
    }
}

extension NSPasteboard {
    var hasImageType: Bool {
        guard let types else { return false }
        let imageTypes: Set<NSPasteboard.PasteboardType> = [
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.tiff"),
        ]
        return !Set(types).isDisjoint(with: imageTypes)
    }

    // Any flavor the frontmost app might paste on its own for a raw ⌘V. The
    // degraded (Secure Input) paste path can't swallow the original keystroke,
    // so it must only run when the terminal would paste nothing itself —
    // otherwise the terminal's paste and CopyCat's typed path both land.
    var hasTextLikeType: Bool {
        guard let types else { return false }
        let textTypes: Set<NSPasteboard.PasteboardType> = [
            .string, .rtf, .html, .fileURL, .URL,
        ]
        return !Set(types).isDisjoint(with: textTypes)
    }
}

enum Typer {
    // Deliver the path in a few Unicode events. Sending a key pair per
    // character can overwhelm terminal input editors; posting more than 20
    // UTF-16 units in one event can truncate the text. A private source keeps
    // the synthetic text independent of the physical ⌘ key being released.
    static func type(_ text: String) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        var chunk: [UniChar] = []

        func postChunk() {
            guard !chunk.isEmpty else { return }
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.flags = []
            chunk.withUnsafeBufferPointer { buffer in
                down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.flags = []
            up?.post(tap: .cghidEventTap)
            chunk.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 16 { postChunk() }
            chunk.append(contentsOf: units)
        }
        postChunk()
    }

    /// Re-posts a chord CopyCat swallowed and decided not to act on, so the
    /// focused app receives the keystroke the user actually pressed.
    ///
    /// Unlike `type`, this deliberately carries modifier flags — it is the
    /// chord — so it *will* match a live registration of the same chord. Only
    /// call it once that registration is gone.
    static func postChord(_ binding: HotkeyBinding) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let flags = CGEventFlags(rawValue: binding.modifiers)
        let key = CGKeyCode(binding.keyCode)

        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}
