# Changelog

Project journal in newest-first order. Each entry captures what shipped, why, and any operational notes worth keeping. The "What's new" entries are the user-facing release-notes voice (Vince Vaughn); earlier entries are internal design-pass notes.

## What's new

OK here's the deal. v0.2.0 is the big one. **AV Pain Reliever is now
a virtual camera.** That's right — the same app that's been quietly
swapping your audio defaults all this time can now also be the camera
that Zoom, Slack, Teams, and any other video app picks up. One
camera in their picker. One name. **AV Pain Reliever.** It streams
whatever real camera the active profile names — your built-in webcam
at the laptop, the HDMI capture at the home office, your iPhone via
Continuity at the conference room — whatever you've configured. The
profile changes, the picture follows. Money.

Here's what this fixes: Zoom, Slack, and Teams keep their *own*
camera selection that ignores the system default. So back in v0.1.x
when you docked at a new location, your microphone and speakers
would change, but Zoom would just sit there showing your laptop
webcam like nothing happened. That's amateur hour. With v0.2.0, you
pick "AV Pain Reliever" in Zoom once and you're done. Forever.

It's **off by default** — installing a virtual camera is a real thing
and we're not turning it on without your permission, that's not how
we do business. Open **Settings → Camera** and flip the toggle.
macOS will ask you to approve the extension once (System Settings →
Login Items & Extensions → Camera Extensions). After that, you're in.

A few technical things, briefly, because if you're reading this far
you probably care:

- **Hold-last-frame** during the swap. When you change profiles, the
  new camera takes a beat to warm up — about half a second. Instead
  of flashing black at your Zoom call, the virtual camera holds the
  last frame from the old camera until the new one's delivering
  frames. You see a soft pause; nobody on the call sees a glitch.
- **Format conversion** for any camera. Built-in webcams ship BGRA,
  USB capture cards ship YUV at 1080p, every device has its quirks.
  We accept whatever the camera natively delivers and convert to
  1280×720 BGRA on the fly, hardware-accelerated where possible.
  Means your weird HDMI capture card just works.
- **Profile-driven everywhere.** The same Add Profile wizard that
  picks your audio defaults now also picks the camera the virtual
  camera streams. No new config to learn — it's the same `camera =`
  field you've already been using. v0.1.x configs upgrade clean.

One known thing: if you toggle the virtual camera off and then back
on inside the same launch, macOS holds the extension in a stale
state and the feed goes black. The Settings UI catches this and
gives you a **Restart AV Pain Reliever** button that handles it. One
click, fresh process, you're back. Edge case — most folks turn it
on once and leave it. Not a deal-breaker.

