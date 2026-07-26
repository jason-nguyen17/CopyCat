import Carbon.HIToolbox
import XCTest
@testable import CopyCat

/// Stands in for the frontmost app, the clipboard, the Accessibility grant and
/// the event-posting machinery, so the arming gate can be driven through every
/// state without touching the running session.
@MainActor
private final class EnvironmentStub {
    var frontmost: String?
    var clipboardHasImage = true
    var clipboardChangeCount = 0
    var accessibilityTrusted = true

    private(set) var postedChords: [HotkeyBinding] = []
    /// Actions that reached the paste itself, recorded instead of dispatched:
    /// a real paste would read the running session's clipboard and, for
    /// broadcast, reach for the network.
    private(set) var pastedActions: [HotkeyAction] = []
    /// Runs inside the post, so a test can inspect what is still registered at
    /// the exact moment the keystroke goes back out.
    var onPost: ((HotkeyBinding) -> Void)?

    /// Per-instance so nothing here depends on how fast the suite runs.
    let cooldown = PasteCooldown(window: 1)

    var environment: HotkeyEnvironment {
        HotkeyEnvironment(
            frontmostBundleID: { self.frontmost },
            clipboardHasImage: { self.clipboardHasImage },
            clipboardChangeCount: { self.clipboardChangeCount },
            accessibilityTrusted: { self.accessibilityTrusted },
            postChord: { binding in
                self.postedChords.append(binding)
                self.onPost?(binding)
            },
            pasteCooldown: cooldown,
            performPaste: { self.pastedActions.append($0) })
    }
}

@MainActor
final class PasteHandlerTests: XCTestCase {
    /// `terminal` is a bundle ID from the shipped target list, read out of
    /// Settings rather than written into it: `registerDefaults` populates only
    /// the volatile registration domain, so these tests never touch stored
    /// preferences.
    private func makeHandler() throws -> (PasteHandler, HotkeyManager, FakeRegistrar, EnvironmentStub, String) {
        Settings.registerDefaults()
        let terminal = try XCTUnwrap(Settings.targetBundleIDs.sorted().first)
        let registrar = FakeRegistrar()
        let stub = EnvironmentStub()
        let hotkeys = HotkeyManager(registrar: registrar)
        let handler = PasteHandler(hotkeys: hotkeys, environment: stub.environment)
        return (handler, hotkeys, registrar, stub, terminal)
    }

    // MARK: - Gate

    func testArmsTheLocalChordWhenEveryGateInputLinesUp() throws {
        let (handler, _, registrar, stub, terminal) = try makeHandler()
        stub.frontmost = terminal

        handler.reconcile(reason: "test")

        XCTAssertEqual(registrar.live, [.localPaste])
        XCTAssertEqual(handler.hotkeyStatus, .on)
    }

    func testHoldsNothingWhileAnotherAppIsFrontmost() throws {
        let (handler, _, registrar, stub, _) = try makeHandler()
        stub.frontmost = "com.example.browser"

        handler.reconcile(reason: "test")

        XCTAssertTrue(registrar.live.isEmpty)
    }

