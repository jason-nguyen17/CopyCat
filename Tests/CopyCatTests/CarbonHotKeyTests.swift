import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import CopyCat

// MARK: - Fake

/// Records what the manager asked for instead of claiming real chords —
/// registering ⌘V for real would swallow it for the whole login session,
/// including whatever is running the tests.
@MainActor
final class FakeRegistrar: CarbonHotKeyRegistering {
    enum Call: Equatable {
        case register(HotkeyAction, keyCode: UInt32, carbonModifiers: UInt32)
        case unregister(HotkeyAction)
        case unregisterAll
        case invalidate
    }

    var onFire: ((HotkeyAction) -> Void)?
    private(set) var calls: [Call] = []
    private(set) var live: Set<HotkeyAction> = []

    /// Status returned instead of success for these actions.
    var failures: [HotkeyAction: OSStatus] = [:]
    /// Same, for drops: the system keeps holding a chord it refused to release.
    var unregisterFailures: [HotkeyAction: OSStatus] = [:]

    func register(_ action: HotkeyAction, keyCode: UInt32, carbonModifiers: UInt32) -> OSStatus {
        calls.append(.register(action, keyCode: keyCode, carbonModifiers: carbonModifiers))
        if let status = failures[action] { return status }
        live.insert(action)
        return noErr
    }

    func unregister(_ action: HotkeyAction) -> OSStatus {
        calls.append(.unregister(action))
        if let status = unregisterFailures[action] { return status }
        live.remove(action)
        return noErr
    }

    func unregisterAll() {
        calls.append(.unregisterAll)
        live.removeAll()
    }

    func invalidate() {
        calls.append(.invalidate)
        live.removeAll()
    }

    func reset() { calls = [] }

    var registerCount: Int {
        calls.filter { if case .register = $0 { return true } else { return false } }.count
    }

    /// Index of the last drop and the first claim, for asserting that the
    /// manager never claims a chord before releasing whatever held it.
    var lastUnregisterIndex: Int? {
        calls.lastIndex { if case .unregister = $0 { return true } else { return false } }
    }

    var firstRegisterIndex: Int? {
        calls.firstIndex { if case .register = $0 { return true } else { return false } }
    }
}

// MARK: - Modifier conversion

final class HotkeyBindingCarbonTests: XCTestCase {
    private func binding(_ flags: CGEventFlags...) -> HotkeyBinding {
        HotkeyBinding(keyCode: 9, modifiers: flags.reduce(UInt64(0)) { $0 | $1.rawValue })
    }

    func testEachModifierMapsToItsCarbonBit() {
        XCTAssertEqual(binding(.maskCommand).carbonModifiers, UInt32(cmdKey))
        XCTAssertEqual(binding(.maskAlternate).carbonModifiers, UInt32(optionKey))
        XCTAssertEqual(binding(.maskControl).carbonModifiers, UInt32(controlKey))
        XCTAssertEqual(binding(.maskShift).carbonModifiers, UInt32(shiftKey))
    }

    func testNoModifiersProducesNoCarbonBits() {
        XCTAssertEqual(HotkeyBinding(keyCode: 9, modifiers: 0).carbonModifiers, 0)
    }

    func testModifiersCombine() {
        XCTAssertEqual(
            binding(.maskCommand, .maskAlternate).carbonModifiers,
            UInt32(cmdKey) | UInt32(optionKey))
        XCTAssertEqual(
            binding(.maskCommand, .maskControl, .maskShift).carbonModifiers,
            UInt32(cmdKey) | UInt32(controlKey) | UInt32(shiftKey))
    }

    func testLocalPasteConvertsToCommandOnly() {
        XCTAssertEqual(HotkeyBinding.localPaste.carbonModifiers, UInt32(cmdKey))
        XCTAssertEqual(HotkeyBinding.localPaste.keyCode, 9)
    }