That's the update. Virtual camera, profile-driven, hold-last-frame,
universal format support. v0.1.x will keep getting patch releases
in parallel for anyone who doesn't need any of this. **Money.**
```

### Camera extension's frame pump stops burning a core while nobody's watching (2026-08-30)

Fixes #115. Duty-cycle tracing on `debug/idle-cpu-tracing` turned up the cause of a long-standing background CPU cost: Zoom holds the virtual camera's *source* stream open for its entire process lifetime, not just during calls (client-identity tracing showed `us.zoom.xos` connecting at launch and never disconnecting). A held source stream keeps the host's `AVCaptureSession` running and keeps the extension's consume timer alive, so "Zoom is running" meant the full capture pipeline was running around the clock. On one machine that came to 7h40m of extension CPU and 551M context switches over 18.8 days — roughly 1.7% of a core and ~340 wakeups/sec, continuously, mostly outside any call.

Two changes to `CameraExtensionDeviceSource`'s pump:

- The timer no longer passes `.strict`, and leeway goes from 1 ms to 8 ms. `.strict` explicitly opts *out* of timer coalescing, which is exactly backwards here: the pump deliberately oversamples at 3× the 30 fps frame rate so that no individual wakeup has to be punctual. With slack, the kernel can fold our wakeups into ones it was already making.
- Idle downshift. When the source stream has zero clients **and** the sink has returned empty on ~3 s of consecutive consumes, the timer reschedules to 2 Hz (250 ms leeway). It returns to the full 90 Hz schedule the moment a consume yields a frame, or on the source's 0→1 client edge — `CameraExtensionStreamSource.startStream` already edge-triggers there for the host's consumer-active notification, so the pump restore hangs off the same branch via a new `device?.sourceClientBecameActive()`.

The downshift gate is deliberately conservative in one direction: it never fires while `streamingCounter > 0`, even if the sink is bone dry. A watcher's experience is unchanged, hold-last-frame re-emits included — those ride on these same ticks and cover the ~500 ms input-swap window in `CameraCaptureSession`, so anything that slowed them down would put a visible freeze in a live call. The 2 Hz idle tick (rather than something slower) is also a hedge: if the client edge ever fails to fire, the pump still notices a live sink within half a second on its own.

Threading is unchanged in shape. The timer, its rescheduling, and the empty-run counter all live on `consumeQueue`; `consumeSampleBuffer`'s completion may run elsewhere, so it reads `pumpIsIdle` as a cheap "do I need to do anything?" hint and hops to `consumeQueue` for the actual reschedule. No new locks.

Still open (deliberately out of scope): the host keeps feeding the sink at full rate for a client that holds the stream open but renders nothing. Fixing the extension side caps the damage; not producing the frames at all would be the larger win.

### Survive a slow extension spawn in the visibility check (2026-08-30)

Fixes #114. The post-activation visibility poll budgeted 8 s (first attempt at 1.5 s, then 1 s intervals) for `AVCaptureDevice.DiscoverySession` in the host process to see the extension's CMIO device. Twice on 2026-08-28, after an in-place extension replace, macOS took **11 s** to spawn the replaced extension process. The poll expired first, escalated to `.requiresRelaunch`, and the #110/#111 properties query then found the pre-replace copy still queued for uninstall-on-reboot and upgraded to `.requiresReboot` — a red "Mac restart required" for a machine that was about to be fine, and the camera did become visible roughly two minutes later. Worse than the wrong advice: the escalation tears down the consumer watch, so any AVCapture client that connected afterwards got a black feed until the user restarted the app a second time.

Two-part fix, so the recovery completes in one pass. First, the poll budget goes 8 s → 30 s at the same 1 s cadence; the poll still exits the instant the device appears, so the longer budget only costs time in the genuinely-broken case. Second, a timeout escalation now arms a slow re-check (every 5 s for up to 2 minutes) that keeps asking DiscoverySession while the state sits in `.requiresRelaunch` / `.requiresReboot`. If the camera turns up, the activator walks the same success path a timely poll would have: back to `.on`, consumer watch re-armed (the escalation had torn it down), `onVisibilityConfirmed` fired so AppDelegate re-applies the active profile. The stale restart advice disappears on its own.

Two boundaries the self-heal deliberately does not cross. It's armed only from the visibility-timeout branch, never from the `deactivatedThisSession` path in `enable()` — a same-process toggle off-then-on genuinely needs a fresh host process no matter what CMIO later publishes, and healing that back to `.on` would hand callers a device that can't deliver frames. And it leaves the #111 request-identity guards alone: the re-check moves state through `state`, not through the shared `OSSystemExtensionRequestDelegate`, and the existing `guard self.state == .requiresRelaunch` in `foundProperties` means an in-flight properties query that lands after a heal can no longer stomp `.on` with `.requiresReboot`. The timer also stands down on `disable()`, on a fresh activation's `scheduleHostVisibilityCheck` (Sparkle replace can re-fire `.completed`), and on any state change it notices at tick time.

### Capture-card virtual camera showed black video (2026-08-30)

Fixes #113. With a profile routing the virtual camera to a USB capture card, Zoom showed a black feed even though the badge was green and the pipeline reported healthy — `session.isRunning=true`, sink writer connected, no runtime error, and zero frames ever delivered.

Two layers of root cause, both diagnosed live on 2026-08-28. First, `CameraCaptureSession` forced `session.sessionPreset = .hd1280x720` onto the capture device; the card only offers the format of its live HDMI signal, so the unsatisfiable preset stalled it silently. Second, dropping the preset wasn't sufficient on its own: the card also ignores AVFoundation's default format pick and only starts streaming for a client that pins a concrete `activeFormat` + frame duration. The smoking gun was a solo session sitting frameless for minutes, then receiving its first frame 344 ms after Zoom (which pins formats) opened the same device, and continuing to receive frames after Zoom released it.

Fix: drop the forced preset, and pin `activeFormat` (highest resolution, ties broken by max frame rate) plus frame duration on the device at input-install time. `CMIOSinkWriter` already normalizes every frame to 1280×720 BGRA regardless of the source stream's native format, so downstream consumers see no change.

### Stale-extension recovery copy now leads with the toggle cycle, not a Mac reboot (2026-08-28)

Field evidence overturned the 2026-08-05 assumption that "only a Mac reboot fixes" the `[terminated waiting to uninstall on reboot]` state. Hit the exact `.requiresReboot` condition again (dev build replacing the installed extension, `isUninstalling` copy detected, camera absent from `system_profiler SPCameraDataType`), and a Settings toggle off → on cycle followed by the `.requiresRelaunch` app restart brought the camera back with no reboot. Mechanism: the fresh deactivate + activate re-registers the new copy with sysextd, and the app restart gives the host a clean CMIO context, the same path that works on every cold launch. `docs/virtual-camera.md` had already recorded "reboot or a Settings toggle off/on cycle" from M3/M4 dev iteration; the #111 copy just never offered the second option.

`.requiresReboot` now renders "Re-enable required" and walks the user through toggle-off/on → restart-the-app-if-prompted, keeping the Mac restart as the explicit fallback if the camera still doesn't appear. No state-machine changes; the relaunch button still isn't offered in this state (a bare relaunch without the toggle cycle genuinely can't help).

### Distinguish "restart the app" from "restart your Mac" in the virtual-camera status (2026-08-05)

Fixes #110. The `.requiresRelaunch` escalation conflated two failure modes: a stale AVFoundation discovery cache (an app relaunch fixes it) and a previous extension version stuck in `[terminated waiting to uninstall on reboot]` after an in-place app upgrade (only a Mac reboot fixes it). In the second mode, Settings prescribed the app-restart button anyway, sending the user through an infinite green-dot → red-dot loop: activation succeeds, the host-visibility check fails ~9 s later, repeat.

Now, after a visibility-check failure escalates to `.requiresRelaunch`, the activator submits an `OSSystemExtensionRequest.propertiesRequest` and upgrades to a new `.requiresReboot` state when any returned copy reports `isUninstalling`. That state renders "Mac restart required" with copy explaining the pending-removal swap, and drops the relaunch button (it can't help). Query fails or comes back clean → stays `.requiresRelaunch`, i.e. today's behavior is the fallback.

Wiring subtlety worth remembering: the properties request shares the activator's `OSSystemExtensionRequestDelegate`, and its terminal `didFinishWithResult(.completed)` would have been indistinguishable from an activation completing — flipping the state back to `.on` and restarting the failing loop. The delegate callbacks guard on request identity (`request === pendingPropertiesRequest`), and the reference is cleared in the terminal callbacks rather than `foundProperties` because both fire for the same request.

Observed live on macOS 26 after installing a dev build over v0.2.0.19: the release-build extension sat in the uninstall queue, CMIO never published the dev copy to the host, and every relaunch looped. `systemextensionsctl list` is the diagnostic; a reboot is the cure.

### Transient USB devices no longer trigger the new-location prompt (2026-08-05)

Plugging in a lone flash drive (or card reader, or a phone on a charge cable) used to fire the full "New location detected" flow — toast, menu badge, the works — because the unknown-location signal counted *any* USB device as evidence of being somewhere new. Now `handleUnknownLocation` classifies each attached device by its USB class data and subtracts the transient ones before deciding; if nothing location-worthy remains, it stays quiet.

Design notes:

- **Denylist, not allowlist.** We filter classes we positively recognize as transient (Mass Storage 0x08, Still Image/PTP 0x06) rather than requiring an AV device to be present. A dock that routes audio over HDMI/DisplayPort exposes zero USB AV devices — an allowlist would have silently stopped prompting at exactly the setups the app exists for. Unclassifiable devices fail open to prompting.
- **Vendor-specific (0xFF) is discounted, not denylisted.** An iPhone exposes PTP *plus* a vendor-specific usbmux interface; a strict subset rule would count it as signal. A purely-vendor-specific device still fails open.
- **Class data rides `NamedUSBDevice`** (new `usbClasses` field, populated from `bDeviceClass` + child `IOUSBHostInterface` `bInterfaceClass` entries), keeping `USBDevice` — the Hashable fingerprint identity — untouched. Engine, resolver, and matching are unchanged; only the prompt layer filters.
- **Ignore keys are now computed on the filtered set**, so "dock" and "dock + USB stick left in the port" dismiss as one location. Entries persisted before this change are still honored via a legacy full-set key lookup — no migration.

IOKit finding worth keeping: `IOUSBHostInterface` entries are immediate children of `IOUSBHostDevice` in the service plane, so a one-level `IORegistryEntryGetChildIterator` walk suffices; composite devices report `bDeviceClass` 0x00/0xEF, which carry no signal and are dropped.

### Profiles tab adopts the grouped-Form chrome (2026-05-18)

The Profiles tab in Settings was the last surface still using `List` with `.listStyle(.inset)` — General, Camera, and Stats all render `Form(.grouped)` with rounded-card section chrome and prominent bold-icon + bold-text Section headers. Switched Profiles over to match. Apple's own System Settings renders list-style content (Login Items, Wi-Fi, Extensions) inside the same grouped-Form chrome, so the tab now reads as part of the same settings surface instead of drifting into List's sidebar aesthetic.

Mechanical: `List { Section { ForEach … } }` → `Form { Section { ForEach … } header: { Label(…) } }.groupedFormChrome()`. The "Ignored Locations" header dropped its manual `HStack(Image + Text)` workaround (we'd built that because List headers default to a smaller, regular-weight style) — Form gives both sections the prominent rendering for free. Added a sibling "Profiles" header (`Label("Profiles", systemImage: "list.bullet.rectangle")`) for parity. Empty state, delete-confirmation alert, and `.safeAreaInset(.bottom)` `+` button bar untouched. Net diff: −29 / +18 lines.

`GroupedFormChrome`'s doc comment claimed the Profiles tab was "intentionally bespoke" and didn't use the modifier. Stale — fixed.

### Slop-review follow-up on the dismiss-a-location feature (2026-05-17)

Six mechanical fixes applied after `/code-quality:slop` on the dismiss-a-location diff:

1. Dropped the dead pluralization branch in `IgnoredLocationRow.headline` (the `count == 1 ? "" : "s"` ternary was unreachable because the early-return handles count == 1).
2. Replaced `Image(systemName: "cable.connector")` in `IgnoredLocationRow` with `Theme.Symbol.usbSection`. `Theme.swift` retired `cable.connector` for the stick-figure-at-small-sizes reason; the sibling `ProfileRow` was already on the replacement glyph. The row's own doc comment says "mirrors `ProfileRow`'s layout" — now it actually does.
3. Bumped the `ignoredLocations` JSON encode-failure log line from `.debug` to `.error`. Silent data loss was logged at a level that's invisible in the support-log export.
4. Factored `NamedUSBDevice.formatDisplayName(vendorName:name:)` as a shared static so `IgnoredLocation.Device.displayName` defers to the same fallback ladder. Removes a near-copy that had drifted on the `(nil, nil)` branch (was rendering "USB 05ac:12a8", now matches the wizard's "(unnamed device)" fallback).
5. Extracted `AppDelegate.clearUnknownLocationState()`. The triple-clear pattern was open-coded in four sites with subtle drift — one site forgot `notifiedUnknownLocation`, another forgot `lastUnknownDevices`. One method now owns the reset; all four exit edges call it.
6. Moved name capture from click-time (in `ignoreCurrentUnknownLocation`) to signal-time (in `handleUnknownLocation`). New private `lastUnknownDevicesNamed: [NamedUSBDevice]` is populated alongside `lastUnknownDevices` via a transient `IOKitUSBWatcher`; the dismiss button now reads the stored snapshot. Eliminates the race window where unplugging between signal and click would persist hex instead of names.

All 273 tests still pass; no behavior change beyond the consistency fixes.

### Dismiss-a-location: "Not a Location" + per-fingerprint ignore list (2026-05-17)

Some unknown-location plug-ins aren't real places — a phone on the couch, a friend's USB stick, a random hub. The menu's "Set Up Location…" prompt was the only affordance for those, and there was no way to say "no, never ask about this combination again."

Added a "Not a Location" item next to "Set Up Location…" (only visible when `atUnknownLocation` is true). Clicking it captures the canonical fingerprint of the currently-attached USB set + the device names IOKit reports for them, persists that as an entry in `SettingsStore.ignoredLocations`, and clears the in-memory unknown-location state so the menu hides the affordance immediately. Subsequent plug-ins of the same combination short-circuit in `handleUnknownLocation` — no toast, no menu prompt.

Persistence model:

- New struct `IgnoredLocation` (codable, `key + devices + dismissedAt`) and a `LocationFingerprint.canonical(for:)` helper that produces a stable pipe-joined `vid:pid[/serial]` string regardless of `Set<USBDevice>` enumeration order. Serials participate in the key so two physically-distinct units of the same model don't collide.
- `SettingsStore` adds `ignoredLocations`, `isLocationIgnored(key:)`, `ignoreLocation(_:)`, `unignoreLocation(key:)`. Stored as JSON `Data` under the `ignoredLocations` UserDefaults key — the entries carry nested structs + a Date, so plist-of-dicts wasn't a clean fit. Empty list removes the key entirely, preserving the lazy-default-on-read pattern the other caches use.
- Un-ignore path: a new "Ignored Locations" `Section` at the bottom of Settings → Profiles renders each entry with its device names + relative dismiss time and an `arrow.uturn.backward` button. `AppDelegate.unignoreLocation(key:)` removes the entry and calls `engine?.evaluate()` so a currently-attached set that just got un-ignored re-prompts without unplug/replug.

Menu label also shortened from "Set Up This Location…" to "Set Up Location…". `MenuBarExtra(.menu)` sizes the underlying NSMenu on first render and doesn't widen when conditional items appear later — once the rest of the menu had been measured without the unknown-location row, the longer string ended up middle-truncated as "Set Up...ocation…". Dropping "This" keeps the label within the existing menu width.

Tests: 6 new cases in `SettingsStoreTests` covering ignore round-trip, replacement on duplicate keys, un-ignore clears the UserDefaults key, fresh-store doesn't seed, and the canonical-fingerprint helper's order-independence + serial sensitivity.

### Clear `atUnknownLocation` when the user unplugs back to the laptop (2026-05-17)

`atUnknownLocation` is the flag behind the menu's "Set Up This Location…" affordance. The engine only fires the *entering* edge (`onUnknownLocation` when the fallback profile resolves with USB devices attached); the flag was cleared in `handleProfileApplied` only when a profile with a **non-empty fingerprint** resolved. The Laptop profile is the empty-fingerprint fallback, so the unplug-everything path (fallback + no devices) skipped the clear and the menu kept showing "Set Up This Location…" indefinitely.

Repro: on Laptop with nothing attached, plug in any device that doesn't match a profile (a phone, a random USB stick), then unplug it. The "New location detected" toast fires correctly on plug-in, but "Set Up This Location…" stuck around after unplug.

Fix in `engine.onDevicesEvaluated`: when the attached set is empty, clear `atUnknownLocation`, `lastUnknownDevices`, and re-arm `notifiedUnknownLocation`. `onDevicesEvaluated` fires before `onUnknownLocation` in the engine's evaluation pass, and `onUnknownLocation` requires a non-empty attached set to fire, so there's no ordering hazard — the clear sticks. The non-empty-fingerprint clear branch in `handleProfileApplied` still handles the other transition (user moves directly from unknown location to a known one without going through undocked).

### Stable release auto-clears the Dev/Experimental README rows (2026-05-13)

Follow-on to #100. The README's "Release channels" block had three rows; Dev and Experimental were auto-filled on every dev/experimental release publish, but **when a stable release shipped, the obsolete prerelease rows kept pointing at their last tag.** Looked confusing: "Dev: v0.2.0.17-dev.5" sitting under "Stable: latest" once the stable is what `latest` resolves to anyway.

`scripts/update-readme-channel.awk` gains an empty-tag semantic: pass `tag=""` and the addressed row gets reset to `_no current release_` instead of rewritten with a new link.

`appcast-publish.yml` grows a three-way `case` on `$VERSION_TAG`:

- `*-dev*` → rewrite the Dev row to the new tag (unchanged).
- `*-experimental*` → rewrite the Experimental row (unchanged).
- bare stable tag → for each of Dev and Experimental, if the row's current tag is a prerelease of the **same** stable version (`strip-prerelease(current) == strip-prerelease(new_stable)`), reset it.

The strip-and-compare rule beats version-comparison via `sort -V` because that's not a real semver comparator — `sort -V` places `v0.2.0.17` BEFORE `v0.2.0.17-dev.5`, opposite of semver. Strip-and-compare captures the actual intent: "this row is showing a prerelease of the version I'm now shipping as stable, clear it." Prerelease tags pointing at a future major/minor (e.g. experimental `v0.3.0-experimental.1` while we ship stable `v0.2.0.17`) are left alone.

Tests: 3 new cases in `scripts/test-update-readme-channel.sh` (empty-tag-resets-dev, empty-tag-resets-experimental, reset-is-idempotent-on-already-reset). 8 total in the harness.

### README "Release channels" block + correct `releases/latest` redirect (2026-05-11)

The README's install step linked GitHub's `/releases/latest` for stable downloads, but every recent release was published without the `prerelease` flag set, so `/releases/latest` was returning whatever tag was newest (dev tags included). A user clicking "latest" today gets `v0.2.0.17-dev.4` instead of the most recent stable.

Fix has two pieces. First, `release.yml` now sets `--prerelease` on `*-dev*` / `*-experimental*` tags and `--prerelease=false` on bare tags (same tag-pattern logic the appcast already uses to pick a Sparkle channel). `/releases/latest` now correctly returns the latest stable. Second, the README gets a new "Release channels" block:

```html
<!-- BEGIN CURRENT RELEASES -->
- **Stable** — [latest](https://github.com/superic/av-pain-reliever/releases/latest)
- **Dev** — _no current release_
- **Experimental** — _no current release_
<!-- END CURRENT RELEASES -->
```

The Dev and Experimental rows get auto-rewritten by `appcast-publish.yml` on every release-published event: same workflow that already commits `appcast.xml` back to main now also runs `scripts/update-readme-channel.awk` against the README and folds the change into the same commit. Stable stays free via the `/releases/latest` redirect. No manual README maintenance on tag.

`scripts/update-readme-channel.awk` is a 50-line awk script with start-of-line anchors on the BEGIN/END markers so it can't accidentally eat a lookalike bullet outside the block (same defensive style as `upsert-appcast-item.awk`). Five test cases in `scripts/test-update-readme-channel.sh` cover both channels, the no-op empty-channel case, lines outside the markers, and idempotency. Wired into `test.yml`.

### Settings, About, Welcome, and Add Profile windows now center on every open (2026-05-12)

The four utility windows sometimes opened off-center on the wrong monitor, sometimes briefly at their last-known position before snapping to center. Root cause turned out to be a sequence of races between the helper's centering, AppKit's `frameAutosaveName` restoration, and SwiftUI's `Settings`-scene state restoration. Diagnostic logging across four iterations was the only way to see it clearly.

Final shape (in `WindowChrome.swift`):

- A custom `NSView` subclass (`WindowCenteringView`) attaches `NSWindow.willCloseNotification` and `NSWindow.didBecomeKeyNotification` observers in `viewDidMoveToWindow`.
- `didBecomeKeyNotification` is the **single source of truth** for centering. On every become-key with a cleared `hasCentered` latch, the window re-centers on the cursor's screen. `willCloseNotification` clears the latch so the next open re-centers.
- Centering is intentionally NOT done in `viewDidMoveToWindow`. The diagnostic logs showed SwiftUI's `Settings` scene restoring its last-session frame between `viewDidMoveToWindow` and `didBecomeKey` (~30 ms gap), which would clobber any pre-show centering. `didBecomeKey` fires after that restoration, so it's the only reliable hook.
- `frameAutosaveName` is cleared if SwiftUI assigns one, as belt-and-suspenders against AppKit's restoration on top of SwiftUI's.
- Centering uses the screen with the mouse cursor, not `NSWindow.center()`'s "screen the saved frame is on" default. For a menu-bar app, the cursor's monitor is the one the user is looking at; the saved-frame's monitor may have been from a different session. Y-axis placement matches AppKit's `center()` heuristic (about a third from the top) so the windows still feel like macOS-native utility windows.
- Focus-return (user clicks another app then back to the window) does NOT fire `willClose`, so the latch stays set and the window keeps its user-moved position.

The `WindowCenteringView` logs decision points under a new `window-center` category so future regressions of this class are diagnosable in one `log stream` run. Diagnostic only: `.debug` is off the persistence path, so Save Logs for Support exports are unchanged.

### Don't register `swiftpm-testing-helper` as a login item from tests (2026-05-12)

`SettingsStoreTests.launchAtLoginPersists` toggled `store.launchAtLogin = true`, which fired the `@Published` `didSet` and called `LaunchAtLogin.apply(enabled: true)`. Under `swift test`, that resolves to `SMAppService.mainApp` from inside the `swiftpm-testing-helper` process, registering the **test runner** as a login item every time the suite ran. macOS Sequoia surfaces this as a "Login Item Added" banner ("`swiftpm-testing-helper` will open automatically when you log in"), which had silently accumulated across many test runs over the past week.

Fix is a `LoginItemApplier` typealias and an injected applier closure on `SettingsStore.init`. Production passes the real `LaunchAtLogin.apply(enabled:)`; tests pass `{ _ in }`. The one test that mutates `launchAtLogin` now injects the no-op explicitly so `SMAppService` never gets called from the test helper. Existing tests that construct `SettingsStore` without mutating `launchAtLogin` are safe because Swift's `didSet` doesn't fire during initialization, so they continue using the default production applier without ever invoking it.

Cleanup for users on the affected machine: open **System Settings → Login Items & Extensions** and remove `swiftpm-testing-helper` from **Open at Login**. After that, the bug is gone for good.

### Trace `.debug` lines for `ProfileConfigWatcher` (2026-05-11)

The watcher logged only on error paths. Matched the `IOKitUSBWatcher` convention from the 2026-05-09 verbose-logging release: six new `.debug` calls covering start (with bound fd numbers), stop, dir-source events, file-source events with mask, inode-staleness rebinds, and debounce arming. All under category `config-watcher`. Diagnostic only: `.debug` is off the persistence path, so this doesn't change Save Logs for Support exports. Stream via `log stream --predicate 'subsystem == "com.ericwillis.avpainreliever" AND category == "config-watcher"' --level debug --style compact`.

### Quarantine corrupt profiles.toml in place instead of silently overwriting (2026-05-10)

A latent bug in `ProfileBootstrapper.loadOrBootstrap` came up while we were thinking about resilience: if `profiles.toml` failed to parse (syntax error, schema violation), the bootstrapper logged a warning and then unconditionally called `writeStarterConfig`, which atomically replaced the user's file with the 1-profile starter. Every custom profile, fingerprint, audio + camera selection: gone, silently. Triggered on every `bootEngine` call (launch, wizard save), and trivially reachable now that the auto-reload watcher fires on any out-of-band edit.

Fix is a `LoadOutcome` enum that splits the recovery path from the first-launch path:

```swift
public enum LoadOutcome {
    case loaded([Profile])
    case bootstrapped([Profile])
    case quarantinedAndReset([Profile], quarantinedAs: URL)
    case unrecoverable
}
```

On parse failure, the bootstrapper renames the corrupt file in place to a timestamped sibling: `profiles.corrupted-{YYYY-MM-DD-HHMMSS-mmm}.toml`. The broken copy stays right next to the active config in Application Support so the user finds both when they navigate there. Considered the user's Trash (via `FileManager.trashItem`) and rejected it as too aggressive: Trash gets auto-emptied on some users' machines, "moved to Trash" sounds like deletion in user-facing copy, and the file ends up mixed with unrelated deleted items. A sibling rename keeps the data right where it belongs, indefinitely.

A `QuarantineOp` closure seam keeps tests deterministic (they pass their own renamer instead of touching the real user filesystem). If the rename itself fails (read-only parent, etc.) the bootstrapper returns `.unrecoverable` and the original file is left untouched.

AppDelegate switches on the outcome after `bootEngine` and posts a UNUserNotification on the `.quarantinedAndReset` or `.unrecoverable` branches. The `notificationsEnabled` toggle does NOT gate this notification (that toggle is for friendly per-switch toasts; corruption is operational and the user needs to know regardless). The corrupt-config toast carries a **Show in Finder** action button that reveals the renamed file with one click. The body also names the renamed file inline so a user who dismisses the toast still has a filename to grep. To support per-action button labels, `Notifier` grew a `NotificationAction` enum so callers pick from pre-registered category labels (currently `openWizard` and `showInFinder`), since `UNUserNotificationCenter` requires categories up-front.

Order of operations in `bootEngine`: `configReloadGate.stamp(configMTime())` happens immediately after `loadOrBootstrap` returns, before any user-visible work. The quarantine + starter-write path produces several filesystem events the watcher will see; stamping early ensures its debounced callback finds the new mtime and treats it as an echo rather than firing a redundant second `bootEngine`.

Tests cover the bootstrap matrix with the closure seam plus one test that exercises the real default rename: valid load, missing-file bootstrap, malformed TOML quarantine, schema-violation quarantine, URL propagation through the outcome, `.unrecoverable` when the quarantine op throws, the `LoadOutcome.profiles` accessor, and the default `renameCorruptFileInPlace` filename shape. Each runs against a fresh scratch dir.

### M2 lessons (gotchas the architecture or first attempts hit)

1. **`AVCaptureVideoDataOutput.sessionPreset` ≠ output
   dimensions.** Setting `session.sessionPreset = .hd1280x720`
   does not force the output to 1280×720 — the FaceTime HD camera
   shipped 1920×1080 frames anyway. Fix: add
   `kCVPixelBufferWidthKey`/`kCVPixelBufferHeightKey` to
   `output.videoSettings`. AVFoundation does the downscale.
2. **Pre-built `CMFormatDescription` is fragile.** If the format
   description's dimensions don't match the actual pixel buffer,
   `CMSampleBufferCreateForImageBuffer` fails with -12743
   (`kCMSampleBufferError_InvalidMediaFormat`). Derive the
   format description from the pixel buffer (cached when
   dimensions stay constant). See
   `CMIOSinkWriter.formatDescription(for:)`.
3. **Don't trust stream array order.** OBS's plugin uses
   `streams[1]` to find its sink, but that's not portable across
   device implementations. Query
   `kCMIOStreamPropertyDirection` (0 = output/sink,
   1 = input/source) and pick by direction.
4. **Hardened runtime needs `com.apple.security.device.camera`
   even outside the sandbox.** TCC won't even prompt — it
   silently denies. Without that key, `requestAccess` returns
   `denied` with no UI. Add the entitlement to the v0.2.0 host
   entitlements file.
5. **Swift `NSLog` doesn't reach unified logging on
   macOS 14+** in our LSUIElement host or the system extension.
   Use `os.Logger(subsystem:category:)` exclusively. Tail with
   `log stream --predicate 'subsystem CONTAINS "ericwillis.avpainreliever"' --info --style compact`.
6. **Iterating on the extension binary requires either a reboot
   OR a Settings toggle off/on cycle.** Each new extension
   version queues the previous one as
   `[terminated waiting to uninstall on reboot]`, and macOS
   stops exposing the device through `system_profiler
   SPCameraDataType` until that queue clears. Confirmed both
   paths work: full reboot or System Settings → General →
   Login Items & Extensions → Camera Extensions → toggle off,
   wait, toggle on. The toggle path is faster but doesn't
   always work; reboot is the supported recovery.
7. **`open --env VAR=val`, not `VAR=val open`.** The shell-prefix
   form is stripped by `open` before launchd handoff. Has
   bitten us in M1 too — kept as a permanent note.
8. **Don't overlay a new bundle in `/Applications` between a
   build and a reboot.** macOS picks up the new bundle during
   boot and kicks off another upgrade cycle, undoing whatever
   the reboot was supposed to clean up. Reboot first, then
   install.

### Wizard camera-picker discovery (2026-05-04)

User report: after activating the virtual camera, "AV Pain
Reliever" showed up in Photo Booth but not in the Add/Edit
Profile wizard's camera picker. Three independent gotchas
overlapping; fix had to address each:

1. **Camera TCC for the host process.** `AVCaptureDevice.DiscoverySession`
   in a host that's never been granted camera permission
   silently hides `.external` devices including the host's
   own embedded Camera Extension. `CameraCaptureSession` only
   asks when the sink pipeline starts, which leaves the
   wizard blind on toggle-on-but-never-opened-Add states.
   Fix: `AppDelegate.applicationDidFinishLaunching` now
   pre-grants on `.notDetermined` so TCC settles before any
   wizard opens. Idempotent — `AVCaptureDevice.requestAccess`
   no-ops once authorized.
2. **Wizard reads the camera list once, at init.**
   `AddProfileViewModel.refresh()` runs from the initializer
   and from the manual Refresh button — nothing observes
   `VirtualCameraActivator.state`. A wizard opened during
   `.activating` / `.needsApproval` froze without the virtual
   camera. Fix: `WizardForm` now `.onReceive`s
   `delegate.virtualCameraActivator.$state` and triggers
   `viewModel.refresh()` on `.on`.
3. **Host process can't always see its own Camera Extension.**
   Even with TCC and a fresh refresh, AVFoundation's
   in-process discovery cache stays stale on first
   activation in some launches. Photo Booth (separate
   process) sees it; the host doesn't until relaunch.
   Same family as the existing disable→re-enable
   `requiresRelaunch` quirk. Fix:
   `VirtualCameraActivator.scheduleHostVisibilityCheck()`
   runs ~1.5 s after state flips to `.on`, runs a fresh
   `DiscoverySession`, looks for the extension by
   `virtualCameraUID`. If absent, escalates to
   `.requiresRelaunch` and stops the capture pipeline so
   the existing Settings "Restart" affordance handles it.

Lesson: a CMIO Camera Extension being live in the OS-level
graph does not guarantee the host that activated it can see
it. Always test the picker from inside the host, not just
Photo Booth.

### Lazy capture, signaled from the extension (2026-05-04)

User report: "macOS shows the green camera light on whenever
AV Pain Reliever is running, even when I'm not in a call.
OBS doesn't do this."

Root cause: `VirtualCameraActivator.enable()` was opening an
`AVCaptureSession` on the user's webcam the moment the
toggle flipped, regardless of whether anything was reading
the virtual camera. Always-on capture = always-on green
light. The original M3 design picked this for hold-last-frame
guarantees during mid-call source swaps, but those guarantees
only matter while a call is in progress; the rest of the
time the running session was pure waste.

OBS comparison: OBS gates capture on (a) a scene that uses
the camera being active AND (b) a downstream consumer
reading the OBS Virtual Camera output. We had neither gate.

Constraint that shaped the fix (M2 attempt #1, above): the
Camera Extension itself can't run AVFoundation, so we can't
move capture into the extension. Capture stays host-side; the
only knob is *when* the host starts/stops it.

Design:

- Extension exposes a "consumer is active" signal via Darwin
  notifications (Team-ID-prefixed names so the sandbox lets
  the extension post). Edge-triggered on `streamingCounter`
  0↔1 transitions in `CameraExtensionStreamSource.startStream`
  / `stopStream`.
- Host (`VirtualCameraActivator`) registers
  `CFNotificationCenter` Darwin observers as soon as state
  reaches `.on`, posts a "what's the current state?" ping so
  the extension re-broadcasts (covers the "host launches with
  extension already streaming a Zoom call from a previous
  host instance" case), and routes notifications to
  `handleConsumerActive` / `handleConsumerInactive`.
- Active: cancel any pending stop, start the pipeline if not
  running.
- Inactive: schedule a 30-s `DispatchSourceTimer` grace.
  Cancelled if a new consumer joins inside the window.
  Stops the pipeline on expiry.

Why Darwin notifications and not custom CMIO properties: the
CMIOExtension framework's bridging from `CMIOExtensionProperty`
(string-based) to host-visible `CMIOObjectAddPropertyListener`
(OSType selectors) isn't documented for custom properties.
Darwin notifications are 1980s-tech, but they work cleanly
across the sandbox boundary with a Team-ID prefix and are
edge-triggered for free. The "host launches mid-stream" case
is solved by a single ping at observer-registration time.

Result:

- Idle (toggle on, no Zoom call): green light off, no
  capture.
- Zoom opens our virtual camera: ~300-500 ms warmup, then
  frames flow.
- Zoom call ends: capture stays warm 30 s; green light goes
  off after.
- Profile-driven mid-call source swap: unchanged — the
  extension still re-emits the cached frame to cover the
  source-swap gap.

What we explicitly didn't add: a logo splash for the warmup
window. AV Pain Reliever's "passive utility" identity says
the camera should show the user's actual face, not our
brand, even for half a second.

### Profile camera = source, virtual camera = output (2026-05-04)

User caught a conceptual mismatch the day after the wizard
fix shipped: the per-profile Camera picker was listing
"AV Pain Reliever" alongside real cameras. That treated the
virtual camera as a possible *input source* — which is
nonsense, since the virtual camera's whole purpose is to be
the *output* that Zoom/Slack/etc. point at. A profile names
the *real* camera the virtual camera should route per
location.

Decision (option #2 of the three we walked through): when the
virtual camera is the active routing layer, the system-wide
preferred camera (`AVCaptureDevice.userPreferredCamera`)
points at the virtual camera, not the real one. Reasoning:

- Users set Zoom/Slack/Teams to "AV Pain Reliever" once,
  manually. That's the contract.
- AVFoundation-modern apps (FaceTime, Safari getUserMedia,
  Photo Booth) honour `userPreferredCamera` automatically.
  Setting it to the virtual camera makes those apps follow
  the same routing as Zoom — one coherent system state.
- System Settings → Cameras → Preferred Camera shows
  "AV Pain Reliever," which reinforces the model when the
  user goes looking.

Implementation:

- New `VirtualCameraSourceController.preferredCameraOverride: String?`
  protocol property (default `nil` so existing impls / tests
  compile unchanged).
- `VirtualCameraActivator` returns `"AV Pain Reliever"` when
  state is `.on`, nil otherwise. During `.activating` /
  `.needsApproval` / `.requiresRelaunch` / `.failed` we don't
  redirect — the device might not deliver frames.
- `ProfileApplier`: when `preferredCameraOverride` is non-nil,
  `setPreferred` gets the override; `setSource` still gets
  the profile's literal real-camera name. When nil, both
  calls get the literal name (legacy V1 behaviour).
- Wizard filters the virtual camera out of the picker
  (`AddProfileViewModel.refresh`) and quietly clears any
  saved profile value that points at it (legacy migration
  for profiles created during the buggy window). Helper text
  under the picker now adapts to the toggle state — explains
  the routing model when the virtual camera is on.
- `Engine.reapply()` + `ProfileApplier.invalidateLastApplied()`:
  the same profile name now produces different system-state
  writes depending on the toggle, so the dedupe key has to be
  invalidated when the toggle flips. Toggle off ⇒ AppDelegate
  calls `engine.reapply()` synchronously; toggle on ⇒ the
  activator's `.on` transition fires a `$state` Combine
  observer that does the same.
- `VirtualCameraActivator.disable()`: defensively clears
  `userPreferredCamera` if it's currently the virtual camera,
  so AVFoundation-modern apps don't get stuck on a now-dead
  device while the engine catches up.

Pieces left untouched:

- Menu bar's `currentCameraDisplay` still shows the
  *profile's* real camera name. Correct under the new
  model — the profile's intent is "use BRIO at this
  location," and the menu surfaces that intent.
- We don't programmatically set `userPreferredCamera` on
  toggle-on outside of the next profile apply. If the
  active profile has `camera == nil`, the system pref
  isn't touched. The user's "set Zoom to AV Pain
  Reliever once" instruction stays the contract; we don't
  over-ride to be helpful.

### Self-source feedback loop on late consumer connect (2026-05-05)

User report: virtual camera frozen on one frame intermittently
when sourcing from the office Neat Bar. FaceTime as the
source worked fine. Frames showed flowing in the log, just
all the same frame.

Two interacting bugs from the prior two days landed us here:

1. **`preferredCameraOverride` set `userPreferredCamera` to
   the virtual camera** (the right call for Zoom/FaceTime
   parity, see prior section). But
   `CameraCaptureSession.pickInitialDevice` reads
   `userPreferredCamera` first — so the host opened its own
   output as a capture source. Self-source: the host writes
   whatever it just read; the extension forwards it back; the
   only "real" frame is whatever the extension had cached at
   the loop's first iteration. Frozen frame, but with
   `Consumed` / `Forwarded` / `Enqueued` cycling at 30 fps in
   the log so it wasn't obviously broken.
2. **Lazy capture dropped pending `setSource` requests.**
   When a profile applied while no consumer was connected,
   `VirtualCameraActivator.setSource` no-op'd silently and
   forgot the requested name. So when Zoom connected later,
   the host had no idea the active profile wanted "Neat Bar
   Pro" and fell through to `userPreferredCamera` — bug #1.

Why "sometimes": the failure mode depends on Zoom-vs-dock
ordering. Open Zoom first, then dock → engine resolves the
office profile → `setSource` runs against the live session →
`switchSource` swaps inputs → real frames. Dock first, then
open Zoom → `setSource` is a no-op + dropped → consumer
connects → host self-sources → frozen.

Fix:

- `CameraCaptureSession.pickInitialDevice` rejects the
  virtual camera at every fallback step (userPreferred,
  systemPreferred, first discovered). New
  `isVirtualCamera(_:)` helper that matches on
  `VirtualCameraActivator.virtualCameraUID`. `findDevice`
  also rejects defensively so a profile that names "AV
  Pain Reliever" can't reopen the loop from the swap path.
- `CameraCaptureSession` gains an `initialSourceName: String?`
  init param. When set, it's the first thing
  `pickInitialDevice` tries.
- `VirtualCameraActivator.setSource` now stores the
  requested name in `pendingSourceName` even when the
  capture pipeline isn't running. `startCapturePipeline`
  passes it through to `CameraCaptureSession.init`. Cleared
  on disable + on the visibility-check failure path so the
  next enable starts clean.

Lesson: any time a capture pipeline can be torn down and
re-created mid-session (lazy capture, sleep/wake, error
recovery), the "what does the user want right now" state
has to live OUTSIDE the pipeline — otherwise it's lost on
every restart and the pipeline restarts with system defaults
that may not match the active profile.

### Local stats screen + privacy-first opt-in (2026-05-05)

User wanted a "fun nerdy stats" surface — counts of profile
switches, per-profile activations, streaks, unique USB
devices recognized. Discussed and ruled out anything
duration-based (camera-on time, frames piped, meeting
length) as too close to "tracking my work."

Shipped under a new **Stats** Settings tab. Originally
planned as "Advanced" with stats inside, but the menu bar
already exposes an Advanced submenu — two surfaces with the
same name read as a UI bug. Renamed to "Stats" to match
the actual content; future advanced/diagnostic settings can
get their own home if and when they show up.

Privacy stance: tracking is **off by default**. Every
recording method on `SettingsStore` (`incrementSwitchCount`,
`incrementManualOverrideCount`, `recordSwitch`,
`recordDevicesSeen`) early-returns when
`statsTrackingEnabled == false`. No `UserDefaults` writes
happen until the user explicitly opts in. Existing values
freeze (don't reset) when the user later disables — a
separate Reset Stats button wipes everything on demand.

Stat list (Balanced bundle):

- Total auto-switches (existing `profileSwitchCount`,
  surfaced)
- Per-profile activation counts → most-used location
  highlight + ranked list
- Tracking-since date (stamped on first opt-in, NOT on
  app first-launch, so the "47 days strong" number is
  honest about what's actually been recorded)
- Last switched (relative time + profile slug)
- Manual overrides (count of menu-driven `applyManually`
  calls)
- Current streak / Longest streak / Active days
- Unique USB devices recognized (count only, hashed as
  `"<vid>:<pid>"`)

Engine plumbing: new `Engine.onDevicesEvaluated:
((Set<USBDevice>) -> Void)?` callback, fires inside
`evaluateAndApply` after the watcher poll, regardless of
profile change. Lets `AppDelegate` feed the unique-devices
set without spinning up its own watcher.

Lesson: privacy-first defaults are easy to bolt on with a
single gate flag, but only if you push the gate into the
domain object (`SettingsStore`) instead of every caller.
Putting `guard statsTrackingEnabled else { return }` at the
top of each `record*` method means callers in `AppDelegate`
don't carry the conditional, and the easter-egg menu line
("Switched N times…") naturally freezes on opt-out without
any view-level changes.

### Button styling pass for macOS HIG alignment (2026-05-05)

Sweep across every standalone Button in the app to retire the
"indie SwiftUI app" tells and read as a native macOS settings
utility. Triggered by a side-by-side review of all four Settings
tabs + the Add/Edit Profile sheet — the buttons worked but
collectively read as off-pattern next to System Settings.

Rules applied (now also documented in
[plans/look-at-all-of-rustling-beacon.md](.claude/plans/look-at-all-of-rustling-beacon.md)):

1. No SF Symbol prefix on text Buttons. Apple's own dialog/sheet
   footers are text-only — Cancel never has an xmark, Save never
   has a plus or pencil. Exceptions: menu bar items (icon aids
   scanning), state indicators (spinner during save, ✓ on
   success), and toolbar buttons.
2. `.borderedProminent` is reserved for the *one* default action
   of a sheet/dialog (the one bound to Return). Using it on
   list-footer "Add" buttons competes visually with sheet
   primaries.
3. Row-action buttons in lists are borderless icon-only.
   Always-visible bordered chips look heavy next to row text.
4. Visual weight matches urgency. Restart-required state now
   pairs with a borderedProminent button instead of a muted
   `.small` default.
5. Ellipsis (`…`) on buttons that open further UI — sheets,
   alerts, system panes.
6. Destructive triggers inside grouped Form sections render as
   full-width red rows (`.foregroundStyle(.red)` +
   `.frame(maxWidth: .infinity, alignment: .leading)` +
   `.buttonStyle(.plain)`). Matches Apple ID → Sign Out and Game
   Center → Reset Recommendations. The bare `.role(.destructive)`
   on a `.bordered` button is a visual no-op on macOS (it only
   paints red on `.borderedProminent` and inside alerts/menus),
   so destructive intent has to come from `.foregroundStyle`.

Per-button changes:

- **Add Profile sheet footer** — drop xmark from Cancel and
  plus/pencil from Save/Update Profile (idle state). Spinner +
  ✓ Saved state indicators preserved.
- **Profiles tab footer Add button** — drop borderedProminent +
  plus icon, plain bordered "Add Profile…".
- **Profiles empty-state Add button** — drop plus icon, add
  ellipsis. BorderedProminent + large kept; this *is* the only
  meaningful action in an empty state.
- **`IconButton` helper** — `.bordered` → `.borderless`. One
  change applies to every pencil/trash row button across the
  Profiles list. Doc comment updated.
- **Camera tab Restart button** — promote to borderedProminent
  at default size when restart is required.
- **Camera tab Open Login Items button** — drop `.small`, add
  ellipsis (deep-links to System Settings).
- **Stats tab Reset button** — full-width red row inside the
  grouped section.
- **Add Profile USB fingerprint header** — text "Refresh" →
  borderless `arrow.clockwise` icon with tooltip. Matches Mail /
  App Store / System Settings refresh idiom. Considered binding
  ⌘R but the menu bar already owns it for "Re-evaluate Now" —
  two ⌘R bindings while the wizard is frontmost is asking for
  surprises, so left as click-only.

Untouched on purpose: AboutView (already correct — Sparkle-style
default + large Check for Updates), WelcomeView (already correct
— borderedProminent + large Add Your First Location), App.swift
menu bar (NSMenuItem entries SHOULD have icons; the rule only
applies to standalone Buttons).

Lesson: macOS's button vocabulary is narrower than iOS's. On
macOS, `.role(.destructive)` is semantic-only on bordered
buttons — if you want red, you have to paint it. And SwiftUI's
default Button-in-a-grouped-Section-row layout produces a small
chip floating in a grouped chrome box that doesn't match any
native pattern; the fix is to expand the label with
`.frame(maxWidth: .infinity)` + `.contentShape(Rectangle())`
and switch to `.buttonStyle(.plain)` so the whole row becomes
the tappable surface.

PR: [#28](https://github.com/superic/av-pain-reliever/pull/28),
shipped in v0.2.0.10.

### Profiles tab → real macOS bottom bar (2026-05-05)

Follow-up to the v0.2.0.10 button pass. The user surfaced a long-
standing visual oddity: the "Add Profile" button at the bottom of
the Profiles tab "looked wrong throughout the entire app" and had
been bothering them across many releases.

Investigation: Profiles is the *only* Settings tab not using
`Form { }.groupedFormChrome()` — it's the bespoke
`VStack { List + Divider + HStack(footer) }` layout (see
`GroupedFormChrome.swift`'s "intentionally bespoke" comment). The
footer was a faux bottom bar — a custom `HStack` with `.padding(12)`
*after* a `Divider()` — that visually mimicked a native macOS
bottom bar (Mail's "+ New Mailbox" sidebar bottom, Reminders' "Add
List", System Settings → Network's `+/-`) without using any of the
SwiftUI/AppKit APIs that produce one. As a result the button inside
read as a `.bordered` chip floating in custom chrome instead of
matching the unmistakable native bottom-bar affordance.

Fix: switched to the proper SwiftUI macOS bottom-bar pattern.

```swift
.safeAreaInset(edge: .bottom, spacing: 0) {
    HStack(spacing: 8) {
        Button { /* … */ } label: {
            Image(systemName: "plus")
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help("Add Profile")
        Spacer()
        Text("\(count) profile…")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(.bar)
}
```

Three native-rendering wins from this change:

1. **`.safeAreaInset(edge: .bottom)`** is the macOS API for "give
   me a bottom bar attached to this content." It reserves layout
   space correctly for the inset content and inherits proper
   safe-area behavior. `.toolbar { ToolbarItem(placement:
   .bottomBar) }` is the API name everyone reaches for first
   (including me, when first recommending the fix) — but
   `bottomBar` placement is iOS-only. On macOS, `.safeAreaInset`
   is the answer.
2. **`.background(.bar)`** is the system bar Material — translucent,
   adapts to light/dark, gets the automatic separator above. This
   is what makes the bottom bar read as a native macOS bottom bar
   instead of a custom HStack with a manually-drawn `Divider()`.
3. **Borderless `+` icon** is what Apple uses for "add a row to
   this list" everywhere it appears in their own apps — Mail's
   sidebar, Reminders, Notes, Network preferences. The hover
   tooltip via `.help("Add Profile")` keeps it discoverable.

Also: the bottom bar is suppressed in the empty state (the
borderedProminent + large hero "Add Profile…" CTA already covers
add-a-profile; doubling up reads as visual noise).

Lesson: always check for the existence of a real platform API
before reaching for a custom layout that mimics one. The faux
bottom bar pre-dated my involvement and had survived multiple
visual passes because it *looked* close enough — but the actual
native API gives you Material chrome, automatic separators, and
the right button-rendering context for free, none of which a
custom HStack reproduces by accident.

Lesson 2: API name carryover from iOS to macOS isn't always
1:1. `.toolbar(content:) { ToolbarItem(placement: .bottomBar) }`
exists on both platforms but `.bottomBar` placement only does
something on iOS. macOS needs `.safeAreaInset(edge: .bottom) +
.background(.bar)`.

PR: TBD, shipped in v0.2.0.11.

### CI toolchain pin via self-hosted runner (2026-05-05, v0.2.0.12)

This was supposed to be a sanity-check release for the bottom-bar
fix. Instead it became the answer to a much older mystery the user
had been calling out for months: **the buttons in the shipped app
look subtly different from the buttons in the dev build.**

Story arc:

1. **The complaint resurfaced** during v0.2.0.11 verification. The
   user A/B'd two screenshots of the Add Profile sheet's Cancel +
   Save Profile buttons. One had taller buttons with white-fill
   chrome; the other had flatter, grey-fill chrome. The user
   preferred the flatter look.
2. **First wrong hypothesis:** I assumed Sparkle had landed an
   incomplete update (Info.plist new, Mach-O old). Verified via
   `cmp` and `shasum` — both bundles' executables differed but were
   source-equivalent on string content (`Add Profile…`, `Open Login
   Items & Extensions…`, etc. all present in both with the same
   counts). Source-equivalent, byte-different.
3. **Second wrong hypothesis:** LaunchServices was launching the
   wrong bundle (two .apps with the same bundle ID on disk —
   `/Applications/AVPainReliever.app` and
   `dist/AVPainReliever.app` from a recent local build). `ps`
   confirmed the running process was actually `dist/`, not
   `/Applications/`. So the user's "two screenshots from two
   builds" was actually "two screenshots, both from dist/" — and
   the chunkier "white-fill" rendering was actually from an
   earlier session of `/Applications` that the user had captured
   but mis-labeled. This was a real LaunchServices ambiguity bug
   to know about, but not the rendering cause.
4. **Third hypothesis (the right one):** check the build
   configuration of the CI binary vs the local binary. Both built
   `swift build -c release`, both signed with the same Developer ID,
   identical Info.plist. But:

   ```
   $ otool -l /Applications/AVPainReliever.app/Contents/MacOS/AVPainRelieverApp \
       | grep -A 5 LC_BUILD_VERSION
   platform 1
       minos 14.0
         sdk 15.2     ← CI was building against Sequoia SDK
   $ otool -l dist/AVPainReliever.app/Contents/MacOS/AVPainRelieverApp \
       | grep -A 5 LC_BUILD_VERSION
   platform 1
       minos 14.0
         sdk 26.4     ← Local was building against macOS 26 SDK
   ```

   Verified with `gh run view --log` on the v0.2.0.11 release
   workflow: CI's `Select Xcode` step picked **Xcode 16.2.0** when
   `xcode-version: latest-stable` resolved on the `macos-14` runner.
   Local Xcode is 26.4.1.

The mechanism is well-documented but easy to miss: **macOS keeps
old SwiftUI rendering paths alive for backward compatibility, and
the SDK at compile time picks which path the binary calls into.**
Same Swift source, two different SDKs at compile, two different
runtime renderings. The shipped app rendered with macOS 15-era
SwiftUI; the dev build rendered with macOS 26-era SwiftUI; they
visibly diverged on `.bordered` chrome thickness even on the same
host machine.

**Initial fix attempt:** bump CI runner to `macos-26-arm64` (which
carries Xcode 26.x) and pin `xcode-version: '26.4.1'` explicitly.
This worked toolchain-wise, but the runner queue time spiked to
30+ minutes — Apple Silicon `macos-26-arm64` runners are scarce in
GitHub's free pool. Aborted; needed a different solution.

**Final fix:** self-hosted runner installed on the user's Mac as a
LaunchAgent (`~/actions-runner/`). The runner uses whichever Xcode
is at `/Applications/Xcode.app` (currently 26.4.1), so toolchain
parity is automatic — when local Xcode bumps, CI follows. Queue
time drops from "30+ minute spike risk" to "starts in seconds."
Setup details + security model in
[docs/self-hosted-runner.md](docs/self-hosted-runner.md).

Security mitigation for self-hosted on a public repo: configured
the Actions setting `fork-pr-contributor-approval =
all_external_contributors`, so every external contributor's
workflow run requires explicit maintainer approval before it can
execute on the runner. Combined with GitHub's design that secrets
are never passed to fork-PR workflows, this means a malicious fork
can neither auto-execute on the dev's Mac nor read the signing
cert / Sparkle private key even if approval is granted.

**New convention introduced this release: pre-publish binary
verification.** Before flipping the v0.2.0.12 draft release to
published, downloaded the CI artifact, built the same tag locally,
and `cmp`'d the two Mach-Os. Result: 3,520 byte delta (down from
~209 KB on v0.2.0.11), all attributable to notarization-ticket
embedding. Same SDK, same renderings paths, byte-equivalent code.
Only then published. This step is now standard for every release —
see [docs/releasing.md](docs/releasing.md) "Pre-publish binary
verification."

Lessons:

1. **"Same source, different binary, different rendering" is a real
   thing.** When debugging visual divergence between two builds,
   check the SDK target via `otool -l ... | grep LC_BUILD_VERSION`
   before assuming code is different. Apple's backward-compat SDK
   pinning means the byte difference can be entirely in which
   SwiftUI runtime API path the compiler emitted calls to.
2. **`latest-stable` is not stable across runners.** The maxim-
   lobanov/setup-xcode action's `latest-stable` resolves to the
   newest Xcode pre-installed on the runner image, which depends
   on the runner OS version. macos-14 → Xcode 16.x; macos-26-arm64
   → Xcode 26.x default (26.2 not 26.4.1). For repeatable builds,
   pin explicitly OR use a self-hosted runner.
3. **LaunchServices ambiguity with duplicate bundle IDs is its own
   gotcha.** Two `.app` bundles with the same bundle ID confuse
   `open` — the path argument isn't always honored. For dev-vs-
   shipped comparison, `ps aux | grep AVPainReliever` is the
   ground truth for which executable is running.
4. **Sparkle replaces the bundle on disk but doesn't kill the
   running process.** Always `pkill -f AVPainRelieverApp && open
   /Applications/AVPainReliever.app` after a Sparkle-delivered
   update to actually pick up the new code, otherwise the running
   process is the old one. Bit us at the start of this debugging
   session.

Files touched:
- `.github/workflows/release.yml` — runs-on swap, removed Select
  Xcode step, made SPM cache reset GitHub-hosted-only
- `.github/workflows/test.yml` — same
- `docs/self-hosted-runner.md` — new setup + security guide
- `docs/releasing.md` — added pre-publish verification convention,
  post-mortem entry for v0.2.0.12

PR: [#31](https://github.com/superic/av-pain-reliever/pull/31)
(workflow changes), shipped in v0.2.0.12. Doc updates in a follow-
up PR.

### v0.2.x graduates from experimental to stable (2026-05-05)

The virtual-camera development track has been on the experimental
Sparkle channel since v0.2.0 (2026-05-04). Decision today: graduate
it. The work was driven by three things converging:

1. **Apple-side gates are clear.** A round of research (Apple
   Developer Forums + Halle Winkler's CMIO blog series, see the
   memory `project_virtual_camera_v2.md`) confirmed that
   distributing a CMIO Camera Extension via Developer ID outside
   the Mac App Store needs only the entitlements we already declare
   (`system-extension.install`, `application-groups`,
   `device.camera`). No additional Apple email request needed. The
   12 successful notarizations of v0.2.0 → v0.2.0.12 are empirical
   proof.
2. **The feature has been exercised end-to-end.** Capture from
   FaceTime HD + HDMI capture cards, hold-last-frame during
   profile switches, format negotiation, self-source feedback loop
   guard, and the macOS-extension-deactivation `.requiresRelaunch`
   workaround all shipped and survived real use.
3. **Keeping v0.2.x experimental indefinitely is wrong** — the
   experimental channel exists for risky feature development, not
   as a permanent home for shipped features. Sitting on it
   permanently contradicts the channel's purpose and confuses
   future graduations.

What the graduation actually changes:

- **`release.yml` channel rule inverted.** Was: "v0.1.x stable,
  everything else experimental." Now: stable by default; explicit
  `-experimental` (or `-experimental.N`) tag suffix opts in. Future
  `v0.2.0.13`, `v0.3.0`, `v1.0.0` etc. ship stable automatically.
  Future risky-feature builds use a tag like
  `v0.2.1.0-experimental.1`. Convention is more future-proof
  (no workflow edit needed when major version bumps) and matches
  how most apps work (stable is the default; experimental is the
  intentional opt-in).
- **`appcast.xml` v0.2.0.12 retagged stable.** Single XML edit
  drops the `<sparkle:channel>experimental</sparkle:channel>` line
  from v0.2.0.12 only. Previous experimental items (v0.2.0.2 →
  v0.2.0.11) keep their tags — historical accuracy preserved; they
  WERE experimental at the time. Stable-channel users (currently
  nobody beyond the dev) will see v0.2.0.12 on their next Sparkle
  check; no need to wait for a new release.
- **Settings → General → "Receive experimental updates" toggle
  stays.** Per the dev's intent, the experimental capability is
  preserved for future risky-feature work — the toggle, the
  `ChannelGatingDelegate`, the `experimentalUpdates` setting, and
  the "you're running an experimental version" nudge alert all
  remain in place. Help text under the toggle was genericized
  ahead of this PR (PR #34) so it doesn't name v0.2.x specifically
  and stays accurate as the experimental queue empties / refills.
- **`docs/releasing.md` documents the new tag convention** in a
  new "Stable vs experimental tags" section, including the
  `vX.Y.Z` vs `vX.Y.Z-experimental.N` rule and graduation
  procedure ("ship next release without the suffix; optionally
  retag specific appcast items").

What graduation explicitly does NOT do:

- No new release tag was cut. The dev is currently the only user;
  no need for a ceremonial graduation release. The next normal
  release (whenever something ships next) will be the first
  workflow-default-stable release.
- No code-level change to extension activation, the host's CMIO
  pipeline, or the virtual camera surfaces in Settings. The
  feature itself is unchanged — only its Sparkle channel
  classification changed.

Lesson: experimental release channels are scaffolding, not a
permanent home. When the feature they were built around graduates,
the channel needs to be reset back to "empty waiting room" for the
next risky thing — keep the mechanism, retire the specific
classification.

PR: TBD (this commit), shipped without a tag. Next release inherits
the new behavior automatically.

### Slop-review program, engine + app target (2026-05-09)

Two-pass `code-quality:slop-review` against the SPM workspace, run as
two campaigns: engine library first (`Sources/AVPainReliever`, ~17
files), then the app target (`Sources/AVPainRelieverApp`, ~28 files).
16 PRs merged on 2026-05-09 across the range #50–#66; PR #55 was a
working artifact closed without merge.

**Engine pass (#50–#65, 15 merged).** High-leverage moves:

- `Notifier` protocol and implementations moved from the engine
  library to the app target (#54, #57). Engine no longer carries
  surface that only the app target consumed; better layering.
- `CameraCaptureSession` refactors: drop redundant
  `VirtualCameraSourceController` conformance (#61), reshape
  observers as closure tokens (#64). Two follow-ups that landed
  cleanly because the file's responsibilities were already clear.
- `IOKit` notification iterators are now released in
  `USBWatcher.stop()` (#60). Real bug, low blast radius (only fires
  on app teardown), worth fixing once the slop pass surfaced it.
- Audio/CameraController split into `Applier` + `Inventory` seams
  (#59). Same code, narrower surfaces, easier to reason about which
  half is being injected at each call site.
- Restart now uses `open -n` to force a new app instance (#53).
  `open` alone deduped the launch when the previous process was
  still tearing down, leaving the user staring at an unrestarted
  app. M2 lesson at line 100 had foreshadowed this; the slop review
  found the actual bite.
- Idiomatic-Swift cleanups in engine adapters (#58), ProfileWriter
  regex fix for hand-edited TOML (#65), engine doc sweep + named
  log-rate constants (#50), small helpers extracted (#51), logger
  threading + `ApplierLogger.error` (#52).

**App target pass (PR #66, single consolidated cleanup).** Six
behavior-preserving items: drop `AppDelegate.currentCameraDisplay`
(dead `@Published`), drop `DevicePortability.isLikelyPortable` +
its keyword list (dead duplicate), move `VersionInfo` from
`SettingsView.swift` to `AboutView.swift`, rewrite the stale
`profileSwitchCount` doc, drop `Theme.Color.muted` (CLAUDE.md says
status colors are the only `Theme.Color` entries), extract
`StatusPill` and migrate the three inline pill chromes. Net
`-127 / +60` across 8 modified + 1 new file. The `StatusPill`
extraction also fixed a real dark-mode contrast issue: wizard pills
had hardcoded `.black` foreground on a 0.85-opacity tint, dimming
to muddy in Dark appearance. Unifying on white-on-tint matches the
two existing settings sites and reads cleanly in both modes.

**Meta-iatrogenic rate stayed visible.** Two of the engine PRs
(#62, #63) fixed slop introduced by the slop-fixes themselves
("slop-fix slop"): doc comments rewritten in the first pass that
referenced removed symbols, a regex helper that was clearer in
isolation but worse at the call site. Both were caught by running
the review a second time after the first round of fixes landed.
Worth keeping that discipline: the second pass is where the
fix-the-fix cases surface.

**Deliberately deferred.** The app-target plan flagged a borderline
backlog (F2 `AppDelegate` lifecycle/composition-root split, F5
`VirtualCameraActivator` carve-up, F6 `SettingsStore` property
wrapper + stats-store split, F7 `AddProfileViewModel` split) that
is explicitly skip-unless-touching-the-file. Several have real
state-coordination cost across the proposed carve points. Working
plan files for both passes are kept in `tools/` (gitignored) so
future passes inherit the calibrated verdicts instead of re-running
from cold.

Lesson: a second slop pass after the fixes land earns its keep.
Fix-the-fix rate was non-zero (2 of 15 engine PRs); without the
second pass those would have been merged as silent regressions in
prose accuracy. Cheap to run, mechanical to address, demonstrably
catches drift the first pass introduced.

### Save-as-new + collision dialog fixes (2026-05-09)

Five follow-on PRs (#68, #69, #70, #71, #72) ran on the same day
as the slop-review program. Three of them fixed real product bugs
that surfaced while testing the slop-review changes; the other two
were small cleanups.

**The bug class.** `ProfileResolver` (`Sources/AVPainReliever/Engine/ProfileResolver.swift`) picks the most-specific matching profile and breaks ties alphabetically by name. That tiebreak rule is a validated design decision (see `docs/decisions.md` "Most-specific match wins"), but it interacts badly with the wizard's save flow: when a newly saved profile shares its fingerprint with an existing sibling at the same specificity, the resolver silently picks the older sibling and the user-visible audio/camera state doesn't reflect the just-saved profile. The first add of any session works because the new profile is the only one matching its fingerprint; the second-and-later adds, the collision Save-as-new path, and the collision Update-existing path all hit the bug.

**The fix shape.** `AddProfileViewModel.onSaved`'s callback contract grew a `forceApplySlug: String?` parameter. The wizard passes it on every save path that involves the user declaring "this profile should be active":

- New-profile no-collision append → force-apply.
- Collision dialog "Update existing" → force-apply (user explicitly chose which profile to land on).
- Collision dialog "Save as new" → force-apply (same).
- Edit-in-place (slug unchanged) → no force-apply (resolver re-picks the same profile, applier applies fresh state on the rebuilt engine).
- Edit-rename no-collision → no force-apply (user might be renaming a profile they aren't currently on; force-applying would yank them onto it unwantedly).

The host (`AppDelegate.onSaved` closure) receives the slug, sets a `pendingForceApplyName` gate, runs `reloadConfig` (which rebuilds the engine and fires `onProfileApplied` once with the resolver's pick — the gate suppresses it in `handleProfileApplied`), then explicitly calls `engine.applyManually(profile)` on the looked-up profile. The user perceives one switch, one toast, one switch-counter increment, regardless of whether the resolver picked the right or wrong profile first.

The `applyManually` call goes directly to `Engine`, not to `AppDelegate.applyManually` — so the manual-override stats counter is correctly NOT incremented for save-driven force-applies.

**Iteration history (kept here so future-Claude can read the why).** PR #69's first commit force-applied unconditionally on `confirmSaveAsNew`. The second commit broadened to all new-profile paths but gated everything on `editingSlug == nil` to avoid yanking users in edit-rename. The third commit reverted that gate for the dialog buttons (`confirmReplace` + `confirmSaveAsNew`) because clicking a dialog button is an explicit "land me on this" signal regardless of editing context — the user reported "edited X, renamed to existing Eric, picked Save as Eric 2, landed on laptop" and the gate was the cause. Final state: `save()` trailing append is gated on `editingSlug == nil`; the two dialog buttons force-apply unconditionally. The diagnostic that settled the third iteration was a debug branch with `os.Logger` tracing at every decision point in the force-apply pipeline; the user captured 60 seconds of log output and the analysis flipped from speculation to verified contract in one round.

**Other PRs that landed in the same cluster:**

- PR #68: borderline-backlog trivial wins (A4 dead `profile` param, M3 `static var` → `static let` for `WelcomeView.greetingTitle`, I1b `Binding.isPresent(_:)` extension migrating two `Binding(get:set:)` glue sites). M4, M6, F12 from the original plan got dropped after verification — see `tools/slop-plan-app-target.md` for the triage.
- PR #70: collision dialog body now spells out the deletion side effect when the user got there by editing a profile and renaming into an existing slug. `PendingCollision` grew an `editingPrettyName: String?` field; `AddProfileView`'s alert message branches on it.
- PR #71: name-field focus on every wizard open. `@FocusState` on the TextField, set true via `DispatchQueue.main.async` inside `.onAppear`. Without the deferred dispatch the underlying NSResponder isn't wired up at the time `.onAppear` fires on macOS 14.
- PR #72: dropped `actionTitle: String?` from `Notifier.notify`. Both backends (UN + AppleScript) silently ignored it; the only caller passed exactly the value the registered UN category was already rendering. Slop-review item M7.
- PR #73: tightened CLAUDE.md across six themes (provenance, motivational copy, examples within rules, overlapping sections, etc.). Net 122 → 104 lines. Established the operating principle: CLAUDE.md is operational rules only; provenance lives in CHANGELOG.

Lessons:

1. The resolver's alphabetical tiebreak rule is correct (it's the validated design decision); it's the wizard's save flow that needed to model "user just declared this should be active." Don't change the resolver to avoid the tiebreak; let the host signal intent.
2. Diagnostic tracing settles speculation cycles cheaply. After three rounds of "should work but the user says it doesn't" speculation, instrumenting the actual code paths and asking the user for log output flipped the conversation to evidence in one pass.
3. CLAUDE.md is auto-loaded into every session, so prose that doesn't operationalize a rule pays context tokens forever for one-time onboarding signal. The PR #73 tightening pass codified this — every line in CLAUDE.md should be doing operational work, with provenance moved here.

PRs: #68 (`9b8f50f`), #69 (`a2856d3`), #70 (`f7abc81`), #71 (`6d4cba3`), #72 (`4d61c8c`), #73 (`a69b1e0`). All on `main` as of 2026-05-09.

### Stats forget deleted profiles (2026-05-09)

Deleting a profile now also drops its per-slug stats. Before this, the Stats tab kept rendering ghost rows for profiles the user had explicitly removed: orphaned `perProfileCounts` entries, plus a stale "Last switched … to <ghost>" line. Stats are local-only and the slug is the only key, so a deleted-then-recreated profile would just start a new count anyway. There's no honest reconciliation to do, so dropping the entries on delete is the correct shape.

`SettingsStore.forgetProfile(slug:)` removes the slug's count and clears `lastSwitchSlug` / `lastSwitchDate` only when they match (so deleting an unrelated profile doesn't blank out the relative-time line). Aggregate counters (`profileSwitchCount`, streaks, active days, unique devices) are deliberately untouched: they reflect overall app usage, not which profile won each switch.

Wired from `AppDelegate.deleteProfile`, after the on-disk TOML delete succeeds. If the disk delete fails, the stats stay (no orphaning created).

A second method, `SettingsStore.reconcileProfiles(currentSlugs:)`, runs on every config load (inside `AppDelegate.bootEngine`) and drops per-slug stats whose profile no longer exists. This serves two roles: it self-heals stats orphaned by anything that bypassed the delete-time hook (a hand-edit of `profiles.toml`), and it acts as a one-shot migration for users on a build that predates `forgetProfile`. No-op (no disk write) when nothing is orphaned, so it doesn't churn UserDefaults on every reload. Same scope as `forgetProfile`: per-slug data only, never aggregates.

PR: #75 (`ea69f58`).

### Stats: per-profile rankings as their own Section (2026-05-09)

The Stats tab's per-profile breakdown was visually confusing: the most-used profile rendered as a `LabeledContent("Most-used location", value: "Laptop (36)")` with the profile name on the *right*, while the runner-up rows rendered as `LabeledContent("Home Office", value: "18")` with the profile name on the *left*. Same data, two columns, broken eye-scan. The "Most-used location" row also lived inside the Tracking section, sandwiched between unrelated rows like "Manual overrides" and "Active days" — the section interleaved profile rankings with global counters.

Restructured: dropped the "Most-used location" highlight row entirely, moved every per-profile entry into its own Form `Section` with header `Label("Switches by location", systemImage: "list.number")`, sorted by descending count. The first row IS the most-used by definition — sort order carries the meaning, no separate winner callout needed. Matches Apple's pattern for similar surfaces (Settings → Battery, Settings → General → Storage, iOS Settings → Privacy → Tracking): show a sorted list, trust the user to read the top entry as the leader.

`StatsSettingsTab.topProfile` and `StatsSettingsTab.otherProfiles` collapsed into a single `rankedProfiles` computed prop. Updated the doc comment on `SettingsStore.perProfileCounts` to drop the stale "most-used location highlight" reference.

### CLAUDE.md: codify the "docs that move with the code" rules (2026-05-09)

Added a "Docs that move with the code" subsection to CLAUDE.md under "Project-wide conventions" so the CHANGELOG-on-every-PR and README-when-user-visible-changes rules are part of the auto-loaded operational ruleset, not just personal memory. Without this, only sessions that happen to carry the right memory entries would know to keep the journal current and the README in sync; codifying it in CLAUDE.md means every fresh agent session in this repo inherits the rule.

The triggers are explicit: CHANGELOG gets a dated H3 entry on every non-mechanical PR; README updates only when a PR changes user-visible behavior (a new setting, renamed menu item, removed feature, install-flow change). Internal refactors, doc-only edits, and test-only changes don't touch README — an executive reader wouldn't notice them. Same operational-rule shape as the other CLAUDE.md subsections, ~6 lines added.

### Verbose `.debug` logging + Save Logs for Support menu item (2026-05-09)

Two complementary diagnostics features in one PR.

**Verbose logging.** `ApplierLogger` (the engine's logging seam in `Sources/AVPainReliever/Engine/ProfileApplier.swift`) gained a fourth method, `func debug(_ message: String)`, with a default no-op impl that keeps existing test conformers (`MockLogger` in `ProfileApplierTests.swift`) building unchanged. The production `ConsoleLogger` overrides `.debug` to route to `os.Logger.debug` (no stderr mirror — too chatty for `swift run`). Chatty per-event `.debug` calls now exist across four areas the user explicitly scoped: engine internals (`Engine`, `ProfileResolver`, `ProfileApplier`, debounce decisions), `IOKitUSBWatcher` (every attach/detach burst with device counts, plus initial-drain-suppressed signals), `AppDelegate` switch handler / `SettingsStore` writes (every UserDefaults persist via a new `write(_:forKey:)` helper), and the virtual camera lifecycle (`VirtualCameraActivator` state transitions, `CameraCaptureSession.setSource`).

By default, `log stream` doesn't show `.debug` entries — they're invisible until explicitly requested. To consume the verbose channel during a diagnostic session, run:

```sh
log stream --predicate 'subsystem CONTAINS "ericwillis.avpainreliever"' --level debug --style compact
```

The local `dev/build` helper (private repo) prints this command in its post-build status block so it's one paste away after every full build.

`ProfileResolver.resolve(attached:)` gained an optional `logger:` parameter (default nil) so the resolver can emit "candidate scoring + winner" debug lines when called from the engine; existing call sites and tests stay source-compatible. `IOKitUSBWatcher.init(logger:)` gained the same shape. The two seams differ on purpose: the resolver is `Sendable` and stateless, so per-call injection avoids changing its value-type semantics; the watcher holds long-lived IOKit notification ports, so init injection fits.

**Save Logs for Support…** A new `LogExporter` enum (`Sources/AVPainRelieverApp/LogExporter.swift`) exposes a static entry point wired to a new `Advanced → Save Logs for Support…` menu item. Uses `OSLogStore(scope: .currentProcessIdentifier)` + `NSPredicate(format: "subsystem BEGINSWITH %@", "com.ericwillis.avpainreliever")` to dump the last 60 minutes of main-app log entries to a user-chosen file (default `av-pain-reliever-log-<timestamp>.txt` in Downloads). Reveals the result in Finder and shows a follow-up alert with the entry count. Plain-text format: `timestamp [category] [level] message`, prefixed with a header documenting the window, subsystem prefix, entry count, and the `.debug`-not-persisted caveat.

**Scope caveat.** `OSLogStore(scope: .currentProcessIdentifier)` captures the calling process only. The embedded Camera Extension runs in a separate process (subsystem `com.ericwillis.avpainreliever.CameraExtension`); its logs are NOT in this export. The wider scope (`.includeAllProcesses`) requires a private-data-access entitlement that may not survive notarization for a sandboxed direct-distribution app, so the simpler scope was chosen. The doc comment + the file header in the export both name this limitation explicitly so a support reader knows to also capture Console.app output filtered by the extension's subsystem when the bug is virtual-camera-related.

**Persistence levels — caught during user-visible testing.** Apple's unified log persists `.notice` and above by default; `.debug` AND `.info` are memory-only and never reach the archive `OSLogStore` reads. An initial pass had `ConsoleLogger.info` routing to `os.Logger.info`, which made the support export nearly empty (the user's first test run captured this — almost nothing showed in the saved file even though `log stream` was busy). Fix: `ConsoleLogger.info` now routes to `os.Logger.notice` since our `info` semantic is "state transition worth keeping" — exactly what Apple's `.notice` is for. Same change for the three direct `os.Logger.info` callsites in the App target (`VirtualCameraActivator`, `LaunchAtLogin`, `Updater`). The Camera Extension's direct `os.Logger.info` callsites were left alone — extension entries don't reach this export anyway (separate process, called out explicitly in the doc and the file header).

**`.debug` is transient by design.** Even after the `.info → .notice` fix, `.debug` is still off the persistence path. That's intentional: `.debug` is for live `log stream` consumption during real-time debugging; bug-report exports get the more durable `.notice`/`.warning`/`.error` entries. An in-memory ring buffer was considered and deferred — the live `log stream` flow handles the niche case where `.debug` is actually needed.

**Slop pass.** Pre-PR `/code-quality:slop` review against the diff caught the `OSLogStore` scope/doc mismatch (originally claimed Camera Extension capture; corrected to be honest about main-app-only), an enum-equality `String(describing:)` shortcut in `VirtualCameraActivator.state` (replaced with the existing `Equatable` conformance), em dashes leaking into log strings (project memory rule), an inconsistent raw `Logger` instance in `SettingsStore` (rerouted through `ConsoleLogger(category: "settings")` to match the rest of the codebase), and over-explaining doc comments on the new `AppDelegate.logger` field (trimmed to the one-liner). Verbose `funcName: <prose>` debug strings in `AppDelegate` switch handlers also got tightened to just the variable info.

### Fix camera visibility race on Camera Extension activation (2026-05-09)

Once Feature B's verbose logging shipped (#78), the new `.notice` and `.debug` lines made an existing virtual-camera bug obvious at every fresh launch:

```
[engine] applying profile: home-office
[engine] set default input: Yeti Stereo Microphone
E [engine] camera 'AV Pain Reliever' not found, skipping (it may not be currently attached)
E [Activator] Visibility check: host process can't see its own Camera Extension, escalating to .requiresRelaunch
[Activator] state: on → requiresRelaunch
```

Two related symptoms, one root cause. When `OSSystemExtensionRequest` reports activation success, the activator transitions `state → .on` immediately. A Combine sink in `AppDelegate` was firing `engine.reapply()` synchronously on that transition. The applier then asks `setPreferred(named: "AV Pain Reliever")` (the virtual camera's display name), but `AVCaptureDevice.DiscoverySession` in the host process still has a stale cache (warmed before the extension registered) so the call returns `.notFound`. ~1.5s later, `scheduleHostVisibilityCheck` runs, sees the same blindness, and escalates to `.requiresRelaunch` — surfacing the manual "Restart" button in Settings → Camera. After the user clicks Restart, the second-process DiscoverySession is fresh and sees the camera fine.

The fix is to defer the post-activation reapply until *after* the visibility check confirms visibility. Two minimal changes:

- `VirtualCameraActivator` gained a `var onVisibilityConfirmed: (() -> Void)?` callback. `scheduleHostVisibilityCheck`'s success branch fires it.
- `AppDelegate` sets the callback to `engine.reapply()` and adds `.filter { !$0 }` to the existing `$state` Combine sink. The sink now only fires reapply on transitions *out of* `.on` (toggle-off cleanup, visibility-failure cleanup); transitions *into* `.on` go through the visibility-confirmed callback so AVFoundation has had ~1.5s to refresh first.

After the fix, the same sequence on a fresh launch logs:

```
[Activator] state: activating → on
[engine] applying profile: home-office  (initial — runs once at engine.start())
... 1.5s ...
[Activator] Visibility check: host sees the virtual camera in DiscoverySession
[engine] applying profile: home-office  (reapply — now succeeds because cache is fresh)
[engine] set preferred camera: AV Pain Reliever
```

No `not found` error, no `.requiresRelaunch`, no manual Restart click. The user-visible "AV Pain Reliever appears in Zoom/Slack/Teams as a usable camera within 2s of launch" outcome matches what users have always expected.

The first apply on launch (from `engine.start()`) still happens before visibility is confirmed, so it'll still log `set preferred camera: HDMI to U3 capture` (the literal profile camera) since the activator's `preferredCameraOverride` returns nil while `state != .on`. The deferred reapply then re-fires once the override is live AND the cache has refreshed. Two applies per launch is fine — applier no-ops a same-name re-apply, and `reapply()` explicitly invalidates that dedupe so the second pass actually runs.

PR: #79.

### Poll for visibility instead of one-shot checking (2026-05-09)

Follow-up to PR #79. Hands-on testing surfaced a second visibility-race symptom on the in-session toggle-off-then-on path: the auto-relaunch's first visibility check at 1.5s frequently fails because the OS hasn't fully republished the Camera Extension yet (it was just deactivated and reactivated within a few seconds). State escalates to `.requiresRelaunch` again, and the user has to click Restart a *second* time. Empirically the OS needs another ~3-5s after that, at which point the cache is healthy and Photo Booth/Zoom see the virtual camera fine.

`scheduleHostVisibilityCheck` previously did a one-shot `asyncAfter(deadline: .now() + 1.5)`. Now it uses a small polling loop: first check at 1.5s (so the fresh-launch happy path's latency stays the same), and on failure poll every 1s up to an 8s total budget. As soon as `hostCanSeeVirtualCamera()` returns true, fire `onVisibilityConfirmed` and stop polling. Only escalate to `.requiresRelaunch` once the budget is exhausted.

Net effect: the toggle-off-then-on path now needs one auto-relaunch instead of two. The fresh-launch path is unchanged (the first check at 1.5s passes and we exit immediately). Failure mode (extension truly broken) takes 8s instead of 1.5s before showing the Restart button — acceptable tradeoff because the success rate of the eventual poll is high enough that the additional dead time on the rare honest-failure case isn't worse than the false-escalation rate of the one-shot check.

Recursion via `DispatchQueue.main.asyncAfter` (each poll schedules the next) is safe: the closure captures `[weak self]`, so a deallocated activator bails on the `guard let self`. State changes during polling (user disables, manual override) bail via `guard self.state == .on`.

### Roll back the virtual-camera toggle when the deactivate auth prompt is cancelled (2026-05-09)

User-visible bug: with the virtual camera on, flipping Settings → Camera off, then clicking Cancel on the macOS admin-password prompt, left the app in a `.failed` state. Toggling back on tripped the in-session deactivation guard and forced a `.requiresRelaunch` auto-relaunch — five seconds of dance for an action the user explicitly cancelled.

The OS-level deactivate never went through (Cancel meant Cancel), so the extension was still alive. The only thing wrong was the host's view of state: `disable()` flips state to `.off` synchronously before submitting the deactivation request, and the existing `didFailWithError` path indiscriminately escalated every failure to `.failed(message)`.

Fix: in `VirtualCameraActivator.didFailWithError`, detect the auth-cancel-during-deactivate case (`state == .off` AND error domain `OSSystemExtensionErrorDomain` AND code `OSSystemExtensionError.Code.authorizationRequired` (13)). Roll back: restore `state = .on`, clear `deactivatedThisSession`, restart the consumer watch that `disable()` ended, and fire a new `onDeactivateAuthCancelled` callback. AppDelegate's handler sets `settings.virtualCameraEnabled = true` so the Settings UI bounces back, and calls `engine.reapply()` so the active profile re-routes to the virtual camera (disable's synchronous teardown had pointed the system-preferred camera at the real fallback).

Activate cancels keep the existing `.failed(message)` behavior because "user said no" to an activation means leave the camera off. Distinguishing the two cases by the activator's state at failure time (`.off` for deactivate, `.activating`/`.needsApproval` for activate) is robust without needing a separate "kind of request" flag.

Logged as `.notice` rather than `.error` because the auth cancel is an expected user action, not a bug.

PRs: builds on #79 and #80; mirrors the closure-callback pattern (`onVisibilityConfirmed`) introduced in #79.

### docs/decisions.md sync after the persistent-todo walkthrough (2026-05-09)

Walked the Pending review section of `tools/todo.md` (the gitignored persistent-todo file) and folded the resulting signals into `docs/decisions.md`. Doc-only PR; no code changes.

**Open questions consolidation.** Four open questions had collected enough signal to settle: vid/pid collision (no hits across 3 users; was already redundant with the validated USB-fingerprinting decision), menu bar profile-name display (default works for all 3 users), external user wizard sticks (2 users completed without help), and toast notifications useful-or-annoying (a Settings toggle "Send notifications when profiles change" already ships, so the question is user preference rather than a code change). The validated notifications bullet in `docs/decisions.md` was clarified to mention the toggle. All four moved into a new "Resolved on 2026-05-09 (walkthrough)" section at the bottom of the doc so the trail is visible. The 1.5s debounce question and the non-USB-disambiguation question stay open; neither has signal yet.

**Scope-creep pruning.** Five v2 candidates that the user has now decided are out-of-product were dropped: per-profile wallpaper, Karabiner profile switching, Bluetooth pairing, VPN, and focus mode / Do Not Disturb. Two stay noted for v2: per-profile display arrangement and opt-in crash + error reporting. The dropped items are listed in the Resolved section so a future reader doesn't propose them again without checking.

**Persistent todo.** `tools/todo.md` was updated in lockstep: the Deferred refactors section was deleted entirely (all 5 items had real reasons-to-skip already on file in `tools/slop-plan-app-target.md`, and the natural moment to refactor came and went on PRs #79, #80, and #81 without anyone feeling the pull); the toast-cutdown work moved into Active.

**Hammerspoon-era cleanup.** The Validated decisions section had four prototype-era entries that no longer described the shipped Swift app: an `obs-cmd` shell-out justification, an "OBS scenes are the right unit of switching" bullet, a "Camo is not a viable alternative" bullet, and an "OBS Virtual Camera in Zoom/Slack" bullet. Plus stray Phase-1 references elsewhere ("no Lua" in the Target product list, "manual override" in the menu-bar UI line which contradicts the validated "No manual override" decision below it, "Audio Hijack-style aggregate device hacks" naming a third-party). All removed. The `obs-cmd` / OBS-scenes / Camo bullets were dropped outright (no replacement needed, they were Phase-1 integration choices that the v0.2.0 virtual camera made moot). The "Same as System + OBS Virtual Camera" bullet was reworded to point at the app's own virtual camera. Doc header at the top retitled from "settled before the Swift app was built" to "settled by the shipped implementation," which is the accurate framing now that v0.2.x has graduated.

- **When we ship a Phase 1 fix or feature**, ask: does this teach us
  something about the Swift port? If yes, add to "Lessons learned."
- **When the user gives feedback or hits a bug**, ask: should this be
  a feature in the Swift app? If yes, add to "Open questions" or
  "Scope creep candidates."
- **When we resolve an open question** (via real-world use or explicit
  user answer), move it from "Open questions" up to "Validated design
  decisions."
- **When we hit a Swift-specific design decision before we start Swift**
  (e.g., "should we use SwiftUI or AppKit for the preferences window?"),
  capture it under "Locked architectural choices" with the rationale.
- **Before starting Phase 2**, do a final pass through this doc to confirm
  every "open question" has been answered or explicitly deferred.

### v1 graduation criteria + two new v2 candidates (2026-05-09)

`docs/decisions.md` gained a "v1 graduation criteria" section so the bar for tagging `v1.0.0` is written down rather than implicit. Five "already met" bullets capture state today: virtual camera path battle-tested across PRs #79, #80, and #81; wizard validated on 2 external users; Save Logs for Support shipped (#78); Sparkle release flow stable across 15 v0.2.x releases; engine test coverage at 73-100% on pure logic. Three forward-looking gate items: 14-day soak with no critical-class bug PRs landing on `main` (clock starts 2026-05-09 since today shipped 3 visibility-race fixes); `tools/todo.md` Active section empty at tag time; author judgment as the actual trigger (no mechanical date).

The section also lists what was considered and explicitly *not* a v1 gate, with reasons: crash + error reporting (deferred to v2), app-target test coverage at engine parity (active fun work targeting 80% on non-UI files), live virtual-camera preview in Settings (v2), localization (v2), and external user count thresholds (chasing a number distracts from quality signal).

The Scope creep candidates list grew by two entries to keep the canonical list current: localization and the live virtual-camera preview in Settings → Camera. The latter is interesting because it doubles as a self-diagnostic (a user can see the feed without opening Zoom) and because the host process consuming its own virtual camera output is the same shape as the "self-source feedback loop on late consumer connect" bug class from 2026-05-05; that lesson is cross-referenced.

Doc-only PR; no code changes.

### Profile config auto-reload; Advanced menu loses two manual buttons (2026-05-10)

The menu bar's Advanced submenu had two affordances that pre-dated everything automatic in the engine: **Re-evaluate Now** (force the engine to re-check current USB state) and **Reload Config** (re-read `profiles.toml` and rebuild the engine). Re-thinking both:

- **Re-evaluate Now** was a legacy diagnostic. `IOKitUSBWatcher` doesn't realistically miss events in practice, and `engine.evaluate()` only re-applies when the resolved profile differs from current — so re-running with the same USB state is a no-op for an already-active profile (i.e. it can't fix "Zoom stole my audio default" the way users sometimes assume). The menu-bar pill already shows what the engine resolved to, so the "sanity check" use case is also handled. Removed cleanly, plus the `reevaluate()` method on `AppDelegate` it was the only caller of.

- **Reload Config** had one legitimate use case: a user hand-edits `profiles.toml` (or some sync tool writes to it) and wants the change picked up without quitting + relaunching. Narrow but real. Replaced with a `ProfileConfigWatcher` that uses `DispatchSource.makeFileSystemObjectSource` to watch the TOML for out-of-band changes. Now the user just edits the file and the engine reloads on its own.

The watcher's design notes:
- **Two kqueue sources** cover the editor-save matrix. The **parent-directory source** with mask `[.write]` fires on entry-list changes (create, rename, delete of children) — catches `String.write(atomically: true)`, TextEdit, and anything else that does the temp-file-then-rename dance. The **file-inode source** with mask `[.write, .extend, .attrib, .delete, .rename]` fires on content writes to the file itself — catches in-place writers like VS Code's default save on macOS, vim without `backupcopy=no`, and `sed -i`. Both sources are scheduled on `.main` and both feed a single 250 ms debounce timer, so a save that trips both (atomic rename also fires the file fd's `.rename`) still coalesces to one `onChange` call. Before firing, the debounce handler confirms the target file exists so a sibling-only event in the same directory with no target present is a no-op.
- **The dir-source owns the file-source's lifecycle.** After any directory event it stat-compares the path's current inode to the file fd's inode and rebinds when they differ. That removes the source-firing-order race that would otherwise leave the file source bound to an orphan inode after an atomic rename (and miss the next in-place edit). The original PR landed with a parent-dir-only design that missed in-place writes entirely; the hybrid was bolted on after end-to-end testing surfaced VS Code's default-save behavior.
- **`ConfigReloadGate` dedupes echoes**: `AppDelegate.handleConfigFileChanged` routes through a small value type that tracks the last-loaded mtime stamped by `bootEngine()`. If the file's current mtime is not strictly newer than the stamp, the watcher's callback is an echo of the app's own write and gets ignored. Without this, the wizard's force-apply flow (which sets `pendingForceApplyName` then drives a synchronous `reloadConfig()`) would get stomped by the watcher's 250 ms-later callback re-running the resolver against a cleared `pendingForceApplyName`. Extracting the gate into its own type let it grow direct test coverage (6 cases for echo / newer-mtime / vanished-file / re-stamp); previously the dedupe logic was inline in `AppDelegate` with no test reach.

Lifecycle: started in `applicationDidFinishLaunching` right after `bootEngine()` (the parent dir is bootstrapped by `ProfileBootstrapper` on first launch, so it's always present), stopped in `applicationWillTerminate`.

Tests: seven cases for `ProfileConfigWatcher` — fires on atomic-rename write, fires on in-place write (no rename), atomic-rename followed by in-place write fires both (proves the file source rebound to the new inode), debounces a burst into one callback, `stop()` halts subsequent callbacks even when the file changes, missing-file-at-start followed by file creation triggers a fire, and deleted-then-recreated triggers a fire. Each test runs in its own scratch subdirectory so unrelated activity in the system temp root can't trip the dir-watch and flake the assertions. Six cases for `ConfigReloadGate` cover the echo / newer / vanished / re-stamp matrix directly.

Net for the Advanced menu: two rows + a divider gone. Now it's just Check for Updates, Reveal Log in Console, Save Logs for Support. The diagnostic surface stays, the manual housekeeping buttons retire.

### Wizard remembers audio and camera devices across disconnects (2026-05-10)

The Add Profile wizard's audio and camera pickers only listed *currently-attached* devices, because `AudioController.availableDevices()` and `CameraController.availableCameras()` hit live CoreAudio / `AVCaptureDevice.DiscoverySession`. So a user sitting at their home desk couldn't swap the Conference Room profile's Yeti or external camera without first physically going back to the conference room. That's exactly the kind of friction the wizard was supposed to eliminate.

Three new caches landed on `SettingsStore`: `rememberedAudioInputs`, `rememberedAudioOutputs`, and `rememberedCameras`, each a `[String]` of display names. The wizard's `refresh()` now appends every live audio + camera device name *and* the editing profile's saved selections into those caches via a new `SettingsStore.rememberDevices(audioInputs:audioOutputs:cameras:)` method. Append-only, case-sensitive dedupe, never auto-prunes. The lazy-default-on-read pattern from existing fields is preserved: the init reads `(defaults.object(...) as? [String]) ?? []` and never writes a default back to disk, so the schema can keep evolving without locking in `[]` on millions of installs.

The pickers (`audioPicker` and the inlined `cameraPicker` in `AddProfileView`) now render two groups inside each `Picker`: currently-attached devices first (alphabetical, as CoreAudio returned them), then a remembered-but-disconnected group at the bottom, suffixed `"  (not connected)"`. No italics, no separators: a flat list inside `Picker` renders cleanly via `NSPopUpButton`, and the suffix is enough signal. A saved value that's somehow in *neither* list (hand-edited TOML, post-forget edit) is synthesized at the top of the disconnected group so the binding never breaks.

Three new computed properties on `AddProfileViewModel` expose the disconnected names to the view: `disconnectedInputNames`, `disconnectedOutputNames`, `disconnectedCameraNames`. Each is `remembered \ live`, alphabetically sorted. They return empty when no `SettingsStore` is injected, which keeps the bulk of the wizard's view-model tests untouched (the new feature gets covered by tests that explicitly pass a throwaway `SettingsStore(defaults: makeSuite())`).

Settings → General gained a "Remembered devices" section with a "Forget remembered devices…" destructive button, gated on a new `hasRememberedDevices` computed property so the section only appears when there's something to wipe. Mirrors the Stats tab's "Reset stats…" pattern, including the confirm-first alert. Wired through `SettingsStore.forgetRememberedDevices()`, which clears all three caches in one shot.

Dependency wiring: `AddProfileDependencies` gained a `settings: SettingsStore` field, populated from `AppDelegate.settings` in `addProfileDependencies()`, threaded through `WizardForm.init` into `AddProfileViewModel`. The view model param is optional with a `nil` default so legacy tests don't need updating, but production always passes the real store.

Tests: five new cases on `SettingsStoreTests` (defaults, append+dedupe, empty-name guard, persistence round-trip, forget wipes all, and an explicit check that the init pass doesn't write defaults to disk) plus five on `AddProfileViewModelTests` (refresh seeds live names, refresh seeds editing-profile saved selections when offline, disconnected lists surface remembered devices, empty when no store is injected, and the headline scenario: editing while offline keeps saved selections in the disconnected list). All 205 tests pass.

Follow-up after first manual pass: reviewed every `StatusPill` text and standardized them on proper case with no parens, using "Active" as the template ("Debug override", "Not connected", "Travels with you", "Important: Mic"/"Video"/"Audio"/"Speaker"). The (not connected) and lowercase-category variants were the outliers. The dropdown suffix in the audio/camera pickers keeps the inline `(not connected)` form because that's a different UI context — an inline parenthetical aside inside a Picker row, not a status badge. Same pass also stripped em dashes from every user-facing string in the Add/Edit Profile wizard per the project's no-em-dashes convention. Replaced with periods or sentence breaks. Wording adjusted in five strings: the "Pick anything human" name caption, the "Fallback profile" hint, both camera-section helper variants (virtual camera on / off), and the "is no longer in the config" error message. Also touched the starter-TOML header comment (`# AV Pain Reliever profile config.`) since users see it when they open the config file.

Second follow-up: sorted `availableProfiles` alphabetically by pretty name (case-insensitive, locale-aware via `localizedCaseInsensitiveCompare`) at the single load site in `AppDelegate.bootEngine()`. Both the Settings → Profiles tab and the menu bar's Switch to submenu read `availableProfiles` directly with no further sort, so one assignment fixes both surfaces. Previously the order was whatever Swift's Dictionary iteration produced from `ConfigLoader.toProfiles()`, which is hash-randomized per launch. Two profiles whose visible order shuffled between app restarts now stay put. Alphabetical-by-pretty-name (not slug) means "Café 2" sorts after "Café 1" the way a reader expects, even though slug rules might pick a different order. `ProfileResolver`'s internal tiebreak still sorts by slug, which is fine because that's an engine-internal deterministic order, not a user-facing one. Extracted the sort into `ProfileDisplayOrder.displayOrder(_:)` so it has tests covering mixed case, locale-aware accent handling, stable ties, empty input, and single-element input.

Third follow-up after the user spotted the data-loss risk: changed "Forget remembered devices" from a full wipe to "Forget unused devices" that preserves any name referenced by a saved profile's `audioInput` / `audioOutput` / `camera`. Reasoning: a user clicking Forget is asking to clean up history they no longer need, not to clobber names their profiles still depend on. Also corrected the stray "Add-Profile" hyphen in the helper text to "Add Profile" (the product name).

Fourth follow-up after the user reported confusion seeing cross-profile devices in a dropdown (Home Office's CalDigit appearing in Conference Room's mic picker). The fix: scope the remembered-devices cache per-profile instead of globally. Cache shape changes from `[String]` to `[String: [String]]` keyed by profile slug; `rememberDevices(forProfile: ..., ...)` appends to the editing profile's entry only; `disconnectedInputNames` / `disconnectedOutputNames` / `disconnectedCameraNames` read `cache[editingSlug]`, so each profile's dropdown shows only that profile's own history. When adding a new profile (no editing slug yet), the cache is bypassed entirely and the dropdowns fall back to live attached devices only; history builds up once the profile exists and is reopened. Forget is reshaped to take a `currentProfiles: [Profile]` list: each remembered profile's cache is trimmed to its current selections, and profile slugs absent from the list (deleted profiles) have their cache entry dropped entirely. Settings → General call site updated accordingly. Schema change is non-migrating: existing data under the old keys casts as the wrong type, falls back to `[:]`, and rebuilds itself from the user's next wizard refresh — the in-flight feature has ~3 known users so the data-loss exposure is trivial.

Fifth follow-up after manual testing exposed a related seed-from-live bug: the per-profile scoping prevented Home Office's CalDigit from being *read* into Conference Room's dropdown, but Conference Room's cache could still be *written* with CalDigit if the user happened to open Conference Room's wizard while CalDigit was attached at their home dock. The previous `refresh()` was seeding every live audio + camera name into the editing profile's cache. That made sense under the old global cache (every dropdown showed every device), but it's wrong under the per-profile model: a profile should only remember devices it has actually saved. Fix: refresh() now seeds the cache from `audioInput` / `audioOutput` / `camera` *only* (the editing profile's on-disk saved selections), never from the live device lists. Live devices still appear in the dropdown naturally via the live list, so the user can still pick one. Once they save and reopen, the new selection lands in the cache because it's then an on-disk saved value. Net: ~6 net new tests across both files. The headline `disconnectedNamesAreScopedPerProfile` covers the user-reported leakage scenario, `refreshSeedsCacheFromSavedSelectionsOnly` covers the seed-from-live regression, plus tests for refresh-when-adding, refresh-with-no-selections, forget-trim, forget-orphan, and forget-empty-selection-drops-entry.

Sixth follow-up on a related confusion the user spotted: the green "Important: <Cat>" pill in the wizard's USB section is keyword-driven (the device name contains "microphone"/"camera"/"audio"/etc.), so it fired for any currently-attached device that matches the keyword regardless of which profile was being edited. A user editing Conference Room from home would see CalDigit attached, labeled "Important: Audio" — a false claim about CalDigit's relevance to Conference Room. The pill was originally designed to explain why a device gets auto-ticked when *adding* a new profile, but auto-tick is disabled when editing, so the pill was making a contextual claim it couldn't back up. Fix: `AddProfileViewModel.shouldShowImportantPill(forDevice:)` gates the pill to two contexts where it makes sense — adding a new profile (auto-tick active) or editing while the device is already in this profile's fingerprint. Outside those contexts, the row falls through to a new quiet gray cross-reference pill via `otherProfileLabel(forDevice:)`: if the device IS in another saved profile's fingerprint, the row reads "In Home Office" (or "In N other profiles" for multi-claim hubs). So Conference Room's wizard now shows CalDigit as "In Home Office" rather than "Important: Audio" — telling the user what they're looking at instead of pretending it belongs here. Wired through a new `AddProfileDependencies.otherProfiles` field populated from `availableProfiles`. The view model defensively filters out the editing profile so a caller can naively pass every profile without inducing nonsense like "In Home Office" while editing Home Office. The "Travels with you" pill stays universal — portability is about device class, not profile context.

Seventh follow-up after the user tested and screenshotted two further issues: (1) opening Add Profile while at Home Office showed "In Office" cross-reference pills on Keychron + LG UltraFine, even though the user was just trying to capture the current location; (2) when editing a profile from a different location, the saved fingerprint devices were buried at the bottom of the device list (under the tier-sorted live attached devices), making the edit-from-elsewhere flow read more like an unrelated device dump. Two fixes shipped together. **Cross-reference pill, scoped to edit only:** `otherProfileLabel(forDevice:)` now returns nil when `!editingExisting`, so the Add Profile flow shows no "In <other profile>" labels at all. Adding is about capturing what's plugged in, not investigating relationships with existing profiles. **Edit-mode device order, fingerprint-first:** `refresh()` now sorts attachedDevices as `[live & in fingerprint] + [disconnected, all in fingerprint] + [live & out of fingerprint]`, with tier sort applied within each group. When editing Conference Room from home, the saved fingerprint anchors the top of the list (live where possible, "Not connected" otherwise) and any unticked attached devices appear below as candidates to add. When adding, savedFingerprint is empty so the expression collapses to a plain tier-sorted live snapshot — the existing behavior. Three new tests: `otherProfileLabelNilWhenAdding`, `editingFloatsFingerprintToTop`, and `addingUsesTierSort` (regression guard for the existing add-mode order).

Ninth follow-up, post slop-review pass: the four-lens slop reviewer caught a real correctness gap. `SettingsStore.forgetProfile(slug:)` and `reconcileProfiles(currentSlugs:)` cleaned up `perProfileCounts` + `lastSwitchSlug` for deleted/orphaned profiles but missed the three new `rememberedAudio*/Cameras` dicts. And the wizard's rename path (`AddProfileViewModel.performSave` when `slug != editingSlug`) deleted the old TOML section but left the cache entry orphaned under the prior slug, so a rename silently dropped the profile's remembered-devices history. Fixed by extending `forgetProfile` to clear the three caches, extending `reconcileProfiles` to prune cache orphans, and introducing `SettingsStore.renameProfile(from:to:)` that migrates `perProfileCounts` + `lastSwitchSlug` + all three caches to the new slug. `performSave` now picks based on save mode: `.append` (regular rename or "Save as new" collision continuation) calls `renameProfile` so history follows; `.replace` ("Update existing" collision continuation) calls `forgetProfile` so the editing profile's side data is dropped before merging into the target. Also addressed the smaller slop-review hits: stripped 14 em dashes from new comments to match the project's no-em-dashes policy (the cleanup ran on user-facing strings but missed comments); fixed the doc on `AddProfileDependencies.otherProfiles` (caller passes the full list, the wizard filters internally — the doc had the contract backwards); fixed the doc on `SettingsStore.appendingNew` + `rememberDevices` (the docs claimed UserDefaults writes were skipped on no-op refreshes, but the caller was unconditionally assigning; added the equality guards so the claims hold); fixed the vacuous `otherProfileLabelNilWhenNoMatch` test that was passing via the `editingExisting` guard instead of the asserted no-match branch; dropped two redundant absence assertions in `disconnectedNamesAreScopedPerProfile` (the set-equality assertions on the same lists made the `!contains(...)` checks logically dead). Six new SettingsStore tests cover the cache-cleanup paths (`forgetProfileClearsRememberedDeviceCaches`, `forgetProfileSpared`, `reconcileProfilesDropsCacheOrphans`, `renameProfileMovesAllPerSlugState`, `renameProfileNoOpForSameSlug`, `renameProfileLeavesUnrelatedLastSwitchAlone`); three new wizard journey tests cover the end-to-end flows (`renameMigratesRememberedDevicesCache`, `updateExistingSubsumesEditingCache`, `deleteProfileClearsCacheJourney`).

Eighth follow-up after the user spotted a latent ambiguity: nothing stopped a user from saving two profiles with identical USB fingerprints (different names). `ProfileWriter` only blocks slug clashes; the resolver tiebreaks identical-specificity matches alphabetically, so a user could end up with a profile that visually exists but never auto-applies because its alphabetical sibling always wins. The save-time `forceApplySlug` pin masks the problem in the same session, but on next launch the demotion shows up. Fix: a new soft-warning dialog at save time. Pause path: `performSave` runs a fingerprint-conflict check (set-equality against every other saved profile's fingerprint, with the editing profile already filtered out by the `otherProfiles` plumbing). If `conflictingProfile(forFingerprint:)` returns a match, stash the save context and surface `PendingFingerprintWarning` instead of writing. The view's alert reads "Same fingerprint as <Other Profile>" with body explaining the alphabetical-tiebreak consequence and two buttons: Save Anyway (calls `confirmFingerprintWarning()`, which resumes the save with `bypassFingerprintCheck: true`) and Cancel (calls `cancelFingerprintWarning()`, drops the warning, leaves the form untouched). The collision-dialog continuations (`confirmReplace` / `confirmSaveAsNew`) bypass this check because they're explicit duplication choices that just passed through a different dialog. Two-empty-fingerprints (the "second fallback" case) also triggers the warning since identical empty sets resolve to the same alphabetical tiebreak. Eight new tests: `conflictingProfileNilWhenNoMatch`, `conflictingProfileReturnsMatch`, `conflictingProfileTwoFallbacksCollide`, `conflictingProfileExcludesEditingProfile`, `saveWithConflictingFingerprintSurfacesWarning` (no write, no callback, dialog up), `confirmFingerprintWarningProceedsWithSave` (full round-trip through the bypass flag), `cancelFingerprintWarningDoesNotSave` (file untouched), and `saveAsNewBypassesFingerprintWarning` (regression guard for the bypass on name-collision continuations).

### README tightening: drop tagline, remove em dashes, less polished voice (2026-05-10)

The README read as slightly AI-shaped: heavy em-dash use for parenthetical asides, a too-tidy descriptive tagline under the hero image, polished but slightly hollow phrasings in the intro. User feedback on 2026-05-10: *"Make it sound less like AI wrote it. You're wonderful but I want more of a human touch here."*

Three passes through the file:

1. **Removed the descriptive blockquote tagline.** ("Auto-switch your microphone, speakers, and camera when you change desks.") The hero image's alt attribute and the body paragraph below it carry the same information without the duplication.
2. **Removed every em dash.** Replaced with periods, commas, parens, or colons depending on the grammatical role each one was filling. Bullet definitions like `**Switch to** — manually apply…` became `**Switch to**: manually apply…`. Aside-style em dashes around lists (`Some apps — Zoom, Slack, Teams — keep…`) became parens. The hero image's alt text (`AV Pain Reliever — Your laptop knows where it is.`) became `AV Pain Reliever. Your laptop knows where it is.`
3. **Loosened the intro paragraph.** Original: *"When you carry a MacBook between locations — your home office, a work desk, a conference room, a café — your audio defaults usually need fixing every time."* Now reads in shorter, choppier sentences with the location list broken into its own beat: *"You carry your MacBook to a few different desks during the week. Home office, work desk, conference room, café. Each one has a different microphone, different speakers, maybe a different camera. The audio is wrong until you fix it."* Same information, more conversational rhythm.

Navigation arrows (`→`) were left alone. They're a different character and serve a different purpose (path separators, e.g., `Settings… → Camera`).

### README hero image replaces the H1 title (2026-05-10)

The README opened with a plain `# AV Pain Reliever` H1. Now that the repo has a real social-preview card uploaded under Settings → General → Social preview (the "story" layout: USB → speaker → camera, white background, "Your laptop knows where it is."), the same image carries the title role at the top of the README too — visual continuity with what users see on GitHub unfurls.

Dropped the H1, added a centered image embed pointing at `docs/og-card.png`. The image is capped at 800px on desktop via the `width` attribute and scales down naturally on mobile. Kept the descriptive blockquote tagline ("Auto-switch your microphone, speakers, and camera when you change desks.") in markdown below the image so search indexers and screen readers still see a concrete description even if the image fails to load; the image's `alt` carries the title and vibe-tagline for accessibility.

The PNG was generated by a one-off script at `tools/generate-og-cards.swift` (gitignored, not project code) that mirrors the `AppIcon.swift` drawing recipe. The chosen output was copied into `docs/og-card.png` for the README to reference. The other rendered candidates and the script itself stay out of the repo by design — they're scaffolding for the design choice, not code that has lasting value.

### Issue templates tailored to the project (2026-05-09)

The boilerplate `bug_report.md` / `feature_request.md` that landed earlier today were GitHub's defaults: half the fields didn't fit a macOS utility (browser, smartphone) and the load-bearing fields for *this* project (app version, release channel, macOS version, Save Logs attachment) weren't there. Replaced with structured YAML issue forms that bake in the right questions and validate the required ones.

**Bug report (`bug_report.yml`).** Required fields: what happened, steps to reproduce, app version, release channel (dropdown: Stable / Dev / Experimental / both), macOS version. Optional fields: USB hardware involved, active profile, logs (with explicit instructions to use **Advanced → Save Logs for Support…** and drag the file onto the textarea), additional context. Auto-labeled `bug`, title prefixed `[Bug]`. The dropdown for release channel is the structural win, since most reports skipped that field with the prose template.

**Feature request (`feature_request.yml`).** Required fields: problem, proposed solution. Optional: alternatives considered, additional context. The intro text points users at `docs/decisions.md`'s scope-creep candidates so duplicates of already-considered ideas land as comments on existing items, and notes that third-party-integration suggestions are usually out of scope per the self-contained product principle. Auto-labeled `enhancement`, title prefixed `[Feature]`.

**`config.yml`.** Disables blank issues (forces a template) and adds a single contact link pointing at the new Discussions tab for general questions, so "how do I…" traffic lands there instead of in Issues.

### Add a third Sparkle release channel: dev (2026-05-09)

The release flow grew from two channels (stable + experimental) to three (stable + dev + experimental). Project convention for what goes where: stable carries normal-sized features and bug fixes for everyone, dev carries small in-flight features (ships more often than stable, low-risk per change), experimental carries moonshot work that may break things. Dev and experimental are independent toggles in Settings, not points on a single stability axis, so the user can opt in to either, both, or neither.

**Settings UI.** Settings → General → Updates gained a second toggle: "Receive dev updates" alongside the existing "Receive experimental updates," each with its own caption. Listed dev first since it's the lower-risk opt-in. Both default off.

**SettingsStore.** New `devUpdates: Bool` mirrors `experimentalUpdates` exactly (same lazy-default pattern, same `didSet` write). No migration needed; new key, additive.

**ChannelGatingDelegate.** `allowedChannels(for:)` now returns a `Set<String>` constructed from both bools: `dev` if `devUpdates`, `experimental` if `experimentalUpdates`. Sparkle treats the returned set as a union, so a user with both flipped on sees the union of stable + dev + experimental. Updater also gained a Combine subscriber for `$devUpdates` matching the existing `$experimentalUpdates` one, plus `.notice` log lines on each toggle change so the toggle-driven re-check is visible in the app's own log stream (Sparkle's internal background-check logs go to its own subsystem, not ours).

**Workflow.** `appcast-publish.yml`'s tag-suffix dispatch grew a `*-dev*) export CHANNEL=dev ;;` arm before the experimental one. `release.yml` doesn't touch channels anymore (decoupled in #84), so no changes there. `scripts/sign-appcast.sh` already accepts any `$CHANNEL` value and emits `<sparkle:channel>$CHANNEL</sparkle:channel>`, so the script needs no edit.

**Known follow-up** (not in this PR): the pre-check intercept in `Updater.checkForUpdates()` uses `isExperimentalVersion(_:)` to detect a running experimental version and nudge the user to enable the toggle. That heuristic was already stale after the 2026-05-05 graduation (it infers channel from major/minor numbers, but the rule flipped to tag-suffix dispatch). Adding "dev" doesn't make it more wrong; it's the same gap. The clean fix is to bake the channel into the build at release time (a new `SUChannel` key in `Info.plist` set by the workflow based on tag suffix) and have the intercept compare bundled vs. enabled channels. Out of scope for this PR.

### Confetti: bigger pop, slower fall (2026-05-09)

Tuned `ConfettiBurst` to feel less rushed. The launch power range bumped from `200...420` to `280...520` (~30% more reach, so the apex is higher and the spread wider). The per-particle fall duration went from `1.4...2.2`s to `2.2...3.4`s (~55% slower descent). The `oneShotConfetti` cleanup timer moved from 3.2s to 4.5s to cover the longer trajectory and updated the doc comment to match. No structural changes; same `KeyframeAnimator` driving the same trajectory shape, just different numbers.

### Trim chrome on Sparkle's update-available window (2026-05-09)

The Sparkle "Update Available" window shipped with the full traffic-light set (close + minimize + zoom). For a transient utility dialog those extra two buttons read as wrong; a software-update prompt isn't something you'd want to minimize or maximize. Extended the existing Sparkle-window detector in `Updater.swift` (formerly `installWindowTitleObserver`, renamed to `installSparkleWindowCustomizer` to reflect the wider scope) to also remove `.miniaturizable` and `.resizable` from the window's `styleMask` and disable the standard miniaturize and zoom buttons. Matches the project pattern in `WindowChrome.applyDialogChrome` (greyed-out rather than hidden, the macOS-idiomatic way to indicate "this window doesn't do that"). Idempotent on every `didBecomeKeyNotification` for a Sparkle window, same as the title-set behavior it sits next to.

### Decouple appcast publish from tag push (2026-05-09)

Moved the appcast `<item>` insertion out of `release.yml` into a new `appcast-publish.yml` workflow that triggers on `release: published`. The old flow auto-spliced the appcast item the moment a tag landed, using GitHub's auto-generated PR list as the description. That meant the in-app "Check for Updates" panel showed users a wall of PR titles instead of the polished Vince Vaughn voice that was meant for `appcast.xml`. By the time the maintainer edited the draft release body into the right voice and clicked Publish, the appcast had already shipped to users with the wrong content.

New flow: `release.yml` builds, signs, notarizes, and creates the draft release with the .app.zip asset; nothing touches `appcast.xml`. After the maintainer edits the draft notes and clicks Publish, `appcast-publish.yml` runs on the same self-hosted runner, pulls the published body via `gh release view`, renders it through GitHub's `/markdown` API (same renderer the release page uses, so the in-app HTML matches what users see on the release page), re-signs the appcast item with the EdDSA private key via `scripts/sign-appcast.sh`, and upserts it into `appcast.xml` on `main`. Releases are now deliberate by construction, the version isn't visible to auto-updating users until the maintainer signals "I'm ready" by clicking Publish.

The upsert logic is awk over `appcast.xml`: buffer each `<item>...</item>` block, check whether `<sparkle:version>$VERSION</sparkle:version>` is inside the buffer, replace if found and splice before `</channel>` if not. Tested locally against the live `appcast.xml`: replacing v0.2.0.16's existing item kept the count at 36; splicing a fictional v9.9.9 item bumped the count to 37 and preserved the channel/RSS closing tags. Channel-suffix dispatch (`-experimental.N` → experimental channel, bare tag → stable) moved to the new workflow unchanged. Dryrun tags (`*dryrun*`) skip appcast publishing entirely, same as before.

Side benefit: `appcast.xml` updates can no longer race the maintainer's editing window. Two callers, one source of truth (the published release body), and the GitHub Release page and the Sparkle update panel will always agree.

CI-only PR; no app code changes.

## V1 design pass (2026-05-01)

The functional engine + wizard was complete (94 tests, end-to-end
working) before this pass. The brief: take the app from "trustworthy
native utility that works" to "trustworthy native utility you'd want
on your machine." Raycast-clean SwiftUI defaults with brand-color
pops, warm copy, a few moments of tasteful delight.

### What shipped

**Brand foundation**

- `Theme` namespace owns the locked palette (magenta `#FF87D7` primary,
  cyan `#00FFFF` highlight, success/warn/error/chrome) plus standard
  SF Symbols (`pills.fill` app icon, `tag.fill` / `cable.connector` /
  `speaker.wave.2.fill` / `camera.fill` for wizard sections). Views
  never hard-code hex values — a future palette tweak (or a real
  dark-mode override) is one file.
- `ProfileIcon` maps slugs → SF Symbols with prefix/contains
  heuristics. `home*` → `house.fill`, `work*`/`office` →
  `building.2.fill`, `conference`/`meeting` → `person.3.fill`,
  `studio`/`podcast` → `music.mic`, `cafe`/`coffee` →
  `cup.and.saucer.fill`, plus `library`, `garage`, `lab`, `hotel`,
  `school`. Unknown slugs fall through to `mappin.and.ellipse`.
  Specificity ordering matters: `conference-home` lands on people
  before house, `home-office` lands on house before building (the
  more-specific predicate runs first).

**Wizard polish**

- Hero header: pill icon + magenta title + cyan subhead.
- Section headers carry SF Symbol icons in primary magenta.
- Save button is brand-magenta primary with a brief green-checkmark
  "Saved" affordance for ~0.45 s before the window closes — the
  smoother feedback the brief asked for.
- Auto-suggest profile name from attached devices: a CalDigit dock
  pre-fills "Home Office", an LG monitor pre-fills "Office", a
  Yeti/Shure mic pre-fills "Studio". Suggestion only, fully editable.
  No-op when editing an existing profile.

**Menu enrichment**

- Each profile in the "Switch to" submenu shows its slug-mapped SF
  Symbol next to the name (or a checkmark when active).
- Each profile is itself a sub-submenu with Switch to / Edit… /
  Delete… entries. Right-click contextMenu would be cleaner but
  SwiftUI's `MenuBarExtra` doesn't propagate it to its child entries
  in the macOS 14 SDK; the sub-submenu chain achieves the same
  affordance.
- Optional one-line caption per profile shows the audio + camera
  it would apply (`🎙 Yeti  •  🔈 CalDigit  •  📷 Built-in`), gated
  by Settings → "Show audio + camera details in menu".
- Settings… (⌘,) and About AV Pain Reliever menu items added below
  the existing admin block.

**Notification copy with personality**

- `NotificationCopy.title(forSlug:)` rotates 2-4 alternates per
  common slug family. Selection is deterministic on day-of-year so
  the title varies between days but doesn't whiplash within a single
  docking cycle. Body is constant: "Audio + camera switched".
- Notifications are now gated by Settings → "Send notifications when
  profiles change" (default on).

**Settings scene** (`Settings { }`, opens with ⌘,)

- General tab: notifications toggle, audio+camera-in-menu toggle,
  debounce-window slider (0.5–5.0 s, default 1.5 s — engine rebuilds
  with the new value on next reload).
- Profiles tab: full list with magenta-tinted icons, "Active" pill
  on the resolved profile, Edit and Delete buttons per row. Empty
  state has a friendly tray icon + warm copy.
- Deliberately no mention of Hammerspoon, OBS, or any third-party
  tool. Per `feedback_app_self_contained`.

**About window**

- Replaces `NSApp.orderFrontStandardAboutPanel` with a SwiftUI scene:
  pulsing pill hero in magenta, title in big rounded magenta type,
  cyan tagline, version string, "Made to stop the fiddling" italic
  line.

**First-run welcome**

- Shown when no profile has a real fingerprint AND the user hasn't
  previously dismissed the welcome. Hero pill, magenta title, cyan
  tagline, warm one-paragraph explainer, magenta "Add Your First
  Location" CTA, cyan "Skip — I'll set up later" link. Suppressed
  forever once either button is clicked or any profile saves.
- Implemented as a SwiftUI `Window` scene whose visibility is
  triggered by an `@Published shouldShowWelcome` flag on
  `AppDelegate` — read by a hidden `WelcomeOpener` view inside the
  `MenuBarExtra` so it can call SwiftUI's `openWindow` (which is
  environment-only and not reachable from `AppDelegate` directly).

**Edit + delete plumbing**

- `ProfileWriter.delete(named:in:)` excises a `[profiles.<name>]`
  section while preserving surrounding content, comments, and
  header banners. Tidies trailing blank lines.
- `AddProfileViewModel` takes an optional `editing: Profile?` —
  pre-fills name (pretty-cased), audio, camera, and the selected
  fingerprint. Save dispatches to replace mode when the slug is
  unchanged; renaming during edit cleans up the prior section
  automatically.
- Native `NSAlert` confirms before delete.

**Persistent settings**

- `SettingsStore` (`UserDefaults`-backed): notificationsEnabled,
  debounceInterval, showAudioCameraInMenu, profileSwitchCount,
  suppressedWelcome. Defaults treat `object(forKey:) == nil` as
  "never set" so default-on toggles stay on across launches.
- `AppDelegate` republishes `settings.objectWillChange` through its
  own `objectWillChange` so views observing the AppDelegate (the
  menu, the About scene) re-render on a settings flip without each
  having to observe the store directly.

**Easter egg**

- Hold Option while the menu is open to reveal a cyan stats line
  under the title: "Switched 47 times. Saving your sanity since
  plug-in #1." Bumped from every actual profile change. Pluralizes
  correctly at counts 0/1/2+.

### Lessons learned

- **`MenuBarExtra` doesn't propagate `contextMenu(for:)` to its
  child Buttons.** Right-click on a profile entry in the "Switch to"
  submenu doesn't surface anything. Workaround: nest each profile
  inside its own `Menu` so Switch / Edit / Delete read as a sub-
  submenu. Discoverability is slightly worse than right-click but
  the affordance survives. Re-evaluate when SwiftUI's MenuBar APIs
  pick up `contextMenu` support (FB-pending).
- **`@MainActor`-isolating `SettingsStore` blocks the AppDelegate
  from reading from non-main contexts.** `buildEngine` is called from
  `bootEngine`, which the docs reach but which isn't yet `@MainActor`
  itself; rather than annotate the entire AppDelegate, drop the
  isolation from `SettingsStore` (`UserDefaults` is thread-safe and
  the `@Published` mutations in the wizard happen from main anyway).
  Same trick applies to any future small persistence helper.
- **Republishing one ObservableObject through another is one line
  of Combine.** `settings.objectWillChange.sink { [weak self] in
  self?.objectWillChange.send() }.store(in: &cancellables)` lets the
  SwiftUI graph treat AppDelegate as the canonical source for both
  engine state AND user preferences. Saves passing `SettingsStore`
  into every view via `@ObservedObject`.
- **First-run welcome can't open a window from the AppDelegate.**
  SwiftUI's `openWindow` is environment-only; AppDelegate has no
  `EnvironmentValues`. Workaround: AppDelegate publishes
  `shouldShowWelcome: Bool`, and a hidden helper view inside the
  `MenuBarExtra` scene watches it via `.onChange` and calls
  `openWindow` from its own environment. Clean, no AppKit cycling.
- **A pure-logic test target for the App module is worth it.**
  ProfileIcon, NotificationCopy, StatsCopy, SettingsStore, and the
  AddProfileViewModel are all unit-testable without AppKit. SPM's
  `executableTarget` can be `@testable`-imported by a sibling
  `testTarget` — no Xcode project required for coverage.
- **Save-success feedback wants 0.45 s, not 0.2 s and not 1.0 s.**
  At 0.2 s the green flash is gone before the eye registers. At 1.0 s
  the modal feels sluggish. 0.45 s reads as a confirmed beat without
  blocking flow.

### Effort estimate update

The pass touched ~1500 lines across 8 new files + 5 modified files,
plus 36 new tests. ~3 hours actual against an open-ended brief. Most
of that was the Settings + About + Welcome scenes (each is ~80–150
lines). The pure-logic helpers (ProfileIcon, NotificationCopy,
StatsCopy) took minutes each because the surface is a single function
+ a small mapping table.

### Deferred to v2

- ~~Custom app icon~~ — runtime-generated icon shipped in the polish
  pass below. Asset Catalog version still pending for the signed
  `.app`.
- User-customizable per-profile icons (auto from slug for v1).
- OBS scene routing as a Settings tab.
- ~~Sparkle / signing / GitHub Actions release pipeline~~ — landed
  2026-05-02 (see "Distribution pipeline kickoff" below); appcast
  hosted on raw.githubusercontent.com.
- "Show Welcome Again" menu/affordance — easy to add later if
  someone asks.

---

## V1 polish pass (2026-05-01)

A second design pass on the same day, focused on fit-and-finish and
on fixing one regression I'd shipped in the V1 design pass. Five
buckets:

### Menu UX restoration

The V1 design pass had wrapped each profile in the "Switch to"
submenu in its own sub-submenu (Switch / Edit / Delete) — three
clicks to switch, vs. the pre-V1 menu's one click. Restored to a
flat menu: each profile is a `Button` that applies on click; Edit
and Delete already live in Settings → Profiles.

The per-profile summary line ("🎙 Yeti  •  🔈 CalDigit  •
📷 Built-in") is now inlined onto the same row as the name. AppKit's
Menu renderer flattens VStack labels to just the first line in
`MenuBarExtra` menus, so the previous multi-line layout never
showed the summary in the actual menu — only in SwiftUI previews.

### Unknown-location state

`AppDelegate` carries two new published flags (`atUnknownLocation`,
`lastUnknownDevices`), set when `Engine.onUnknownLocation` fires
(empty-fingerprint resolution + non-empty attached set). Both reset
the moment the engine resolves to a real-fingerprint profile.

Visible effect: when fallback fires with USB attached, the menu-bar
label switches to a `questionmark.circle` icon + "New location" text;
the menu header reads "New location detected — N USB devices
attached"; a magenta "Set Up This Location…" CTA opens the wizard
with all attached devices already pre-selected (the wizard already
did this; the CTA is just a more discoverable entry point).

Without this, the user docking somewhere new sees the menu bar say
"Laptop" and assumes the engine missed the USB event. The status
toast already told them "new location" but a transient banner
isn't enough — the menu has to keep telling the truth.

### App icon (runtime-generated)

`AppIcon.makeIcon()` renders a 1024×1024 squircle with a
magenta→deep-magenta→cyan radial gradient and a white `pills.fill`
SF Symbol on top with a soft shadow. Wired at launch via
`NSApp.applicationIconImage` and reused by the About + Welcome
heroes (rounded-rect-clipped at 96/104 px).

The white-symbol-on-gradient trick uses `.destinationIn` compositing:
fill a fresh image with white, then `destinationIn`-clip by the
template SF Symbol's alpha mask. The result is a real white-filled
symbol image that draws cleanly onto the gradient. SwiftUI's
`Image(systemName:).foregroundStyle(.white)` doesn't help here
because we need an `NSImage` to composite into the AppKit graphics
context, not a SwiftUI view.

Generated in memory rather than shipped as a `.icns` so palette
tweaks don't need a regenerated Asset Catalog. The signed `.app`
will eventually carry a proper Asset Catalog AppIcon for higher-
fidelity rendering at 16/32/64-pt sizes; the runtime icon covers
the dev workflow without an Xcode project.

### Launch at Login

New `SettingsStore.launchAtLogin` (default off — fresh users opt
in, per macOS background-task etiquette). `LaunchAtLogin.apply(
enabled:)` wraps `SMAppService.mainApp.register()` /
`unregister()`. AppDelegate calls apply() on launch so a setting
toggled in a previous session takes effect.

Caveat: `SMAppService` needs a properly bundled `.app` for clean
registration. The SPM dev binary will see `register()` throw — the
helper logs and continues so the toggle stays usable in Settings;
once the signed `.app` ships, the same code starts working with no
app-side changes. This is the same SPM-dev-vs-signed-bundle
shimming pattern as `Notifier` (AppleScriptNotifier vs the eventual
UNUserNotificationCenter wrapper).

### Theme adaptive colors

The locked palette (`#FF87D7` magenta, `#00FFFF` cyan, `#00FF00`
green, `#FF0000` red) is tuned for dark backgrounds — mirrors the
Hammerspoon TUI which assumes a dark terminal, and the menu-bar
agent's most common surfaces (the menu, dark-mode windows) are
dark. On light-mode forms the canonical hex codes washed out:
`#00FFFF` cyan on white is unreadable as link text.

`Theme.Color.{primary,highlight,success,error}` now return adaptive
colors via an `NSColor` dynamic provider. The canonical hex codes
are preserved as the dark-mode value; a darker, more saturated
cousin handles light mode. The brand-pop intent stays — the user
can't tell from glancing at either appearance that anything's
adaptive, but light-mode contrast is now WCAG-respectable.

This respects the spirit of the locked palette (the brand color in
the surface that matters most — the menu, dark-mode windows — is
exactly the canonical hex) while fixing a real accessibility
concern. Documented prominently in the file's doc comment so a
future palette tweak goes through both variants.

### Lessons learned

- **`MenuBarExtra` collapses multi-line VStack labels to one line.**
  AppKit's menu renderer pulls the first line out of a VStack and
  drops the rest. Looks fine in SwiftUI previews; ships broken in
  the actual menu. Inline summary text is the only reliable way to
  add a sub-line to a menu entry.
- **SF Symbols are template images; `.foregroundStyle(.white)` /
  `setFill()` doesn't tint them when drawing into an AppKit context.**
  Use `.destinationIn` compositing (fill white → clip by symbol
  mask) to get a real white-filled image you can composite. Pattern
  generalizes to any tint of any SF Symbol when drawing into a CG
  context.
- **`SMAppService.mainApp` needs a real bundle.** The SPM dev binary
  fails the registration silently (or throws). Wrap the call so
  failures log + return — the user toggling Settings during dev
  doesn't crash anything, and the same code starts working once
  the signed `.app` ships. Same pattern we used for the
  AppleScriptNotifier dev-vs-bundle shim.
- **The locked palette needed light-mode variants for
  accessibility.** Pure cyan and pure green are unreadable on
  white. Adaptive colors via `NSColor(name:dynamicProvider:)` keep
  the dark-mode brand intact and let light-mode breathe — same
  pattern Apple uses for system colors. Honor the canonical hex
  in the appearance that matters most (dark, where the menu lives
  most of the time) and tweak the cousin for light.
- **Keyboard shortcuts in SwiftUI menus are global to the menu's
  scope.** Two `Button(...)`s with `.keyboardShortcut("n")` in the
  same menu silently breaks both. Surface a generic "Add Profile…"
  shortcut on one entry, leave the visually-prominent CTAs without
  a shortcut.

### Effort estimate update

Polish pass: ~1.5 hours, 2 new files + 8 modified files, +1 test
(menu state changes are easier to verify by smoke-launch than to
unit-test against AppKit). Total polish + design pass over the same
day: ~4.5 hours, 35+ tests added.

### Deferred to v2 (after polish)

- ~~Asset-Catalog AppIcon for the signed `.app`~~ — replaced 2026-05-02
  with a `Resources/AppIcon.icns` rendered from `AppIcon.swift`'s
  pill via `scripts/build-icon.sh`. No Asset Catalog needed.
- User-customizable per-profile icons.
- OBS scene routing as a Settings tab.
- ~~Sparkle / signing / GitHub Actions release pipeline~~ — landed
  2026-05-02.
- ~~"Show Welcome Again" affordance~~ — shipped in the fit & finish
  pass below.
- Right-click context menu on profile rows — would let us put
  Edit/Delete back on the menu without losing the one-click
  switch. SwiftUI MenuBarExtra doesn't support `contextMenu`
  propagation in macOS 14; revisit when SDK support lands.

---

## V1 fit & finish (2026-05-01 — third pass same day)

A short third pass focused on individual rough edges spotted on
the polished build. Three buckets, each landed in its own commit.

### Wizard: live profile-icon preview

The Name section now renders the SF Symbol the menu would use
for the typed slug, live, with a short crossfade. Surfaces the
"each location gets its own icon" feature visually and tells the
user what their slug matched on without forcing them to save +
inspect the menu. `AddProfileViewModel.previewSlug` exposes the
slug used for the icon; falls back to a generic placeholder slug
while the field is empty so the icon doesn't flicker on every
keystroke at the start.

### Wizard: "Suggested: untick" portability badges

`DevicePortability.portabilityCategory(deviceName:)` classifies
attached USB devices by name into "this almost certainly travels
with you" categories — keyboards, pointing devices, phones /
wearables, headphones, watches. The fingerprint list now shows a
yellow capsule "Suggested: untick (<category>)" on flagged rows.

Conservative on purpose — when in doubt, don't flag, because a
wrong-positive (silently dropping an actually-fingerprintable
peripheral) is worse than a missed flag (the user spends two
seconds unticking three rows manually). Auto-untick was
considered and rejected for the same reason.

### Warmer toast copy

The "new location detected" toast body switched from
> 5 USB devices attached. Add it to your profiles so AV Pain
> Reliever can switch automatically.

to
> 5 USB devices joined the party. Open the menu to teach me
> this spot.

Same information, half the words, voice consistent with the rest
of the app. Pulled into a public testable helper at
`NotificationCopy.unknownLocationBody(deviceCount:)`.

### Profiles tab empty state

`Settings → Profiles` previously rendered a generic SF tray icon
+ small caption when no profiles existed. Replaced with an
inviting empty-state hero: rounded-rect-clipped app icon with a
soft shadow, magenta "Set up your first location" headline, a
sentence of explainer copy, and a large magenta "Add Profile" CTA.
The empty state now reads as part of the product, not as a
placeholder.

### Show Welcome Again

The first-run welcome window is suppressed forever after the user
clicks either button. The About scene now carries a small "Show
welcome again" link below the explainer copy that flips the
published flag, dismisses About, and re-opens the welcome via the
existing `WelcomeOpener` watcher. `AppDelegate.showWelcomeAgain()`
toggles `shouldShowWelcome` false→true across runloop turns so
the `.onChange` watcher fires even if the flag was already true.

### Wizard error banner

`viewModel.lastError` previously rendered as a single line of
`.foregroundStyle(.red)` text. Now wrapped in a proper banner:
triangle warning icon, error-tinted background + border, padded
rounded rectangle, opacity+slide transition on appear. Same
information, much higher signal — the user can't miss it.

### Lessons learned

- **`MenuBarExtra` activated views can take an `@ObservedObject`
  AppDelegate** even when the AppDelegate's own properties
  changed via Combine republishing. The dependency tracking
  picks up the republished signal without complaint. This is
  what made `Show Welcome Again` work — a Settings change
  observed in the menu's stats line + an About-scene
  callback driving an AppDelegate published property all
  flow through the same single observation.
- **NSImage rounded-rect clipping inside SwiftUI doesn't need
  an `Image(uiImage:)`-style hack on macOS** — `Image(nsImage:
  AppIcon.image).resizable().clipShape(RoundedRectangle(...))`
  works directly. The signed `.app`'s Asset Catalog icon will
  still be sharper at small render sizes, but the runtime icon
  composites cleanly enough at 76+ pt.
- **Conservative classification beats aggressive defaults.** The
  Wizard's "Suggested: untick" hint is on portable devices only
  — auto-unticking would silently drop an ergonomic-keyboard
  fingerprint the user actually wanted, and that failure
  (silent data loss in a config workflow) is irrecoverable
  without re-discovery. The badge surfaces the suggestion;
  the user remains in control of every checkbox.

### Effort estimate update

Fit & finish pass: ~1 hour, 1 new file + 8 modified files,
+9 tests (140 total). Combined day-of-2026-05-01 design + polish
+ fit & finish: ~5 hours actual, 45+ tests added across three
commits' worth of UI/UX work plus the supporting library + app
helpers. The tests bias is intentional — every pure-logic
helper (Theme adaptation aside) gets a `testTarget` rather than
relying on visual smoke tests, since smoke tests can't gate CI.

### Deferred (still on the v2 list)

- ~~Asset-Catalog AppIcon for the signed `.app`~~ — superseded by
  `scripts/build-icon.sh` rendering the pill into `.icns` (2026-05-02).
- User-customizable per-profile icons.
- OBS scene routing as a Settings tab.
- ~~Sparkle / signing / GitHub Actions release pipeline~~ — landed
  2026-05-02 (Distribution pipeline kickoff section below).
- Right-click context menu on profile rows.
- Notification-action support ("Open Wizard" button on the
  unknown-location toast). Needs UNUserNotificationCenter, which
  ~~needs a real bundle~~ becomes available now that we ship a
  signed `.app` — re-evaluate when revisiting notifications.

---

## Distribution pipeline kickoff (2026-05-02)

Phase 2 distribution — turning the SPM executable into a signed,
notarized, auto-updating `.app` released via GitHub Actions on tag
push. The work landed in a single session, with one user-driven
follow-up (Apple Developer Program enrollment + Sparkle EdDSA key
generation) gating the first real release.

### What landed

- `Resources/Info.plist` — bundle metadata, `LSUIElement=YES`,
  `LSMinimumSystemVersion=14.0`, `SUFeedURL` pointing at
  `raw.githubusercontent.com/superic/av-pain-reliever/main/appcast.xml`,
  `SUPublicEDKey` placeholder waiting on first `generate_keys`.
  `__MARKETING_VERSION__` / `__BUILD_VERSION__` substituted at build
  time by `make-app.sh`.
- `Resources/AVPainReliever.entitlements` — `app-sandbox=NO`. The
  engine reads `~/Library/Application Support`, talks to IOKit and
  CoreAudio, and uses `SMAppService` for Launch-at-Login — none of
  which are sandbox-compatible. No special hardened-runtime
  exceptions needed.
- `Resources/AppIcon.icns` (455KB) — rendered from
  `Sources/AVPainRelieverApp/AppIcon.swift`'s pill design via
  `scripts/build-icon.sh` + `scripts/icon-exporter.swift`. Renders
  natively at each iconset size (16/32/64/128/256/512/1024 + @2x)
  rather than downscaling a single high-res master, which gives SF
  Symbols a chance to use size-specific glyphs and stay crisp at
  16×16.
- `scripts/make-app.sh` — universal-binary build (`swift build
  --arch arm64 --arch x86_64`), bundle assembly, version stamping
  via sed substitution, embedding of Sparkle.framework's macOS slice
  from the SPM artifact directory, `install_name_tool -add_rpath
  @executable_path/../Frameworks` (SPM only adds `../lib`),
  inside-out codesigning of Sparkle's nested helpers, and a final
  ad-hoc-or-Developer-ID sign of the main app driven by the
  `MAC_CERT_NAME` env var.
- `Sources/AVPainRelieverApp/Updater.swift` + the AppDelegate hook —
  thin wrapper around `SPUStandardUpdaterController`, plus a
  conditional gate that skips Sparkle init when running outside a
  proper bundle (`swift run`) **or** when the SUPublicEDKey is still
  the `__SPARKLE_PUBLIC_KEY__` placeholder. Without the placeholder
  guard, dev builds pop a "Unable to Check For Updates / EdDSA key
  not valid" dialog at every launch.
- `Sources/AVPainRelieverApp/App.swift` — "Check for Updates…" item
  added to the existing **Advanced** submenu (commit `8f54caf`).
- `appcast.xml` (stub) — empty `<channel>` so the first running app
  resolves to "you're up to date" against an empty feed.
- `.github/workflows/release.yml` — fires on `v*.*.*` tag push,
  imports the cert from `MACOS_CERTIFICATE` (base64 `.p12`) into a
  temp keychain, runs `make-app.sh`, runs `notarytool submit
  --wait`, staples, EdDSA-signs the zip via Sparkle's `sign_update`,
  drafts a GitHub Release with auto-generated notes, then commits
  the new `<item>` to `appcast.xml` on `main`. Each Apple- or
  Sparkle-secret-dependent step early-exits with a `::warning::` if
  the secret is empty, so a `v0.0.0-dryrun` tag exercises the
  workflow end-to-end without credentials.
- `scripts/sign-appcast.sh` — wraps `sign_update`, emits a
  ready-to-paste `<item>` block. Reads the private key from
  `$SPARKLE_PRIVATE_KEY` (CI) or the `avpainreliever` keychain
  account (local).
- `docs/releasing.md` — runbook for Apple Developer Program
  enrollment, Sparkle key generation, the seven `gh secret set`
  commands, the first-tag checklist, and a troubleshooting section.

### Lessons learned

- **macOS file-provider race against codesign.** Building the
  bundle directly under `dist/` in a `~/Documents`-rooted repo
  triggered a race: macOS's fileprovider daemon (visible as a
  lingering `com.apple.fileprovider.fpfs#P` xattr) re-added
  `com.apple.FinderInfo` to the bundle root in the milliseconds
  between our `xattr -cr` scrub and codesign's read, causing a
  "resource fork detritus not allowed" failure on the main-app
  sign every time. `xattr -cr "$path" && xattr -d
  com.apple.FinderInfo "$path"` immediately before codesign wasn't
  enough — the race was tighter than that. Fix: assemble + sign in
  a `mktemp -d`, `ditto` the finished bundle to `dist/` at the end.
  /tmp isn't watched by fileprovider.
- **Sparkle.framework needs an explicit rpath.** SPM only injects
  `@executable_path/../lib` into the executable. Sparkle's binary
  expects `@rpath/Sparkle.framework/Versions/B/Sparkle`, where
  `@rpath` is conventionally `@executable_path/../Frameworks`.
  Patching it post-build with `install_name_tool -add_rpath
  @executable_path/../Frameworks` is one line and avoids unsafe
  linker flags in `Package.swift`.
- **Sparkle's nested bundles (Updater.app, Downloader.xpc,
  Installer.xpc) ship pre-signed by the Sparkle project.**
  Re-distributing requires re-signing each one with our identity
  before signing the framework before signing the main app —
  Apple's `--deep` flag is deprecated and notarization rejects it.
  Inside-out, path-by-path is the supported approach.
- **`generate_keys` writes to the user's login keychain.** Running
  it from an automated agent isn't appropriate (it produces a
  long-lived credential the user owns); the docs walk the user
  through running it themselves, replacing the
  `__SPARKLE_PUBLIC_KEY__` placeholder in `Info.plist`, and stashing
  the private key in 1Password + `gh secret set
  SPARKLE_PRIVATE_KEY`.
- **GitHub Actions secrets can't be used in `if:` conditions
  directly.** Tried `if: ${{ secrets.X != '' }}` and it doesn't
  evaluate as expected. The clean pattern: every step runs, but
  the step body checks `[[ -z "${X:-}" ]]` and `exit 0` with a
  `::warning::` if missing. That gives us the "dryrun tag works
  with no Apple creds" property.
- **macOS bash 3.2 + `set -u` + empty arrays.** `"${arr[@]}"`
  expansion on an empty array under `set -u` errors with
  "unbound variable." Use `${arr[@]+"${arr[@]}"}` for the
  empty-safe expansion.

### Pending (gated on user)

- Apple Developer Program enrollment ($99/yr, 24–48h approval).
- Sparkle EdDSA keypair generation + Info.plist substitution.
- Setting the seven GitHub Secrets per `docs/releasing.md`.
- First `git tag v0.1.0` push to exercise the workflow end-to-end.
- Smoke-test auto-update by tagging `v0.1.1` immediately after
  with a one-line README change.

`docs/releasing.md` is the canonical handoff for these.

### Verification done in this session

- `scripts/make-app.sh` produces a valid universal-binary
  `dist/AVPainReliever.app` with embedded `Sparkle.framework`,
  ad-hoc signed, that launches and surfaces the menu-bar pill
  + engine.
- 145 of 146 tests still pass (`IOKitUSBWatcher` test depends on
  attached USB hardware, unrelated to distribution work).
- `swift build -c release --arch arm64 --arch x86_64` clean.
- Sparkle wiring confirmed by an earlier crash dialog: with the
  placeholder public key in Info.plist, Sparkle correctly
  initialized, fetched feedURL, then refused to start ("EdDSA key
  not valid") — proving every step except verification works. The
  guard in `AppDelegate` now suppresses the dialog by skipping
  Sparkle init until a real key is committed.

---

## v0.1.0 shipped (2026-05-03)

Apple Developer Program approved 2026-05-02 evening. The full
Phase 4 (cut v0.1.0) ran the same night. Tag landed, release
workflow turned green, draft GitHub Release published with a
notarized + stapled `AVPainReliever.app.zip`, and `appcast.xml`
on `main` carries a signed `<item>` for v0.1.0. The remaining
local smoke test (drag to /Applications, double-click, no
Gatekeeper warning) is queued for the morning, with the v0.1.1
auto-update exercise immediately after.

### What landed for v0.1.0

- Sparkle EdDSA keypair: public key embedded at
  `Resources/Info.plist:44`, private key in user's login keychain
  + 1Password + as `SPARKLE_PRIVATE_KEY` GitHub Secret.
- Developer ID Application certificate generated via Apple's CSR
  flow, installed in login keychain, exported to `cert.p12`,
  base64'd into `MACOS_CERTIFICATE` GitHub Secret. Cert identity:
  `Developer ID Application: Eric Willis (HLH4LEWS9S)`.
- App-specific password for `notarytool` generated at
  appleid.apple.com, stored as `APPLE_ID_PASSWORD` Secret AND
  locally as keychain profile `avpain-notary` so future
  `xcrun notarytool …` calls can use `--keychain-profile
  avpain-notary` instead of typing it.
- All seven GitHub Secrets populated. The release workflow
  (`.github/workflows/release.yml`) runs end-to-end with no
  skipped steps.
- v0.1.0 tag pushed → workflow green in 1m41s on the second
  attempt (first attempt failed at notarization; see Lessons).

### Lessons learned (v0.1.0 ship)

- **`Sparkle.framework/Versions/B/Autoupdate` was missing from
  `SPARKLE_NESTED`.** It's a bare Mach-O sibling of the framework's
  main `Sparkle` binary, not a bundle, which is why it slipped
  past the inside-out signing pass. The notarytool log called it
  out cleanly: "The binary is not signed with a valid Developer ID
  certificate" + "The signature does not include a secure
  timestamp" for both arm64 and x86_64 slices. Fix: add the path
  to the array. Documented in `docs/releasing.md` post-mortem
  section so a future Sparkle version bump prompts a re-walk of
  `Versions/B/`.
- **`xcrun notarytool log <id>` is the must-have diagnostic.** A
  notary submission status of `Invalid` says nothing useful on its
  own; the JSON log lists exactly which path/architecture failed
  and why. First thing to run on any failure.
- **Double-clicking a `.cer` to install can hit `errSecKeychainItemNoAccess
  -25294`** if Keychain Access has the iCloud keychain selected
  in the sidebar at install time. `security import …
  developerID_application.cer -k ~/Library/Keychains/login.keychain-db`
  bypasses the GUI ambiguity entirely.
- **Markdown-aware chat clients autolink emails inside code
  blocks.** Pasting `gh secret set APPLE_ID --body 'you@example.com'`
  back through chat → terminal yielded
  `'[you@example.com](mailto:you@example.com)'` as the literal
  Secret value. Twice. Fix is to type the email directly into the
  terminal, or use `gh secret set NAME` with no `--body` so it
  reads from a `?` prompt. Captured in the post-mortem because
  it'll happen to anyone scripting Apple-account Secrets via chat.
- **Notarization is the moment Apple actually inspects the
  bundle.** Ad-hoc dev builds happily ignore signing miss-matches
  that hard-fail under notary. Plan for at least one tag-fail-fix
  cycle on the first signed release and don't pre-publish the
  draft until smoke-tested.

### Hardening done concurrently with v0.1.0

To make a recurrence less likely:

- `Updater.shouldEnable(bundleIdentifier:publicKey:)` — the
  build-time placeholder gate is now a pure function on `Updater`
  with `UpdaterGatingTests` covering all six branches. Previously
  inline in `AppDelegate.applicationDidFinishLaunching`,
  un-testable. A placeholder slipping into a release tag would
  pop "Unable to Check For Updates" at every user; this catches
  it in CI.
- `.github/workflows/test.yml` — runs `swift test` on every PR
  and on every push to `main`. Cheap fast feedback so a
  regression doesn't have to wait for a release tag to surface.
- `Package.swift` Sparkle pin tightened from `from: "2.6.0"`
  (allows up to <3.0) to `.upToNextMinor(from: "2.9.0")` (allows
  2.9.x patches only). New minor needs a deliberate bump and a
  fresh walk of `Versions/B/` to confirm no new nested helpers.
- `docs/releasing.md` post-mortem section captures the four
  lessons above + the diagnostic incantations.

### Pending after v0.1.0 (small)

- Smoke test the published v0.1.0 `.app.zip` end-to-end on a
  fresh install (queued for morning of 2026-05-04).
- Tag v0.1.1 with a one-line README change to exercise Sparkle
  auto-update from a v0.1.0 install.
- (Once Sparkle bumps to 2.10/3.0) walk `Sparkle.framework/Versions/B/`,
  update `SPARKLE_NESTED`, do a `v0.0.0-dryrun` tag.

### Pending after v0.1.0 (larger, deferred)

- AppDelegate is 577 lines. Lots of small responsibilities live
  there: engine boot, Sparkle gate, login-item apply, welcome
  state, profile-edit session lifecycle. A natural break is
  `EngineBootManager` + `EditingSessionManager` + leaving
  AppDelegate as the SwiftUI scene wiring + lifecycle. Not
  blocking anything; the file is dense but understandable.
- Homebrew-cask distribution path (still on the v2 list per
  `docs/releasing.md`).

---

## Menu bar profile-icon toggle (2026-05-03)

Added an opt-in setting that swaps the menu bar's `pills.fill` glyph
for the active profile's SF Symbol. Default off so the product's
brand glyph stays the out-of-the-box look; users who want the menu
bar to track location flip the toggle in Settings → General →
Behavior ("Show current profile icon in the menu bar").

Implementation reused existing pieces end-to-end:

- `SettingsStore` — new `showProfileIconInMenuBar` Bool with the
  same `@Published`/`didSet`/UserDefaults pattern as the other
  toggles. Default decoded with `(object(forKey:) as? Bool) ?? false`
  so "never set" stays distinct from "explicitly off".
- `AppDelegate` — one-line passthrough mirror so `MenuLabelView`
  re-renders via the existing `objectWillChange` republish.
- `MenuLabelView` — new private `menuBarIcon` computed var routes
  through `ProfileIcon.effectiveSymbol(for:override:)`, the same
  resolver the "Switch to" submenu and Profiles list already use.
  Falls back to `Theme.Symbol.appIcon` when the toggle is off, when
  no active profile is known yet (fresh launch pre-evaluation), or
  when the active slug isn't found in `availableProfiles`.
- The unknown-location branch is intentionally untouched — when the
  user is at a new dock there's no active profile to represent, so
  the `questionmark.circle` + "New location" treatment stays the
  right signal regardless of toggle state.

No new types, no new files. Total diff: ~25 net lines across four
files.

---

## About dialog refresh (2026-05-03)

Stripped the "fiddling" framing out of the About dialog and rebuilt
it around the four things that actually matter at the About moment:
app icon, app name, version, an update affordance, and the existing
"Show welcome again" link.

What got cut:

- `Theme.Copy.tagline` ("Stop fiddling with mic, speakers, and webcam.")
- The italic "Made to stop the fiddling." line.
- The two-line description block ("Lives quietly in your menu bar / Watches your USB ports / Picks the right defaults.").
- The intervening Divider.

What got added:

- A bordered `Check for Updates` button wired to the existing
  `delegate.checkForUpdates()` Sparkle pass-through, so the same
  update path Advanced → Check for Updates… uses is now reachable
  from About too.
- A one-shot SwiftUI confetti burst overlaid on the dialog. Hand-
  rolled, no SPM dep — 36 particles (Circle / Capsule / `pills.fill`
  brand-glyph wink) with random color, size, drift, spin, and fall
  duration, each animated by a single per-particle `@State` flipped
  on appear. The whole overlay unmounts after 2.6 s via `.task` +
  `showConfetti = false` so nothing keeps ticking once the burst
  finishes. Palette uses system colors (`.accentColor`, `.yellow`,
  `.pink`, `.green`, `.blue`, `.orange`) so it inherits the user's
  macOS accent and stays plain-native.

Frame shrunk 360 × 460 → 360 × 340. `Theme.Copy.tagline` is still
defined; it just isn't used by the About dialog anymore.

---

## Refined-pills icon + menu bar symbol picker (2026-05-04)

Two related polish moves on the visual identity:

**Icon redesign.** Replaced the SF-Symbol-driven `pills.fill`
artwork with a hand-drawn pharmaceutical capsule on a cool-charcoal
gradient squircle. The dual-pill SF symbol read as cartoony /
medicine-cabinet — the new mark is a single capsule with a near-
white cap, soft warm-gray body, thin seam at the meeting point, and
a glassy top-edge highlight, tilted ~25° down-to-the-right. Same
"system utility" register as Activity Monitor / Console — preserves
the pills metaphor without the kitsch.

The drawing lives in `Sources/AVPainRelieverApp/AppIcon.swift` (no
SF symbol reference any more — fully decoupled from
`Theme.Symbol.appIcon`). `Resources/AppIcon.icns` is regenerated
from the same drawing via a new `scripts/regen-icon.sh` pipeline:

1. `scripts/render-app-icon.swift` — standalone Swift script that
   duplicates the drawing routine and writes a 1024×1024 PNG.
   Duplication is deliberate; ~80 lines of Core Graphics and the
   regen script is the only consumer, so a second SPM target would
   be overkill. Comment in both files notes the keep-in-sync
   requirement.
2. `sips` downscales to every size `iconutil` expects.
3. `iconutil -c icns` packs the iconset.

`docs/releasing.md` documents the regen step.

**Menu bar symbol picker.** New Settings → General → Behavior row
"Menu bar icon" with a popover-bound 6-column grid of ~12 curated
SF symbols (`MenuBarIcon.catalog`). Wired through:

- `SettingsStore.menuBarIconSymbol: String` (default
  `MenuBarIcon.defaultSymbol` = `"pills.fill"` so existing installs
  see no change).
- `AppDelegate.menuBarIconSymbol` passthrough mirror.
- `MenuLabelView.menuBarIcon` reads from
  `delegate.menuBarIconSymbol` instead of the literal
  `Theme.Symbol.appIcon`.
- `MenuBarSymbolPicker` view — visual sibling of
  `IconPickerView` (same tile size, same selection-highlight). Kept
  separate rather than generalising IconPickerView because the
  wizard picker has an "Auto" affordance keyed to a profile slug
  that doesn't translate.

Per-profile icon override (existing
`showProfileIconInMenuBar` toggle) still wins when a profile is
active. The picker controls the *fallback* symbol.

`Theme.Symbol.appIcon` left as the documented brand-glyph constant
for any future caller that wants "the original."

---

