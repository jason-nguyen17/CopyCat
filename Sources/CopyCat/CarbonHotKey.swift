import Carbon.HIToolbox
import Foundation

/// What a registered chord does when it fires. Raw values are stamped into
/// `EventHotKeyID.id`; they only need to be stable and unique in this process.
enum HotkeyAction: UInt32, CaseIterable, Sendable {
    case localPaste = 1
    case broadcast = 2
}

// MARK: - Registration seam

/// Thin seam over the Carbon hot key C API. Tests substitute a fake so the
/// reconcile bookkeeping can be exercised without claiming real chords, which
/// would apply to the whole login session including the test runner's host.
@MainActor
protocol CarbonHotKeyRegistering: AnyObject {
    /// Fires with the action whose chord the system matched. By the time this
    /// runs the OS has already swallowed the keystroke — there is no way to
    /// decline it and let the event continue to the focused app, so a caller
    /// that decides not to act has to hand the keystroke back itself.
    var onFire: ((HotkeyAction) -> Void)? { get set }

    func register(_ action: HotkeyAction, keyCode: UInt32, carbonModifiers: UInt32) -> OSStatus
    func unregister(_ action: HotkeyAction) -> OSStatus
    func unregisterAll()
    /// Drops every chord *and* the process-wide event handler. Registering
    /// again reinstalls the handler, so this is teardown, not a one-way door.
    func invalidate()
}

@MainActor
final class SystemCarbonHotKeyRegistrar: CarbonHotKeyRegistering {
    var onFire: ((HotkeyAction) -> Void)?

    private var hotKeys: [HotkeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let installHandler: @MainActor (SystemCarbonHotKeyRegistrar) -> OSStatus

    /// Tags every `EventHotKeyID` we create so the handler ignores hot keys
    /// registered elsewhere in the process (a framework may install its own).
    fileprivate static let signature: OSType =
        Array("CpCt".utf8).reduce(OSType(0)) { ($0 << 8) | OSType($1) }

    /// Reported success but produced nothing usable — no hot key ref, or a
    /// handler the installer claimed to install. Recording either would leave
    /// a chord claimed with nothing behind it, so both surface as failures.
    private static let inconsistentStateStatus = OSStatus(paramErr)

    /// The installer is injectable because the interesting case is the failing
    /// one: registration has to fail closed when no handler got installed, and
    /// provoking that for real would mean claiming chords system-wide.
    init(installHandler: @escaping @MainActor (SystemCarbonHotKeyRegistrar) -> OSStatus
        = SystemCarbonHotKeyRegistrar.installSystemHandler) {
        self.installHandler = installHandler
    }

    isolated deinit {
        invalidate()
    }

    func register(_ action: HotkeyAction, keyCode: UInt32, carbonModifiers: UInt32) -> OSStatus {
        // Fail closed. A chord registered with no handler behind it is the
        // worst state available: the OS swallows the keystroke for every app
        // on the system and nothing ever acts on it.
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else { return handlerStatus }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref)

        guard status == noErr else { return status }
        // Recording a registration we hold no handle for would leak the chord
        // for the life of the process.
        guard let ref else { return Self.inconsistentStateStatus }
        hotKeys[action] = ref
        return noErr
    }

    func unregister(_ action: HotkeyAction) -> OSStatus {
        guard let ref = hotKeys[action] else { return noErr }
        let status = UnregisterEventHotKey(ref)
        guard status == noErr else {
            // Keep the ref. The chord is still claimed system-wide and this is
            // the only handle that can ever release it; dropping it here would
            // strand the chord for the life of the process.
            Log.hotkey.error("UnregisterEventHotKey failed (OSStatus \(status)) — chord stays claimed, keeping its ref for a later retry")
            return status
        }
        hotKeys.removeValue(forKey: action)
        return noErr
    }

    func unregisterAll() {
        for action in Array(hotKeys.keys) { _ = unregister(action) }
    }

    func invalidate() {
        unregisterAll()
        guard let handler else { return }
        // If a chord above refused to release, this leaves exactly the state
        // registration guards against — a claimed chord with no handler behind
        // it. There is no better option: keeping the handler installed past
        // deallocation makes its unretained context a use-after-free, and this
        // path only runs at teardown, where the process is going away and
        // taking its claims with it.
        // Must outlive every chord it dispatches for, and must not outlive
        // `self`: the handler's context is an unretained pointer to this
        // instance, so leaving it installed past deallocation is a
        // use-after-free waiting for the next matching chord.
        let status = RemoveEventHandler(handler)
        if status != noErr {
            Log.hotkey.error("RemoveEventHandler failed (OSStatus \(status))")
        }
        self.handler = nil
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handler == nil else { return noErr }

        let status = installHandler(self)
        if status != noErr {
            Log.hotkey.error("InstallEventHandler failed (OSStatus \(status)) — not claiming any chord, since a claimed chord with no handler swallows the keystroke and does nothing")
            return status
        }
        guard handler != nil else {
            Log.hotkey.error("event handler reported success but left no ref — not claiming any chord")
            return Self.inconsistentStateStatus
        }
        return noErr
    }