    // Every combination round-trips: the two encodings share no bit values, so
    // a one-directional mapping error would otherwise only show up as a chord
    // that silently registers under the wrong modifiers.
    func testEveryModifierCombinationRoundTrips() {
        let all: [CGEventFlags] = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        for mask in 0..<(1 << all.count) {
            var flags: UInt64 = 0
            for (index, flag) in all.enumerated() where mask & (1 << index) != 0 {
                flags |= flag.rawValue
            }
            let original = HotkeyBinding(keyCode: 9, modifiers: flags)
            let restored = HotkeyBinding(keyCode: 9, carbonModifiers: original.carbonModifiers)
            XCTAssertEqual(restored, original, "round trip lost modifiers for mask \(mask)")
        }
    }

    func testEveryBroadcastChordRoundTrips() {
        for chord in BroadcastHotkey.allCases {
            let binding = chord.binding
            let restored = HotkeyBinding(keyCode: binding.keyCode, carbonModifiers: binding.carbonModifiers)
            XCTAssertEqual(restored, binding, "round trip lost \(chord.rawValue)")
        }
    }
}

// MARK: - Arming plan

final class HotkeyPlanTests: XCTestCase {
    private let targets: Set<String> = ["com.example.terminal", "com.example.console"]

    private func plan(
        frontmost: String? = "com.example.terminal",
        clipboardHasImage: Bool = true,
        accessibilityTrusted: Bool = true,
        local: Bool = true,
        broadcast: Bool = false,
        broadcastBinding: HotkeyBinding = BroadcastHotkey.cmdOptV.binding
    ) -> [HotkeyAction: HotkeyBinding] {
        HotkeyPlan.desired(
            frontmostBundleID: frontmost,
            targetBundleIDs: targets,
            clipboardHasImage: clipboardHasImage,
            accessibilityTrusted: accessibilityTrusted,
            localPasteEnabled: local,
            broadcastEnabled: broadcast,
            broadcastBinding: broadcastBinding)
    }

    // The gate cases below are the guardrail against the failure mode that
    // makes a registered chord dangerous: holding ⌘V when CopyCat would not
    // have acted means ⌘V is dead everywhere with no way to pass it through.
    func testHoldsNothingWhenNoAppIsFrontmost() {
        XCTAssertTrue(plan(frontmost: nil).isEmpty)
    }

    func testHoldsNothingWhenFrontmostIsNotATarget() {
        XCTAssertTrue(plan(frontmost: "com.example.browser").isEmpty)
    }

    func testHoldsNothingWhenClipboardHasNoImage() {
        XCTAssertTrue(plan(clipboardHasImage: false).isEmpty)
    }

    func testHoldsNothingWhenBothChordsAreDisabled() {
        XCTAssertTrue(plan(local: false, broadcast: false).isEmpty)
    }

    // Carbon registers a chord with no TCC grant at all, but the paste it
    // leads to can't type anything without one. Arming there would swallow ⌘V
    // and produce nothing — the one outcome worse than not arming.
    func testHoldsNothingWithoutAccessibility() {
        XCTAssertTrue(plan(accessibilityTrusted: false).isEmpty)
        XCTAssertTrue(plan(accessibilityTrusted: false, broadcast: true).isEmpty)
    }

    func testHoldsLocalPasteWhenGateIsOpen() {
        XCTAssertEqual(plan(), [.localPaste: .localPaste])
    }

    func testHoldsBothWhenChordsDiffer() {
        let expected: [HotkeyAction: HotkeyBinding] = [
            .localPaste: .localPaste,
            .broadcast: BroadcastHotkey.cmdOptV.binding,
        ]
        XCTAssertEqual(plan(broadcast: true), expected)
    }

    func testHoldsOnlyBroadcastWhenLocalPasteIsDisabled() {
        XCTAssertEqual(
            plan(local: false, broadcast: true),
            [.broadcast: BroadcastHotkey.cmdOptV.binding])
    }