    func testHoldsNothingWhenTheClipboardHasNoImage() throws {
        let (handler, _, registrar, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        stub.clipboardHasImage = false

        handler.reconcile(reason: "test")

        XCTAssertTrue(registrar.live.isEmpty)
    }

    // Without the grant a chord would swallow ⌘V and type nothing, so the gate
    // stays shut — and the header has to say why, distinctly from "off".
    func testHoldsNothingAndSaysSoWithoutAccessibility() throws {
        let (handler, _, registrar, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        stub.accessibilityTrusted = false

        handler.reconcile(reason: "test")

        XCTAssertTrue(registrar.live.isEmpty)
        XCTAssertEqual(handler.hotkeyStatus, .needsAccessibility)
    }

    // The grant is re-read on every reconcile precisely so that approving it
    // in System Settings takes effect without relaunching CopyCat.
    func testGrantLandingArmsTheChordWithoutRestart() throws {
        let (handler, _, registrar, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        stub.accessibilityTrusted = false
        handler.reconcile(reason: "test")
        XCTAssertTrue(registrar.live.isEmpty)

        stub.accessibilityTrusted = true
        handler.reconcile(reason: "test")

        XCTAssertEqual(registrar.live, [.localPaste])
        XCTAssertEqual(handler.hotkeyStatus, .on)
    }

    // A chord another app already owns must not read as "off" — that is the
    // state the user gets by flipping the toggle themselves, and it sends them
    // looking in the wrong place.
    func testStatusNamesTheChordWhenRegistrationFails() throws {
        let (handler, _, registrar, stub, terminal) = try makeHandler()
        registrar.failures[.localPaste] = OSStatus(-9878)
        stub.frontmost = terminal

        handler.reconcile(reason: "test")

        XCTAssertEqual(
            handler.hotkeyStatus,
            .unavailable(chord: HotkeyBinding.localPaste.displayString))
        XCTAssertNotEqual(handler.hotkeyStatus, .off)
    }

    // Precedence: a missing grant explains every chord at once, so it outranks
    // an individual chord that couldn't be claimed.
    func testMissingAccessibilityOutranksARegistrationFailure() throws {
        let (handler, _, registrar, stub, terminal) = try makeHandler()
        registrar.failures[.localPaste] = OSStatus(-9878)
        stub.frontmost = terminal
        handler.reconcile(reason: "test")

        stub.accessibilityTrusted = false

        XCTAssertEqual(handler.hotkeyStatus, .needsAccessibility)
    }

    // MARK: - Poll lifecycle

    func testClipboardPollRunsOnlyWhileATargetIsFrontmost() throws {
        let (handler, _, _, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        handler.reconcile(reason: "test")
        XCTAssertTrue(handler.isPollingClipboard)

        stub.frontmost = "com.example.browser"
        handler.reconcile(reason: "test")
        XCTAssertFalse(handler.isPollingClipboard)
    }

    func testClipboardPollSurvivesAReconcileWithinTheSameApp() throws {
        let (handler, _, _, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        handler.reconcile(reason: "test")
        handler.reconcile(reason: "test")

        XCTAssertTrue(handler.isPollingClipboard)
    }

    // MARK: - Passthrough on bail

    // The chord is armed from state sampled up to a poll interval earlier, so
    // it can fire after the gate closed. The keystroke is already gone by
    // then: bailing without handing it back destroys the user's ⌘V.
    func testHandsTheKeystrokeBackWhenFrontmostChangedFirst() throws {
        let (handler, _, registrar, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        handler.reconcile(reason: "test")
        stub.frontmost = "com.example.browser"
        registrar.reset()

        handler.fire(.localPaste)

        XCTAssertEqual(stub.postedChords, [HotkeyBinding.localPaste])
        XCTAssertEqual(registrar.calls, [.unregister(.localPaste)])
    }

    func testHandsTheKeystrokeBackWhenTheImageVanishedFirst() throws {
        let (handler, _, registrar, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        handler.reconcile(reason: "test")
        stub.clipboardHasImage = false
        registrar.reset()

        handler.fire(.localPaste)

        XCTAssertEqual(stub.postedChords, [HotkeyBinding.localPaste])
    }

    // The loop guard in one assertion: the re-posted event carries the same
    // modifiers the hot key matches on, so the chord must already be gone by
    // the time it goes out.
    func testChordIsReleasedBeforeTheKeystrokeIsPosted() throws {
        let (handler, _, registrar, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        handler.reconcile(reason: "test")
        stub.frontmost = "com.example.browser"

        var liveAtPost: Set<HotkeyAction>?
        stub.onPost = { _ in liveAtPost = registrar.live }

        handler.fire(.localPaste)

        XCTAssertEqual(liveAtPost, [], "posting while the chord is still claimed would re-enter the handler")
    }

    func testPassthroughIsAbandonedWhenTheChordCannotBeReleased() throws {
        let (handler, _, registrar, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        handler.reconcile(reason: "test")
        registrar.unregisterFailures[.localPaste] = OSStatus(-9874)
        stub.frontmost = "com.example.browser"

        handler.fire(.localPaste)

        XCTAssertTrue(stub.postedChords.isEmpty)
    }

    func testNothingIsPostedWhenNoChordWasHeld() throws {
        let (handler, _, registrar, stub, _) = try makeHandler()
        stub.frontmost = "com.example.browser"

        handler.fire(.localPaste)

        XCTAssertTrue(stub.postedChords.isEmpty)
        XCTAssertTrue(registrar.calls.isEmpty)
    }

    // Nothing to hand back for the fired action, but the gate is still closed
    // for the chords that *are* armed.
    func testSiblingsAreStillReleasedWhenTheFiredChordIsNotHeld() throws {
        let (handler, hotkeys, registrar, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        hotkeys.apply([.broadcast: BroadcastHotkey.cmdOptV.binding], reason: "test")
        stub.frontmost = "com.example.browser"
        registrar.reset()

        handler.fire(.localPaste)

        XCTAssertTrue(registrar.live.isEmpty)
        XCTAssertTrue(stub.postedChords.isEmpty, "a chord that was never held can't be handed back")
    }

    // The gate is one decision for all chords: when it goes stale, a sibling
    // left armed keeps swallowing keystrokes for a window that already closed.
    func testPassthroughReleasesEveryArmedChordNotJustTheFiredOne() throws {
        let (handler, hotkeys, registrar, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        // Armed directly: reaching this through reconcile would need the
        // broadcast toggle in stored preferences, and the rule under test
        // doesn't depend on how the chords came to be armed.
        hotkeys.apply([
            .localPaste: .localPaste,
            .broadcast: BroadcastHotkey.cmdOptV.binding,
        ], reason: "test")
        stub.frontmost = "com.example.browser"
        registrar.reset()

        handler.fire(.localPaste)

        XCTAssertTrue(registrar.live.isEmpty, "the gate is closed for every chord, not just the fired one")
        XCTAssertTrue(hotkeys.activeBindings.isEmpty)
        XCTAssertEqual(
            stub.postedChords, [HotkeyBinding.localPaste],
            "only the swallowed chord is handed back — the sibling was never pressed")
    }

    // MARK: - Paste dispatch

    func testFiringInsideTheGatePastes() throws {
        let (handler, _, _, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        handler.reconcile(reason: "test")

        handler.fire(.localPaste)

        XCTAssertEqual(stub.pastedActions, [.localPaste])
        XCTAssertTrue(stub.postedChords.isEmpty, "acting on the chord must not also hand the keystroke back")
    }

    // One keystroke can reach both the chord and the Secure Input sensor, so a
    // repeat of the same action inside the window is dropped.
    func testRepeatOfTheSameActionIsSuppressed() throws {
        let (handler, _, _, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        handler.reconcile(reason: "test")

        handler.fire(.localPaste)
        handler.fire(.localPaste)

        XCTAssertEqual(stub.pastedActions, [.localPaste])
    }

    // Different chords are different presses; suppressing the second would
    // silently drop a paste the user deliberately asked for.
    func testADifferentActionIsNotSuppressedByTheWindow() throws {
        let (handler, _, _, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        handler.reconcile(reason: "test")

        handler.fire(.localPaste)
        handler.fire(.broadcast)

        XCTAssertEqual(stub.pastedActions, [.localPaste, .broadcast])
    }

    // Re-arming is left to the reconcile path, so a released chord comes back
    // as soon as the conditions that justify it do.
    func testReleasedChordIsReArmedOnceTheGateReopens() throws {
        let (handler, _, registrar, stub, terminal) = try makeHandler()
        stub.frontmost = terminal
        handler.reconcile(reason: "test")
        stub.frontmost = "com.example.browser"
        handler.fire(.localPaste)
        XCTAssertTrue(registrar.live.isEmpty)

        stub.frontmost = terminal
        handler.reconcile(reason: "test")

        XCTAssertEqual(registrar.live, [.localPaste])
    }
}