    static func installSystemHandler(_ registrar: SystemCarbonHotKeyRegistrar) -> OSStatus {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        // Only key-down: CopyCat acts on the press and has no key-up behavior,
        // so registering kEventHotKeyReleased would just add dispatches to drop.
        return InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, context in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id)
                guard status == noErr else { return status }
                // Identify the hot key before touching `context`: the pointer
                // is unretained, and resurrecting an object from it for an
                // event that was never ours is exactly the case where it is
                // most likely to be dead.
                guard id.signature == SystemCarbonHotKeyRegistrar.signature,
                      let action = HotkeyAction(rawValue: id.id),
                      let context else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon dispatches hot keys on the main thread; taking the
                // isolation without a hop keeps the handler's latency the
                // user's latency.
                return MainActor.assumeIsolated {
                    let registrar = Unmanaged<SystemCarbonHotKeyRegistrar>
                        .fromOpaque(context).takeUnretainedValue()
                    return registrar.dispatch(action)
                }
            },
            1,
            &spec,
            Unmanaged.passUnretained(registrar).toOpaque(),
            &registrar.handler)
    }

    private func dispatch(_ action: HotkeyAction) -> OSStatus {
        onFire?(action)
        return noErr
    }
}

// MARK: - Plan

/// Which chords CopyCat should be holding right now. Pure so the arming rule —
/// the thing standing between "⌘V works everywhere" and "⌘V is dead
/// system-wide" — is directly testable.
enum HotkeyPlan {
    static func desired(
        frontmostBundleID: String?,
        targetBundleIDs: Set<String>,
        clipboardHasImage: Bool,
        accessibilityTrusted: Bool,
        localPasteEnabled: Bool,
        broadcastEnabled: Bool,
        broadcastBinding: HotkeyBinding
    ) -> [HotkeyAction: HotkeyBinding] {
        // A registered chord is swallowed for every app on the system, so
        // CopyCat may only hold one while it would actually act on it.
        guard let frontmostBundleID,
              targetBundleIDs.contains(frontmostBundleID),
              clipboardHasImage else { return [:] }

        // Carbon registers chords without any TCC grant, but typing the path
        // posts synthetic key events, which the OS drops for an untrusted
        // process. Holding a chord in that state swallows ⌘V and produces
        // nothing at all — worse than never arming, so don't arm.
        guard accessibilityTrusted else { return [:] }

        var plan: [HotkeyAction: HotkeyBinding] = [:]
        if localPasteEnabled {
            plan[.localPaste] = .localPaste
        }
        if broadcastEnabled {
            // The chords are allowed to collide (⌘V is a selectable broadcast
            // chord). Carbon rejects a second registration of the same chord,
            // so the collision is resolved here instead: broadcast wins, which
            // is the precedence users already had.
            plan = plan.filter { $0.value != broadcastBinding }
            plan[.broadcast] = broadcastBinding
        }
        return plan
    }
}

// MARK: - Fire decision

/// Why a fired chord isn't being acted on. Both are races against the arming
/// gate: a chord is armed from state sampled up to one poll interval ago, and
/// the keystroke can land after that state changed.
enum HotkeyBailReason: String, Sendable {
    case frontmostNotATarget
    case clipboardImageGone
}

/// What to do with a chord the OS just handed over. `passThrough` is not "do
/// nothing": the keystroke was swallowed before any app saw it, so bailing
/// without handing it back destroys the user's ⌘V outright.
enum HotkeyFireOutcome: Equatable, Sendable {
    case act
    case passThrough(HotkeyBailReason)
}

enum HotkeyFire {
    static func outcome(
        frontmostBundleID: String?,
        targetBundleIDs: Set<String>,
        clipboardHasImage: Bool
    ) -> HotkeyFireOutcome {
        guard let frontmostBundleID, targetBundleIDs.contains(frontmostBundleID) else {
            return .passThrough(.frontmostNotATarget)
        }
        guard clipboardHasImage else { return .passThrough(.clipboardImageGone) }
        return .act
    }
}

// MARK: - Manager

/// A chord CopyCat wants but could not claim. Carries the binding as well as
/// the status so the menu can name the chord that is unavailable rather than
/// just reporting that something is wrong.
struct HotkeyFailure: Equatable, Sendable {
    let action: HotkeyAction
    let binding: HotkeyBinding
    let status: OSStatus
}

