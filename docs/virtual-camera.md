# Virtual camera (V2)

The native CMIO Camera Extension that lets Zoom / Slack / Teams pick up "AV Pain Reliever" as a camera and follow the active profile's source. This is the canonical V2 record — design decisions, system-extension lifecycle, lock-step rule with the host app, codesign quirks, and the implementation milestones (M1–M7) as they landed.

For developer setup of this feature see [docs/virtual-camera-dev.md](virtual-camera-dev.md) (build/install loop, common failures, fallback paths).

## V2 plan: native virtual camera (CMIO Camera Extension)

**Status:** planning, 2026-05-04. Decisions captured below; no code
yet. This section is the canonical record for the V2 work — update it
as the design evolves and as milestones land.

### Why this, why now

Today's app sets `AVCaptureDevice.userPreferredCamera`, which covers
FaceTime and browsers (Safari/Chrome `getUserMedia`) automatically.
It does **not** cover Zoom, Slack, or Teams — those apps store their
own camera selection and ignore the system preference. There is no
public API to change Zoom's selection from the outside.

The earlier plan was to recommend OBS Virtual Camera as the bridge:
configure OBS once with a per-scene camera, point Zoom/Slack at "OBS
Virtual Camera," and let OBS scene-switching handle the rest. That
plan was retired on 2026-05-04 — OBS is a third-party dependency
and the project mandate is "self-contained" (no third-party tools in
the UI or in the docs).

The V2 path: ship a native macOS Camera Extension (CoreMedia I/O,
macOS 13+) bundled inside the app. Zoom/Slack/Teams see "AV Pain
Reliever" in their picker, the user selects it once, and from then
on the active profile drives what frames flow through. CMIO Camera
Extensions are the modern macOS API used by mmhmm, Hand Mirror,
Detail, Camo, Ecamm Live, and OBS itself (since OBS migrated off the
deprecated DAL plug-in path in 2022).

### Decisions (settled 2026-05-04)

- **Activation is opt-in.** Default install behaves exactly like
  v0.1.x — no system-extension prompt, no extra entry in Zoom's
  picker. Users enable the virtual camera from a Settings toggle,
  which triggers the system-extension approval flow at that moment.
  Rationale: most users may already be happy with FaceTime/browser
  coverage; an opt-in toggle respects that and keeps first-launch
  identical.
- **On profile switch, hold last frame.** The virtual camera holds
  the last good frame from the outgoing source for ~500 ms while
  the new source initializes, then cuts. Polite to viewers in a
  live call, no jarring black flash. Exact hold duration is a tuning
  knob, not a design decision.
- **macOS 13+ floor for v0.2.0.** This is a modern app; CMIO Camera
  Extensions need 13+. Users still on macOS 12 stay on the v0.1.x
  Sparkle channel and miss the feature, which is fine.
- **Picker name: "AV Pain Reliever".** Short, matches the app name,
  reads correctly in narrow Zoom/Slack pickers. No "Camera" suffix,
  no "Virtual" parenthetical.