    // Carbon rejects a second registration of the same chord, so a collision
    // has to collapse to one entry — and broadcast is the one that wins.
    func testBroadcastWinsWhenBothChordsAreCommandV() {
        let result = plan(local: true, broadcast: true, broadcastBinding: BroadcastHotkey.cmdV.binding)
        XCTAssertEqual(result, [.broadcast: HotkeyBinding.localPaste])
        XCTAssertNil(result[.localPaste])
    }
}

// MARK: - Manager lifecycle

@MainActor
final class HotkeyManagerTests: XCTestCase {
    private func makeManager() -> (HotkeyManager, FakeRegistrar) {
        let registrar = FakeRegistrar()
        return (HotkeyManager(registrar: registrar), registrar)
    }

    func testApplyRegistersDesiredChords() {
        let (manager, registrar) = makeManager()
        manager.apply([.localPaste: .localPaste], reason: "test")

        XCTAssertEqual(registrar.calls, [
            .register(.localPaste, keyCode: 9, carbonModifiers: UInt32(cmdKey)),
        ])
        XCTAssertEqual(manager.activeBindings, [.localPaste: .localPaste])
    }

    func testReapplyingTheSamePlanTouchesNothing() {
        let (manager, registrar) = makeManager()
        manager.apply([.localPaste: .localPaste], reason: "test")
        registrar.reset()

        manager.apply([.localPaste: .localPaste], reason: "test")
        XCTAssertTrue(registrar.calls.isEmpty)
    }