/// Owns the gap between a desired plan and what is actually registered with
/// the system.
@MainActor
final class HotkeyManager {
    var onFire: ((HotkeyAction) -> Void)?

    /// A failed registration for a chord that is *still* wanted. A failed chord
    /// is silent — nothing swallows the keystroke and nothing acts on it — so
    /// this is the only signal that CopyCat is inert, which is also why it must
    /// not outlive the plan that produced it. Ordered by action so the menu
    /// doesn't flip between two broken chords from one reconcile to the next.
    var lastFailure: HotkeyFailure? {
        failures.sorted { $0.key.rawValue < $1.key.rawValue }.first?.value
    }

    private let registrar: CarbonHotKeyRegistering
    private var registered: [HotkeyAction: HotkeyBinding] = [:]
    private var failures: [HotkeyAction: HotkeyFailure] = [:]
    /// Failures already reported, so a chord another app permanently owns is
    /// logged as a state rather than once per reconcile.
    private var loggedFailures: [HotkeyAction: OSStatus] = [:]
    private var loggedReleaseFailures: [HotkeyAction: OSStatus] = [:]

    init(registrar: CarbonHotKeyRegistering) {
        self.registrar = registrar
        registrar.onFire = { [weak self] action in
            self?.onFire?(action)
        }
    }

    convenience init() {
        self.init(registrar: SystemCarbonHotKeyRegistrar())
    }

    var activeBindings: [HotkeyAction: HotkeyBinding] { registered }

    func apply(_ desired: [HotkeyAction: HotkeyBinding], reason: String) {
        // Prune before the early return, not after: a chord that failed to
        // register and was then disabled leaves `desired == registered` true,
        // so anything kept here would report CopyCat as inert forever.
        failures = failures.filter { desired[$0.key] != nil }
        loggedFailures = loggedFailures.filter { desired[$0.key] != nil }

        guard desired != registered else { return }
        let before = registered

        // Every drop must complete before any claim: when a chord moves between
        // actions (enabling broadcast on ⌘V while local paste holds it), a claim
        // issued first hits the still-live registration and fails.
        for (action, binding) in registered where desired[action] != binding {
            let status = registrar.unregister(action)
            guard status == noErr else {
                // Keep it recorded. The system still holds the chord, and
                // reporting it as released would claim ⌘V is free while it is
                // in fact dead everywhere. The next apply retries the drop.
                if loggedReleaseFailures[action] != status {
                    loggedReleaseFailures[action] = status
                    Log.hotkey.error("unregister \(binding.displayString) failed (OSStatus \(status)) — chord still claimed, will retry")
                }
                continue
            }
            loggedReleaseFailures[action] = nil
            registered[action] = nil
        }

        for (action, binding) in desired where registered[action] == nil {
            let status = registrar.register(
                action,
                keyCode: UInt32(binding.keyCode),
                carbonModifiers: binding.carbonModifiers)
            guard status == noErr else {
                failures[action] = HotkeyFailure(action: action, binding: binding, status: status)
                if loggedFailures[action] != status {
                    loggedFailures[action] = status
                    Log.hotkey.error("register \(binding.displayString) failed (OSStatus \(status)) — chord will not be intercepted")
                }
                continue
            }
            registered[action] = binding
            failures[action] = nil
            loggedFailures[action] = nil
        }

        // A failed claim leaves the held set unchanged and retries next time;
        // don't narrate the retries.
        guard registered != before else { return }
        let held = registered.values.map(\.displayString).sorted().joined(separator: " ")
        Log.hotkey.info("\(reason): holding [\(held.isEmpty ? "nothing" : held)]")
    }

    /// Drops a single chord outside the plan cycle. Handing a swallowed
    /// keystroke back needs the chord gone *first*, or the re-posted event
    /// matches the still-live registration and comes straight back to us.
    /// Reports whether the chord is now free; the next apply re-arms it if the
    /// gate has reopened.
    func release(_ action: HotkeyAction, reason: String) -> Bool {
        guard let binding = registered[action] else { return true }
        let status = registrar.unregister(action)
        guard status == noErr else {
            Log.hotkey.error("release \(binding.displayString) failed (OSStatus \(status)) — chord stays claimed")
            return false
        }
        registered[action] = nil
        Log.hotkey.info("\(reason): released \(binding.displayString)")
        return true
    }

    func releaseAll() {
        registrar.unregisterAll()
        registered = [:]
        failures = [:]
        loggedFailures = [:]
        loggedReleaseFailures = [:]
    }

    /// Teardown: drop the chords and the event handler behind them.
    func invalidate() {
        releaseAll()
        registrar.invalidate()
    }
}