- **Source mirrors the active profile.** The virtual camera vends
  frames from whatever camera the current profile says is the
  preferred camera. No separate "virtual camera source" config —
  one less knob, and it matches the user mental model ("Zoom should
  finally follow my profiles").
- **Apple entitlement request happens after a working prototype.**
  Build first on user's machine in `systemextensionsctl developer
  on` mode, prove the architecture end-to-end, then submit the
  request. Risk: turnaround is days to weeks, so we may end up with
  a finished feature waiting on Apple. Acceptable — the existing
  release line keeps shipping in parallel.

### Architecture

Three pieces, separated by process boundary:

1. **Main app (existing process).** Owns USB watching, profile
   resolution, settings, the menu-bar UI. Adds a new
   `VirtualCameraController` protocol with two implementations:
   - `NoopVirtualCameraController` — does nothing. Used in the
     default v0.1.x build. Lets the existing release pipeline
     continue untouched.
   - `CMIOVirtualCameraController` — captures from the active
     profile's source camera using AVFoundation, encodes each
     frame as an IOSurface, and pushes it to the extension over
     XPC. Receives extension-side status (active client count,
     errors).
2. **Camera Extension (`AVPainRelieverCameraExtension.systemextension`).**
   A `CMIOExtensionProvider` host with one `CMIOExtensionDevice`
   ("AV Pain Reliever") and one `CMIOExtensionStream`. **Pure
   relay** — receives `IOSurface` frames from the host app over
   XPC, wraps each in a `CMSampleBuffer`, sends downstream via
   `stream.send(...)`. Handles hold-last-frame on source-camera
   switch (i.e., when the host app pauses the XPC frame feed).
3. **XPC pipe.** Both frames and commands flow over the same XPC
   connection. Frames piggyback on `IOSurface` references (zero-
   copy across the process boundary). Commands are simple
   messages: `setSourceCamera(uniqueID:)`, `pause()`, `resume()`,
   `currentStatus()`.

**The extension never touches AVFoundation or the physical camera
hardware.** This is forced by an M2 lesson learned the hard way
(see "Why the extension can't capture" below): a CMIO Camera
Extension that calls `AVCaptureSession` enumerates devices through
the very CMIO subsystem it's plugged into, sees itself in the
list, and creates an IOKit-level deadlock that wedges every camera
app on the machine. OBS, mmhmm, Hand Mirror, Camo all use the
host-app-captures + XPC-to-extension pattern for the same reason.

`ProfileApplier` gains one new step: after setting
`userPreferredCamera`, also tell the `VirtualCameraController` to
switch its source. With the no-op implementation this is free; with
the CMIO implementation it forwards over XPC.

The extension does not own any audio. The existing `AudioController`
path is unchanged — audio still flows through the system default
device, which Zoom/Slack pick up via "Same as System" as today.

### Branch + build setup

- **Branch:** `feature/virtual-camera`, cut off `main` at whatever
  commit is current when work starts. Long-lived. `main` continues
  to ship `v0.1.x` patch releases independently.
- **Project structure shift:** A `.systemextension` target requires
  an actual Xcode bundle, which Swift Package Manager can't build
  alone. Add a thin `AVPainReliever.xcodeproj` alongside `Package.swift`
  that references the existing SPM packages and adds two targets:
  the Camera Extension and an XPC service. SPM development for the
  main app continues unchanged — `swift build`, `swift test`, the
  current scripts. The Xcode project is only invoked for v0.2.0
  release builds.
- **Build configuration:** Two configs — `Release` (existing,
  no extension embedded, no camera-extension entitlement, ships as
  v0.1.x) and `ReleaseWithVirtualCamera` (embeds the extension,
  declares the entitlement, ships as v0.2.0+). The
  `VirtualCameraController` injection is selected by build setting
  so the no-op build genuinely doesn't link the CMIO code path.
- **CI:** Existing GitHub Actions release workflow keeps working as-
  is for v0.1.x. A second workflow (or a parameter on the existing
  one) handles v0.2.0+ builds via xcodebuild. Notarization stays the
  same Developer ID flow; the only delta is the entitled
  provisioning profile after Apple approves the entitlement.

### Milestones

Rough ordering, not a timeline (this is a side project; whenever
each lands, it lands). Re-numbered after the M2 retreat (see "Why
the extension can't capture"):

1. **M1 — Project scaffold.** ~~`AVPainReliever.xcodeproj`~~ kept
   the SPM + shell-script build pattern. Empty Camera Extension
   target that activates and shows up in Zoom but vends a black
   frame. Goal: prove the activation/signing/embedding plumbing
   works. **SHIPPED 2026-05-04.**
2. **M2 — Host-side capture + CMIO sink-stream pipe.** SHIPPED
   2026-05-04. Host app opens an `AVCaptureSession` against the
   built-in webcam, opens AV Pain Reliever's sink stream via raw
   CMIO C API, and enqueues each captured `CMSampleBuffer` into
   the sink's `CMSimpleQueue`. The kernel passes the underlying
   IOSurfaces across the process boundary. Extension consumes
   from the sink via `stream.consumeSampleBuffer(from:)` on a
   timer at 3× framerate and forwards each consumed frame to the
   source stream that AVCapture clients (Zoom, Photo Booth, etc.)
   read. Initial XPC implementation was abandoned — see "Why XPC
   didn't work for the frame pipe" below.
3. **M3 — Source switching + hold-last-frame.** SHIPPED
   2026-05-04. Engine layer drives the host's running
   `AVCaptureSession` directly through a new
   `VirtualCameraSourceController` adapter — no XPC (M2's
   architecture pivot eliminated the XPC service entirely). The
   active profile's `camera` field becomes both the system
   `userPreferredCamera` (existing behavior) AND the virtual
   camera's source (new). Extension holds the most recent frame
   and re-emits it at 30 fps when the sink temporarily dries up,
   covering the ~500 ms input-swap window so Zoom doesn't see a
   freeze.
4. **M4 — Settings UI + opt-in toggle.** SHIPPED 2026-05-04.
   `SettingsStore.virtualCameraEnabled` (default off).
   `VirtualCameraActivator` refactored from a static one-shot
   into a stateful `ObservableObject` with state machine
   (`.off` / `.activating` / `.needsApproval` / `.on` /
   `.failed` / `.requiresRelaunch`) and a `relaunch()` action.
   Camera tab in Settings shows toggle + live status row +
   contextual button (Open Login Items & Extensions for
   approval, Restart AV Pain Reliever for the in-session
   re-enable quirk). `AVPR_ACTIVATE_VIRTUAL_CAMERA=1` kept as a
   debug override that locks the toggle for the launch and shows
   a "Debug override" badge.
5. **M5 — Release readiness.** SHIPPED 2026-05-04. Release
   workflow now picks the right build script per tag (v0.1.x →
   make-app.sh, v0.2.x+ → make-app-with-virtual-camera.sh) so
   the v0.1.x release line stays unblocked. New
   `MACOS_PROVISIONING_PROFILE` GitHub Secret carries the
   profile that the extension needs for activation outside
   developer mode. README has a "Virtual camera" section
   explaining the feature install-first; Settings UI's Camera
   tab is the discovery path. Sparkle/extension upgrade-replace
   verification is documented as an end-to-end test plan to be
   run with the v0.2.0 → v0.2.0.1 cycle in M6 — can't be
   shippable-verified until at least one v0.2.x release exists
   on the appcast.
6. **M6 — Tag v0.2.0.** SHIPPED 2026-05-04. CI workflow ran
   clean (1m48s) using `make-app-with-virtual-camera.sh`,
   notarized + stapled both bundles, signed appcast item
   appended to main, draft published. v0.2.0 live at
   https://github.com/superic/av-pain-reliever/releases/tag/v0.2.0.
7. **M7 — Sparkle release channel split.** SHIPPED 2026-05-04.
   v0.2.0 was retroactively marked
   `<sparkle:channel>experimental</sparkle:channel>` so v0.1.x
   users stop being prompted to upgrade. v0.1.14 ships an
   "Receive experimental updates" toggle to Settings → General
   → Updates plus an `SPUUpdaterDelegate` that returns
   `["experimental"]` when the toggle is on (default off).
   `scripts/sign-appcast.sh` now takes a `CHANNEL` env var; the
   release workflow auto-sets it to `experimental` for v0.2.x+
   tags. v0.2.0.1 backports the channel-aware Updater to
   feature/virtual-camera (live at
   https://github.com/superic/av-pain-reliever/releases/tag/v0.2.0.1)
   so users on the experimental track get future patches
   normally.

### Deferred / open items

- **Hold-last-frame exact duration.** Resolved in M3: there is no
  fixed duration — the extension repeats the cached frame at 30 fps
  for as long as the sink stays empty AND a client is watching.
  Verified on a manual switch from `home-office` → `laptop` on
  2026-05-04: cold-start gap on first client connect was covered by
  one held emit before fresh frames took over.
- **Behavior when no source camera is available** (profile says
  camera X, X is unplugged). Currently logged as
  `virtual camera source 'X' not found — skipping`; the running
  session keeps the previous source and the virtual camera continues
  to deliver that. No black frame, no placeholder. Revisit if the
  user reports it as confusing in practice.
- **Format negotiation for non-FaceTime cameras.** Resolved as
  part of M3 (2026-05-04). Diagnosis: forced
  `kCVPixelFormatType_32BGRA` at 1280×720 in the host's
  `videoSettings` works for FaceTime HD but silently dropped
  every frame from the user's HDMI to U3 capture card
  (vendor 0x1e4e / product 0x701f) which natively delivers
  `420v` (NV12) at 1920×1080. Fix: host accepts the device's
  native format; `CMIOSinkWriter` runs each frame through
  `VTPixelTransferSession` to convert to 1280×720 BGRA before
  enqueueing. `CVPixelBufferPool` recycles the destination
  buffers so steady-state capture doesn't churn allocations.
  Verified end-to-end on both `home-office` (HDMI capture, NV12
  1080p source path) and `laptop` (FaceTime HD, BGRA 720p
  passthrough path) profiles.
- **Resolution / format negotiation.** Match source for V2; revisit
  if Zoom complains about specific formats.
- **Uninstall flow.** Resolved in M4 (2026-05-04). The Settings
  toggle calls `OSSystemExtensionRequest.deactivationRequest` on
  flip-off and tears down the host capture pipeline. Surfaces in
  System Settings → Login Items & Extensions for true uninstall.
- **In-session toggle off → on quirk.** Surfaced and partially
  resolved in M4 (2026-05-04). `OSSystemExtensionRequest.deactivationRequest`
  doesn't actually stop the running extension process — it
  queues `[terminated waiting to uninstall on reboot]` while the
  extension stays alive and visible to AVCapture clients. Toggle
  back on in the same host process can't get fresh CMIO state for
  the device (the host's CMIO context already saw the device as
  "going away") so the pipeline produces a black feed. Detected
  via the activator's `deactivatedThisSession` flag; toggle-on
  routes to `.requiresRelaunch` and the Settings UI surfaces a
  "Restart AV Pain Reliever" button that quits + relaunches the
  host (fresh process → fresh CMIO context → device found
  immediately, same path that works on every cold launch). Not
  pretty, but mac OS doesn't expose a userspace API to tear down
  an extension and re-attach in the same process.
- **Stale per-process CMIO context (#120, 2026-08-30).** The same
  fresh-process cure, reached by a different route and now applied
  automatically. After an in-place extension replace, the host's
  CMIO context can go stale in a way that freezes
  `AVCaptureDevice.DiscoverySession` for the life of the process:
  the host polled 30 s and re-checked for 2 minutes without
  seeing the device while a freshly-launched Zoom opened it fine.
  So when the #117 re-check budget expires, the activator
  relaunches itself (`relaunchForStaleDiscovery` →
  `relaunch()`), after a user-visible notification and gated on
  the notifier reporting the post accepted. Three things bound it:
  a `UserDefaults` latch (`VirtualCameraRelaunchGuard`) written
  before the quit, so the process that comes back knows it already
  spent its retry and declines to loop; `.requiresReboot` and an
  unanswered relaunch-vs-reboot properties query are both excluded
  (a bare relaunch is futile on those machines — #110/#112); and
  the re-check budget is counted in ticks actually fired, so a
  sleep/wake inside the window can't spend the latch on a
  transient. The latch is given back only by a confirmed sighting
  of the camera or by the user disabling the feature. Decision
  matrix: `VirtualCameraActivator.autoRelaunchDecision`.
- **Sparkle + extension replacement edge cases.** Specifically the
  "user has Zoom open with the virtual camera active when v0.2.1
  installs" case. Investigate in M6.
- **Entitlement request body.** Draft once M4 lands so we can
  describe a working feature, not a hypothetical.

### M1 — project scaffold (SHIPPED 2026-05-04)

Branch: `feature/virtual-camera`. Approach: extend the existing
SPM + shell-script build pattern rather than introduce an Xcode
project. A `.systemextension` is just a different bundle wrapper
around a Swift binary; the existing `make-app.sh` already proves
hand-rolled bundle assembly works for this project.

What landed:

- `Sources/AVPainRelieverCameraExtension/` — four Swift files:
  `main.swift` (entry point), `CameraExtensionProvider.swift`
  (CMIOExtensionProviderSource), `CameraExtensionDevice.swift`
  (CMIOExtensionDeviceSource — single device, stable UUID),
  `CameraExtensionStream.swift` (CMIOExtensionStreamSource —
  vends 1280×720 BGRA black frames at 30 fps via a
  `DispatchSourceTimer` + `CVPixelBufferPool`).
- `Package.swift` — added
  `AVPainRelieverCameraExtension` as an executable target. No
  dependency on `AVPainReliever` or `AVPainRelieverApp`; clean
  process boundary from the start.
- `Resources/AVPainRelieverCameraExtension-Info.plist` — minimal
  bundle metadata (`CFBundlePackageType = SYSX`, child bundle ID
  `com.ericwillis.avpainreliever.CameraExtension`).
- `Resources/AVPainRelieverCameraExtension.entitlements` —
  sandboxed (`com.apple.security.app-sandbox = true`).
- `Resources/AVPainReliever-WithVirtualCamera.entitlements` —
  v0.2.0 host-app entitlements adding
  `com.apple.developer.system-extension.install`. The default
  `Resources/AVPainReliever.entitlements` is unchanged so the
  v0.1.x signing pipeline is byte-for-byte the same.
- `scripts/make-app-with-virtual-camera.sh` — parallel-track
  build script. Runs `swift build` for both products, assembles
  both bundles, embeds the extension at
  `Contents/Library/SystemExtensions/`, signs inside-out (Sparkle
  nested → Sparkle.framework → Camera Extension → host app).
- `Sources/AVPainRelieverApp/VirtualCameraActivator.swift` +
  `AppDelegate.applicationDidFinishLaunching` hook — env-var-gated
  (`AVPR_ACTIVATE_VIRTUAL_CAMERA=1`) `OSSystemExtensionRequest`
  activation. No-op on v0.1.x builds (entitlement absent → request
  fails harmlessly). M4 will replace this with a real Settings
  toggle.
- `docs/virtual-camera-dev.md` — local-test recipe:
  `systemextensionsctl developer on`, build, ditto into
  `/Applications`, env-var-launch, verify in Zoom, iteration loop,
  uninstall, common failure modes.

What's deliberately not done: no main-app integration with
`ProfileApplier`, no source-camera switching, no XPC service yet.
Those are M2 / M3 / M4. M1's only job is to prove the
activation/embedding/signing plumbing works.

Verification (2026-05-04, second attempt): activated successfully
end-to-end. `systemextensionsctl list` reports `[activated enabled]`,
the extension process is alive under `_cmiodalassistants`, the host
app's activation request returns success, and "AV Pain Reliever"
appears in Zoom's camera picker showing the black 1280×720 frame at
30 fps. M1 success criteria met.

### M1 lessons (gotchas the original scaffold missed)

The first build attempt failed activation because the original
plumbing was missing several non-obvious requirements. Each of
these surfaced as a distinct error from `sysextd`, requiring
re-signing and re-installing to fix. Documenting them so future
milestones don't relearn the same things:

1. **`open` strips environment variables.** The `AVPR_ACTIVATE_VIRTUAL_CAMERA=1`
   env var has to be passed via `open --env AVPR_ACTIVATE_VIRTUAL_CAMERA=1`,
   not the shell-prefix form, because `open` hands off to `launchd`
   which doesn't inherit the calling shell's environment. The
   shell-prefix form sets the var only for the `open` command
   itself, not for the launched app.
2. **Notarization is required for system extension activation,
   even with valid Developer ID signing.** `sysextd` queries the
   notary daemon during validation; an unnotarized bundle gets
   `bundle code signature is not valid - does not satisfy
   requirement: -67050`. The `make-app-with-virtual-camera.sh`
   script grew a notarization step gated by
   `NOTARIZE_KEYCHAIN_PROFILE=avpain-notary` (using the existing
   v0.1.x notarytool keychain profile). One round trip is ~30s; a
   `SKIP_NOTARIZE` style escape hatch is a future-niceness if
   non-system-extension iteration speed becomes a concern.
3. **The Info.plist `CMIOExtension` dict is the type marker.**
   Without it, `sysextd` reports "system extension does not appear
   to belong to any extension categories" — the daemon cycles
   through DriverKit / NetworkExtension / EndpointSecurity checks,
   finds no marker for any of them, and rejects the bundle. The
   correct shape is `<dict><key>CMIOExtensionMachServiceName</key>
   <string>{TEAMID}.{appgroup-id}.{suffix}</string></dict>`. We
   substitute `__TEAM_ID__` at build time, parsed out of
   `MAC_CERT_NAME`.
4. **Mach service name must be prefixed by an App Group declared
   in the extension's entitlements.** The error from `sysextd` is
   "invalid mach service name or is not signed, the value must be
   prefixed with one of the App Groups in the entitlement." This
   meant registering an App Group at developer.apple.com
   (`group.com.ericwillis.avpainreliever`), enabling the App
   Groups capability on both App IDs (host + extension),
   regenerating the Developer ID provisioning profile, and adding
   `com.apple.security.application-groups` to both entitlements
   files with the team-prefixed form
   (`HLH4LEWS9S.group.com.ericwillis.avpainreliever`).
5. **AMFI's entitlement parser doesn't tolerate XML comments.**
   The entitlement plists need to be plain key/value dicts; even
   well-formed `<!-- ... -->` comments fail signing with "Failed
   to parse entitlements: AMFIUnserializeXML: syntax error."
   Documentation has to live in adjacent files, not inline.
6. **Final activation needs explicit user approval in System
   Settings.** `[activated waiting for user]` is the
   intermediate state; the user opens **System Settings → General
   → Login Items & Extensions → Camera Extensions** and toggles
   the extension on. State then transitions to
   `[activated enabled]`.

The dev workflow (`docs/virtual-camera-dev.md`) was rewritten in a
follow-up commit to reflect the actual recipe instead of the
ad-hoc + developer-mode + SIP-off path I originally documented.

### Why the extension can't capture (M2 attempt #1, 2026-05-04)

First M2 attempt put an `AVCaptureSession` inside the Camera
Extension, opened against the built-in webcam, and forwarded the
captured `CMSampleBuffer`s to `stream.send(...)`. The extension
compiled, signed, notarized, and activated cleanly. But as soon as
any client (Photo Booth, Zoom) selected the AV Pain Reliever
camera, the entire camera pipeline on the machine wedged — Photo
Booth froze hard, requiring force-quit and (sometimes) `sudo
killall VDCAssistant` to unwedge.

Diagnosis from the extension's logs: `AVCaptureSession` triggered
`AVCaptureDALDevice _refreshPreferredCameraProperties` and full
device-list enumeration *inside* the extension process. CMIO holds
the system-wide camera-device list while waiting for the
extension's reply on `startStream`; concurrently the extension was
asking AVFoundation to enumerate cameras, which routes back through
CMIO, which sees our extension as one of the devices, which calls
back into the same path. IOKit deadlock — every camera app gets
queued behind it.

Architectural rule that fell out: **a CMIO Camera Extension cannot
use AVFoundation.** Frames have to enter the extension from the
outside, via XPC from the host app or a sibling helper. OBS,
mmhmm, Hand Mirror, Camo, Ecamm Live all use the host-app-captures
+ XPC-to-extension pattern.

This invalidates the original M2/M3 split (where M2 = "frames in
the extension" and M3 = "XPC for commands"). Re-architected:
M2 now means host-side capture + XPC frame pipe; source switching
becomes a one-line change in M3.

Concrete changes after the rollback:
- `CameraExtensionStream.swift` reverted to the M1 black-frame
  timer (no AVFoundation in the extension, ever).
- Camera entitlement (`com.apple.security.device.camera`) and
  `NSCameraUsageDescription` removed from the extension —
  permanently. The extension doesn't need either.
- `Resources/AVPainRelieverCameraExtension.entitlements` keeps
  `com.apple.security.app-sandbox` and the App Group; nothing
  else.
- M2 plan rewritten in milestones list above.

### M2 — host-side capture + CMIO sink (SHIPPED 2026-05-04)

End-to-end working: host captures from the built-in FaceTime HD
camera at 1280×720 BGRA, writes frames into the extension's sink
stream via CMIO's `CMSimpleQueueEnqueue`, the extension drains
the sink and forwards to the source stream that Zoom and Photo
Booth read. Live webcam feed flows through the AV Pain Reliever
virtual camera with no perceptible latency.

Architecture (matches OBS's `mac-virtualcam` pattern,
referenced for design):

- **Extension**: declares two streams on its single device — a
  `.source` stream (AVCapture clients read this) and a `.sink`
  stream (host writes here). Owns no AVFoundation. Runs a
  consume timer at 90 Hz that drains the sink and calls
  `stream.send(...)` on the source when there's an active
  consumer (`streamingCounter > 0`). See
  `Sources/AVPainRelieverCameraExtension/`:
  - `CameraExtensionStream.swift` — source side, just tracks
    streaming counter.
  - `CameraExtensionStreamSink.swift` — sink side, captures the
    `CMIOExtensionClient` in `authorizedToStartStream`.
  - `CameraExtensionDevice.swift` — owns both streams + the
    consume loop.

- **Host**: opens AV Pain Reliever as a CMIO consumer, queries
  each stream's `kCMIOStreamPropertyDirection` to find the sink
  (NOT the index 1 trick — direction-property check is robust
  against ID ordering changes), gets the buffer queue via
  `CMIOStreamCopyBufferQueue`, calls `CMIODeviceStartStream`,
  then enqueues each captured frame via `CMSimpleQueueEnqueue`.
  See `Sources/AVPainRelieverApp/`:
  - `CameraCaptureSession.swift` — AVFoundation capture against
    built-in camera (no recursion since host is a normal app).
  - `CMIOSinkWriter.swift` — raw CMIO sink-write path.

### Why XPC didn't work for the frame pipe

First attempt put NSXPCConnection between host and extension on
a Mach service named `HLH4LEWS9S.group.com.ericwillis.avpainreliever.framepipe`.
The XPC connection failed with `failed to do a bootstrap look-up:
xpc_error=[3: No such process]`. Root cause:
`NSXPCListener(machServiceName:)` only attaches to launchd-
registered services — system extensions don't have launchd
plists for their custom Mach names, so the listener never
registered the service and clients couldn't find it.

The OBS-style sink-stream approach sidesteps this entirely:
CMIO already has cross-process IOSurface plumbing built in,
and using the second stream as a sink reuses that plumbing for
free. No Mach services to register, no XPC code to maintain.

### M3 — profile-driven source switching + hold-last-frame (SHIPPED 2026-05-04)

End-to-end: changing the active profile (manually or by docking
to a known location) swaps the virtual camera's source camera in
the running `AVCaptureSession`, and the extension covers the
~500 ms warm-up gap by re-emitting the last good frame at 30 fps.
Zoom stays connected; the picture freezes for ~500 ms then comes
alive on the new source. No call drop.

Architecture (no XPC — M2's pivot eliminated it permanently):

- **Engine layer** (`Sources/AVPainReliever/Adapters/CameraController.swift`):
  - New `VirtualCameraSourceController` protocol with a single
    `setSource(named:) -> CameraApplyResult` method. Mirrors the
    existing `CameraController` shape so `ProfileApplier` handles
    the two adapters symmetrically.
  - `ProfileApplier` accepts an optional
    `virtualCameraSource:`. When `profile.camera` is set it
    drives BOTH the system `userPreferredCamera` (legacy
    behavior, for AVFoundation-modern apps) AND the virtual
    camera's source (new, for Zoom/Slack/Teams that ignore the
    system preference but follow the AV Pain Reliever device).
  - Nil injection = silent no-op. Production wires it only when
    the env-var-gated activator booted the host capture pipeline;
    v0.1.x and "didn't ask for virtual camera" launches inject
    nil with no behavior change.

- **Host app** (`Sources/AVPainRelieverApp/CameraCaptureSession.swift`):
  - Refactored away from the hardcoded `.builtInWideAngleCamera`
    lookup. Initial source is picked from the same fallback chain
    `AVFoundationCameraController.currentPreferredName` uses
    (`userPreferredCamera` → `systemPreferredCamera` → first
    discovered) so the first frames match what a fresh AVCapture
    client would naturally see.
  - New `switchSource(toLocalizedName:)` runs on the capture
    queue, looks up the device by `localizedName` (matches the
    profile's camera field), and swaps inputs inside a
    `beginConfiguration` / `commitConfiguration` block. The
    session keeps running across the swap — no
    `stopRunning`/`startRunning` cycle.
  - `videoSettings` no longer forces a pixel format or
    dimensions; the device delivers its native format
    (FaceTime HD ships BGRA 720p, the user's HDMI capture card
    ships NV12 1080p, etc) and the conversion happens
    downstream in `CMIOSinkWriter`. M2's forced settings worked
    for FaceTime but silently dropped every frame from the
    HDMI capture card.
  - Conforms to `VirtualCameraSourceController`. The static
    `VirtualCameraActivator.virtualCameraSource` accessor exposes
    the running session to `AppDelegate.buildEngine` so the
    `ProfileApplier` gets the live adapter.
  - `applicationDidFinishLaunching` order changed:
    `VirtualCameraActivator.activateIfRequested()` now runs
    BEFORE `bootEngine()` so the engine's first
    evaluate-and-apply pass finds a live source to drive.

- **Host's CMIO sink writer** (`Sources/AVPainRelieverApp/CMIOSinkWriter.swift`):
  - Added a `VTPixelTransferSession` + `CVPixelBufferPool` pair
    that converts every incoming frame to 1280×720 BGRA before
    `CMSimpleQueueEnqueue`. Hardware-accelerated where the GPU
    supports it; the pool recycles destination buffers so
    steady-state capture allocates nothing per frame.
  - Fast path for inputs that already match (FaceTime HD,
    Continuity Camera) — passthrough, zero copy.
  - Format description is re-derived per pool buffer (cached by
    `CVPixelBuffer` pointer). Sharing one description across
    different source frames gets rejected with -12743 because
    VT attaches source-derived colorspace metadata to the
    destination, and `CMSampleBufferCreateForImageBuffer`
    validates strictly.
  - `Host frame format: <fourcc> <w>x<h> — convert+scale|passthrough`
    is logged once per (format, dimensions) signature change
    so a profile switch is visible without flooding the log.

- **Extension** (`Sources/AVPainRelieverCameraExtension/CameraExtensionDevice.swift`):
  - Caches the most recent `(CVPixelBuffer, CMFormatDescription)`
    pair from the sink. On each consume tick that yields nil and
    the source has at least one watcher, mints a fresh
    `CMSampleBuffer` over the cached pixel buffer with the
    current host time and sends it through the source stream.
  - Held emissions are rate-limited to ~30 fps (matches the
    source's declared `frameDuration`) so the 90 Hz consume
    timer doesn't burst the source at 3× framerate.
  - Holding the underlying `CVPixelBuffer` (not the parent
    `CMSampleBuffer`) lets each repeat carry a fresh PTS without
    AVCapture clients seeing duplicate timestamps.

Wiring summary:

```
profile.camera = "Logitech BRIO"
    │
    ▼
ProfileApplier.applyVirtualCameraSource("Logitech BRIO")
    │
    ▼
CameraCaptureSession.setSource(named:)
    │
    ▼  (capture queue)
session.beginConfiguration()
remove old input
add new AVCaptureDeviceInput(BRIO)
session.commitConfiguration()
    │
    ▼  (~500 ms while BRIO warms up — sink dry)
extension consumeOne() returns nil
    │
    ▼
extension re-emits last cached frame at 30 fps to source
    │
    ▼
Zoom keeps seeing 30 fps — no freeze, no drop
```

### M4 — Settings UI + opt-in toggle (SHIPPED 2026-05-04)

The Camera Extension is now opt-in via a real Settings toggle
instead of the env-var-only path used in M1–M3. Default off, so
fresh installs see no system extension activity until the user
turns it on. The env var (`AVPR_ACTIVATE_VIRTUAL_CAMERA=1`) stays
as a debug affordance — it forces enable on launch regardless of
the persisted setting and shows a "Debug override" badge in the
Settings UI so the user understands why the toggle is greyed out.

Architecture:

- **`SettingsStore.virtualCameraEnabled`** — persisted `Bool`,
  default false. Same `UserDefaults` pattern as the other
  toggles. New unit test covers the default + persistence.

- **`VirtualCameraActivator` refactor** — was a static one-shot
  in M1; now an `ObservableObject` with a state machine:

  ```
  .off ──enable()──▶ .activating ──didFinishWithResult──▶ .on
   ▲ ▲                   │
   │ │                   ├─requestNeedsUserApproval──▶ .needsApproval
   │ │                   └─didFailWithError──────────▶ .failed
   │ └────disable()─────┐
   │                    │
   ┴────────────────────┘
       (deactivatedThisSession=true)
                ↓
       enable() → .requiresRelaunch
   ```

  `enable()` and `disable()` are both idempotent and log every
  transition for debugging. `relaunch()` quits + reopens the
  host bundle via `/usr/bin/open <path>` so the fresh process
  picks up the persisted toggle and gets a clean CMIO context.

- **AppDelegate wiring** — owns the activator (was static).
  Subscribes to `settings.$virtualCameraEnabled` via Combine;
  toggle changes route through `applyVirtualCameraToggle`. The
  activator is itself the `VirtualCameraSourceController`
  plumbed into `ProfileApplier` — silently no-ops when off
  (returns `.ok` without doing anything), forwards to the
  running `CameraCaptureSession` when on. No engine rebuild
  needed on toggle flip.

- **Settings UI — Camera tab** — third tab alongside General
  and Profiles. Shows the toggle, a live status row (colored
  dot + label that mirrors the activator state), and a
  contextual button: "Open Login Items & Extensions" when in
  `.needsApproval` / `.failed`, "Restart AV Pain Reliever" when
  in `.requiresRelaunch`. Footer hint adapts to the state
  (e.g. "Pick 'AV Pain Reliever' in Zoom" when on, and a
  cause-agnostic "macOS is holding the virtual camera in a state
  only a fresh app process can clear…" when a restart is required
  — reworded in #120, where that state can also be reached with
  its automatic restart already spent). Footer rendered as a
  `Text` row inside the section body per the project memory's
  macOS-14 `Form(.grouped)` footer-slot convention.

### M5 — release readiness (SHIPPED 2026-05-04)

Three sub-tasks, all landed:

1. **README — virtual camera section.** New "Virtual camera
   (optional)" section between "Using the app" and "Privacy".
   Install-first, scannable, executive aesthetic preserved
   (per the README-audience memory). Calls out that Zoom /
   Slack / Teams ignore the system default and tells the user
   the four steps to enable it.

2. **CI release workflow updates.**
   `.github/workflows/release.yml` now picks the build script
   from the tag prefix: `v0.0.0-*` and `v0.1.*` keep using
   `scripts/make-app.sh`; everything else (`v0.2.*` and later)
   uses `scripts/make-app-with-virtual-camera.sh`. New
   `MACOS_PROVISIONING_PROFILE` GitHub Secret holds the
   base64-encoded provisioning profile; decoded into
   `Resources/AVPainReliever.provisionprofile` only for v0.2.x+
   runs (skipped silently on v0.1.x to keep that pipeline a
   no-op). `docs/releasing.md` updated to reflect the new
   secret + the script-selection logic.

3. **Sparkle / extension upgrade-replace verification —
   recipe documented; execution in M6.** Can't be properly
   verified until at least one v0.2.x release exists on the
   appcast and there's an installed Sparkle-capable client to
   upgrade FROM. The recipe lives in this section's "Upgrade-
   replace test plan" subsection below; M6 runs it for real.

### M5 — Sparkle upgrade-replace test plan (run during M6)

The macOS quirk we hit during M3/M4 dev iteration was: rebuilding
the extension binary marks the previous version
`[terminated waiting to uninstall on reboot]`, and CMIO stops
exposing the device until reboot or a Settings toggle off/on
cycle. **This test plan validates that Sparkle's normal upgrade
flow doesn't reproduce that quirk for end users**, because
Sparkle quits the running host before swapping the bundle (fresh
process for the new version, clean CMIO context).

Pre-requisites:
- v0.2.0 already released and live on the appcast.
- A Mac with v0.2.0 installed via Sparkle (not via dev build)
  and the virtual camera toggle ON for at least one launch (so
  the extension is `[activated enabled]` in `systemextensionsctl
  list`).

Test steps:
1. On the local dev machine, bump the source to a v0.2.0.1 patch
   (e.g. trivial README typo or release-notes copy edit).
2. `git tag v0.2.0.1 && git push --tags` — CI workflow runs.
3. Verify the workflow used `make-app-with-virtual-camera.sh` and
   notarization succeeded for both the host AND the embedded
   extension bundle.
4. Verify the workflow appended a new `<item>` to `appcast.xml`
   on `main` with the v0.2.0.1 enclosure URL + EdDSA signature.
5. On the test Mac (running v0.2.0): About → Check for Updates.
   Sparkle should detect v0.2.0.1, prompt, download, quit,
   replace the bundle, relaunch.
6. Verify on the test Mac after Sparkle's relaunch:
   - `systemextensionsctl list` — old v0.2.0 entry should
     transition cleanly to v0.2.0.1; the previous version may
     show as `[terminated waiting to uninstall on reboot]` for
     a moment (expected) but the new version should be
     `[activated enabled]`.
   - `system_profiler SPCameraDataType` — AV Pain Reliever
     entry still present.
   - Open Photo Booth → AV Pain Reliever → live frames flowing
     (no black screen).
   - Settings → Camera → status row shows "Active".
7. If step 6 shows black frames, that's the same-process CMIO
   stale-handle bug from M4's known issues; click the
   `Restart AV Pain Reliever` affordance in Settings → Camera
   (which already exists) to recover. If we see this, file a
   follow-up to investigate whether Sparkle's pre-upgrade quit
   is reaching the activator's deactivation path cleanly.

Failure modes worth watching for:
- Apple's notary service rejecting the embedded extension bundle
  for any reason (would surface in the workflow's "Notarize and
  staple" step).
- Sparkle's downloader / installer not preserving the embedded
  `Library/SystemExtensions/...` directory (the extension would
  be missing from the new bundle; would surface as the
  activation request failing on the test Mac's first launch
  after upgrade).

### v0.2.0 release notes (draft, ready to copy)

Paste this into the GitHub Release body when pre-creating the v0.2.0
draft release (per `docs/releasing.md`'s curated-notes flow). The CI
workflow renders it through GitHub's `/markdown` API and pipes the
HTML into the appcast `<description>`, so what you write here is
exactly what shows up in Sparkle's "What's New" panel for upgrading
v0.1.x users.

```markdown