    func testChangingAChordReplacesTheRegistration() {
        let (manager, registrar) = makeManager()
        manager.apply([.broadcast: BroadcastHotkey.cmdOptV.binding], reason: "test")
        registrar.reset()

        manager.apply([.broadcast: BroadcastHotkey.cmdShiftV.binding], reason: "test")

        XCTAssertEqual(registrar.calls, [
            .unregister(.broadcast),
            .register(.broadcast, keyCode: 9, carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey)),
        ])
        XCTAssertEqual(manager.activeBindings, [.broadcast: BroadcastHotkey.cmdShiftV.binding])
    }

    func testDisablingAChordUnregistersIt() {
        let (manager, registrar) = makeManager()
        manager.apply([.localPaste: .localPaste], reason: "test")
        registrar.reset()

        manager.apply([:], reason: "test")

        XCTAssertEqual(registrar.calls, [.unregister(.localPaste)])
        XCTAssertTrue(manager.activeBindings.isEmpty)
        XCTAssertTrue(registrar.live.isEmpty)
    }

    // A chord handed from one action to another must be released first;
    // claiming it while the old registration is live fails in Carbon.
    func testChordMovingBetweenActionsIsReleasedBeforeItIsClaimed() {
        let (manager, registrar) = makeManager()
        manager.apply([.localPaste: .localPaste], reason: "test")
        registrar.reset()

        manager.apply([.broadcast: HotkeyBinding.localPaste], reason: "test")

        XCTAssertEqual(registrar.calls, [
            .unregister(.localPaste),
            .register(.broadcast, keyCode: 9, carbonModifiers: UInt32(cmdKey)),
        ])
        XCTAssertEqual(registrar.live, [.broadcast])
    }

    func testAllReleasesPrecedeAllClaimsWhenEveryChordChanges() {
        let (manager, registrar) = makeManager()
        manager.apply([
            .localPaste: .localPaste,
            .broadcast: BroadcastHotkey.cmdOptV.binding,
        ], reason: "test")
        registrar.reset()

        manager.apply([
            .localPaste: HotkeyBinding(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue),
            .broadcast: BroadcastHotkey.cmdCtrlV.binding,
        ], reason: "test")

        let lastRelease = try? XCTUnwrap(registrar.lastUnregisterIndex)
        let firstClaim = try? XCTUnwrap(registrar.firstRegisterIndex)
        XCTAssertNotNil(lastRelease)
        XCTAssertNotNil(firstClaim)
        XCTAssertLessThan(lastRelease ?? .max, firstClaim ?? .min)
    }

    func testFailedRegistrationIsSurfacedAndNotRecordedAsActive() {
        let (manager, registrar) = makeManager()
        registrar.failures[.localPaste] = OSStatus(-9878)

        manager.apply([.localPaste: .localPaste], reason: "test")

        XCTAssertEqual(manager.lastFailure?.status, OSStatus(-9878))
        XCTAssertTrue(manager.activeBindings.isEmpty)
    }

    func testOneFailedChordDoesNotDiscardTheOtherOne() {
        let (manager, registrar) = makeManager()
        registrar.failures[.broadcast] = OSStatus(-9878)

        manager.apply([
            .localPaste: .localPaste,
            .broadcast: BroadcastHotkey.cmdOptV.binding,
        ], reason: "test")

        XCTAssertEqual(manager.activeBindings, [.localPaste: .localPaste])
        XCTAssertEqual(manager.lastFailure?.status, OSStatus(-9878))
    }

    // A failed claim leaves nothing recorded, so the next apply must retry it
    // rather than treat the chord as already held.
    func testFailedRegistrationIsRetriedOnTheNextApply() {
        let (manager, registrar) = makeManager()
        registrar.failures[.localPaste] = OSStatus(-9878)
        manager.apply([.localPaste: .localPaste], reason: "test")

        registrar.failures = [:]
        registrar.reset()
        manager.apply([.localPaste: .localPaste], reason: "test")

        XCTAssertEqual(registrar.registerCount, 1)
        XCTAssertNil(manager.lastFailure)
        XCTAssertEqual(manager.activeBindings, [.localPaste: .localPaste])
    }

    // The failure outlives the plan it belongs to only if nobody prunes it:
    // once the chord is disabled, `desired == registered` short-circuits apply
    // and a retained status would report CopyCat as inert forever.
    func testFailureIsClearedWhenTheActionLeavesThePlan() {
        let (manager, registrar) = makeManager()
        registrar.failures[.localPaste] = OSStatus(-9878)
        manager.apply([.localPaste: .localPaste], reason: "test")
        XCTAssertEqual(manager.lastFailure?.status, OSStatus(-9878))

        manager.apply([:], reason: "test")

        XCTAssertNil(manager.lastFailure)
    }

    // The menu names the chord that is unavailable, so the failure has to carry
    // the binding and not just a status code.
    func testFailureIdentifiesTheChordThatCouldNotBeClaimed() {
        let (manager, registrar) = makeManager()
        registrar.failures[.broadcast] = OSStatus(-9878)

        manager.apply([.broadcast: BroadcastHotkey.cmdOptV.binding], reason: "test")

        XCTAssertEqual(manager.lastFailure?.action, .broadcast)
        XCTAssertEqual(manager.lastFailure?.binding, BroadcastHotkey.cmdOptV.binding)
    }

    func testFailureForOneActionSurvivesAnotherActionLeavingThePlan() {
        let (manager, registrar) = makeManager()
        registrar.failures[.broadcast] = OSStatus(-9878)
        manager.apply([
            .localPaste: .localPaste,
            .broadcast: BroadcastHotkey.cmdOptV.binding,
        ], reason: "test")

        manager.apply([.broadcast: BroadcastHotkey.cmdOptV.binding], reason: "test")

        XCTAssertEqual(manager.lastFailure?.status, OSStatus(-9878))
    }

    func testReleaseAllClearsBookkeeping() {
        let (manager, registrar) = makeManager()
        registrar.failures[.broadcast] = OSStatus(-9878)
        manager.apply([
            .localPaste: .localPaste,
            .broadcast: BroadcastHotkey.cmdOptV.binding,
        ], reason: "test")

        manager.releaseAll()

        XCTAssertTrue(manager.activeBindings.isEmpty)
        XCTAssertTrue(registrar.live.isEmpty)
        XCTAssertTrue(registrar.calls.contains(.unregisterAll))
        XCTAssertNil(manager.lastFailure)
    }

    func testInvalidateAlsoTearsDownTheEventHandler() {
        let (manager, registrar) = makeManager()
        manager.apply([.localPaste: .localPaste], reason: "test")

        manager.invalidate()

        XCTAssertTrue(manager.activeBindings.isEmpty)
        XCTAssertTrue(registrar.calls.contains(.invalidate))
    }

    // A refused drop means the system still holds the chord. Recording it as
    // released would claim ⌘V is free while it is in fact dead everywhere.
    func testFailedUnregisterKeepsTheChordRecordedAndRetriesIt() {
        let (manager, registrar) = makeManager()
        manager.apply([.localPaste: .localPaste], reason: "test")
        registrar.unregisterFailures[.localPaste] = OSStatus(-9874)
        registrar.reset()

        manager.apply([:], reason: "test")
        XCTAssertEqual(manager.activeBindings, [.localPaste: .localPaste])

        registrar.unregisterFailures = [:]
        registrar.reset()
        manager.apply([:], reason: "test")

        XCTAssertEqual(registrar.calls, [.unregister(.localPaste)])
        XCTAssertTrue(manager.activeBindings.isEmpty)
    }

    func testReleaseDropsOnlyTheRequestedChord() {
        let (manager, registrar) = makeManager()
        manager.apply([
            .localPaste: .localPaste,
            .broadcast: BroadcastHotkey.cmdOptV.binding,
        ], reason: "test")
        registrar.reset()

        XCTAssertTrue(manager.release(.localPaste, reason: "test"))

        XCTAssertEqual(registrar.calls, [.unregister(.localPaste)])
        XCTAssertEqual(manager.activeBindings, [.broadcast: BroadcastHotkey.cmdOptV.binding])
        XCTAssertEqual(registrar.live, [.broadcast])
    }

    func testReleaseReportsFailureAndKeepsTheChord() {
        let (manager, registrar) = makeManager()
        manager.apply([.localPaste: .localPaste], reason: "test")
        registrar.unregisterFailures[.localPaste] = OSStatus(-9874)

        XCTAssertFalse(manager.release(.localPaste, reason: "test"))
        XCTAssertEqual(manager.activeBindings, [.localPaste: .localPaste])
    }

    func testReleasedChordIsReArmedByTheNextApply() {
        let (manager, registrar) = makeManager()
        manager.apply([.localPaste: .localPaste], reason: "test")
        _ = manager.release(.localPaste, reason: "test")
        registrar.reset()

        manager.apply([.localPaste: .localPaste], reason: "test")

        XCTAssertEqual(registrar.calls, [
            .register(.localPaste, keyCode: 9, carbonModifiers: UInt32(cmdKey)),
        ])
        XCTAssertEqual(manager.activeBindings, [.localPaste: .localPaste])
    }

    func testFiringForwardsTheActionThroughTheManager() {
        let (manager, registrar) = makeManager()
        var fired: [HotkeyAction] = []
        manager.onFire = { fired.append($0) }

        registrar.onFire?(.broadcast)
        registrar.onFire?(.localPaste)

        XCTAssertEqual(fired, [.broadcast, .localPaste])
    }
}

// MARK: - Fail-closed registration

@MainActor
final class SystemCarbonHotKeyRegistrarTests: XCTestCase {
    // Only the failing installer is exercised. A successful one would go on to
    // claim a real chord for the whole login session — including whatever is
    // running these tests — which is exactly what the fake registrar exists to
    // avoid elsewhere.
    func testRegistrationBailsWhenTheHandlerCannotBeInstalled() {
        let registrar = SystemCarbonHotKeyRegistrar { _ in OSStatus(-9868) }

        let status = registrar.register(.localPaste, keyCode: 9, carbonModifiers: UInt32(cmdKey))

        XCTAssertEqual(status, OSStatus(-9868), "the installer's status must reach the caller")
    }

    // An installer that claims success without leaving a handler behind is the
    // same hazard wearing a noErr: a claimed chord with nothing listening
    // swallows the keystroke and does nothing with it.
    func testRegistrationBailsWhenTheInstallerLeavesNoHandler() {
        let registrar = SystemCarbonHotKeyRegistrar { _ in noErr }

        let status = registrar.register(.localPaste, keyCode: 9, carbonModifiers: UInt32(cmdKey))

        XCTAssertEqual(status, OSStatus(paramErr))
        XCTAssertEqual(registrar.unregister(.localPaste), noErr, "nothing should have been recorded as claimed")
    }
}

// MARK: - Fire decision

final class HotkeyFireTests: XCTestCase {
    private let targets: Set<String> = ["com.example.terminal"]

    private func outcome(
        frontmost: String? = "com.example.terminal",
        clipboardHasImage: Bool = true
    ) -> HotkeyFireOutcome {
        HotkeyFire.outcome(
            frontmostBundleID: frontmost,
            targetBundleIDs: targets,
            clipboardHasImage: clipboardHasImage)
    }

    func testActsWhenTheGateStillHolds() {
        XCTAssertEqual(outcome(), .act)
    }

    // Both bail cases are races against the arming gate, and both mean the
    // keystroke has already been swallowed — so neither can end in silence.
    func testPassesTheKeystrokeBackWhenFrontmostIsNoLongerATarget() {
        XCTAssertEqual(outcome(frontmost: "com.example.browser"), .passThrough(.frontmostNotATarget))
        XCTAssertEqual(outcome(frontmost: nil), .passThrough(.frontmostNotATarget))
    }

    func testPassesTheKeystrokeBackWhenTheImageIsGone() {
        XCTAssertEqual(outcome(clipboardHasImage: false), .passThrough(.clipboardImageGone))
    }
}

// MARK: - Shared paste cooldown

@MainActor
final class PasteCooldownTests: XCTestCase {
    func testFirstClaimIsAlwaysAllowed() {
        XCTAssertTrue(PasteCooldown(window: 1).claim(.localPaste, now: 0))
    }

    // The two paths that can see one physical ⌘V — the registered chord and
    // the IOHID sensor — must not each type the path.
    func testSecondClaimInsideTheWindowIsRejected() {
        let cooldown = PasteCooldown(window: 1)
        XCTAssertTrue(cooldown.claim(.localPaste, now: 100))
        XCTAssertFalse(cooldown.claim(.localPaste, now: 100.2))
    }

    func testClaimIsAllowedAgainAfterTheWindow() {
        let cooldown = PasteCooldown(window: 1)
        XCTAssertTrue(cooldown.claim(.localPaste, now: 100))
        XCTAssertFalse(cooldown.claim(.localPaste, now: 100.5))
        XCTAssertTrue(cooldown.claim(.localPaste, now: 101.6))
    }

    // Only same-action deliveries can be one keystroke seen twice. A local
    // paste followed by a broadcast is two deliberate presses and both land.
    func testAnotherActionIsNotSuppressedByTheWindow() {
        let cooldown = PasteCooldown(window: 1)
        XCTAssertTrue(cooldown.claim(.localPaste, now: 100))
        XCTAssertTrue(cooldown.claim(.broadcast, now: 100.2))
    }

    func testEachActionKeepsItsOwnWindow() {
        let cooldown = PasteCooldown(window: 1)
        XCTAssertTrue(cooldown.claim(.localPaste, now: 100))
        XCTAssertTrue(cooldown.claim(.broadcast, now: 100.2))
        XCTAssertFalse(cooldown.claim(.localPaste, now: 100.3))
        XCTAssertFalse(cooldown.claim(.broadcast, now: 100.4))
    }

    // A rejected claim must not slide the window forward, or a repeating key
    // could keep the next deliberate paste out indefinitely.
    func testRejectedClaimsDoNotExtendTheWindow() {
        let cooldown = PasteCooldown(window: 1)
        XCTAssertTrue(cooldown.claim(.localPaste, now: 100))
        XCTAssertFalse(cooldown.claim(.localPaste, now: 100.9))
        XCTAssertTrue(cooldown.claim(.localPaste, now: 101.5))
    }
}
