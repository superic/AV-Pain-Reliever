import Foundation
import Testing
@testable import AVPainRelieverApp
import AVPainRelieverSharedConstants

@Suite("VirtualCameraPreviewStatus")
struct VirtualCameraPreviewStatusTests {
    @Test("streaming names the source camera when one is known")
    func streamingNamesSource() {
        let status = VirtualCameraPreviewStatus.streaming(fps: 30)
        #expect(
            status.label(sourceName: "HDMI to U3 capture")
                == "Relaying 30 fps from HDMI to U3 capture."
        )
    }

    @Test("frames with no open source read as a held frame, not a relay")
    func streamingWithoutSource() {
        // The extension re-emits its cached frame at full rate when
        // the sink dries up, so "frames arriving" plus "no camera on
        // air" is a frozen picture. Naming no source but claiming a
        // relay would be the lie this replaced.
        let status = VirtualCameraPreviewStatus.streaming(fps: 30)
        let label = status.label(sourceName: nil)
        #expect(!label.contains("Relaying"))
        #expect(label == "Holding the last frame — no source camera is open.")
    }

    @Test("green is reserved for live frames from a named open source")
    func onlyNamedSourceGoesGreen() {
        let streaming = VirtualCameraPreviewStatus.streaming(fps: 30)
        #expect(streaming.dotTint(sourceName: "Studio Display Camera") == Theme.Color.success)
        #expect(streaming.dotTint(sourceName: nil) == Theme.Color.warn)
    }

    @Test("dot colors match the severity of their sentences")
    func dotTintSeverity() {
        #expect(VirtualCameraPreviewStatus.deviceMissing.dotTint(sourceName: nil) == Theme.Color.error)
        #expect(VirtualCameraPreviewStatus.accessDenied.dotTint(sourceName: nil) == Theme.Color.error)
        #expect(VirtualCameraPreviewStatus.waitingForFrames.dotTint(sourceName: nil) == Theme.Color.warn)
        #expect(VirtualCameraPreviewStatus.stalled.dotTint(sourceName: nil) == Theme.Color.warn)
        // A named source can't upgrade a non-streaming state.
        #expect(VirtualCameraPreviewStatus.stalled.dotTint(sourceName: "Some Camera") == Theme.Color.warn)
    }

    @Test("the three diagnostic states read differently from each other")
    func diagnosticStatesAreDistinct() {
        // The 2026-08-28 debugging session needed to tell "device
        // isn't published" from "device is open but dry" from "frames
        // are flowing". Those must never collapse into one sentence.
        let labels = [
            VirtualCameraPreviewStatus.deviceMissing,
            .waitingForFrames,
            .streaming(fps: 30),
        ].map { $0.label(sourceName: "Studio Display Camera") }
        #expect(Set(labels).count == 3)
    }

    @Test("only the frame-carrying states render the video surface")
    func videoSurfaceGating() {
        #expect(VirtualCameraPreviewStatus.streaming(fps: 30).showsVideoSurface)
        #expect(VirtualCameraPreviewStatus.waitingForFrames.showsVideoSurface)
        #expect(VirtualCameraPreviewStatus.stalled.showsVideoSurface)
        // The placeholder is a picture; hiding the surface would
        // replace one "nothing here" graphic with another.
        #expect(VirtualCameraPreviewStatus.showingPlaceholder.showsVideoSurface)
        #expect(!VirtualCameraPreviewStatus.idle.showsVideoSurface)
        #expect(!VirtualCameraPreviewStatus.deviceMissing.showsVideoSurface)
        #expect(!VirtualCameraPreviewStatus.accessDenied.showsVideoSurface)
    }

    @Test("no state names a third-party app")
    func noThirdPartyNames() {
        let banned = ["Zoom", "Slack", "Teams", "OBS", "FaceTime"]
        let labels: [String] = [
            .idle,
            .deviceMissing,
            .accessDenied,
            .waitingForFrames,
            .stalled,
            .streaming(fps: 30),
            .showingPlaceholder,
        ].map { (status: VirtualCameraPreviewStatus) in
            status.label(sourceName: nil)
        }
        for label in labels {
            for name in banned {
                #expect(!label.contains(name))
            }
        }
    }
}

/// The placeholder-vs-live half of the row, added when the extension
/// gained its no-signal placeholder (#125). Frames arriving on the
/// source no longer prove the user's camera is alive, so the status
/// takes a second input: whether the *host* is still putting frames
/// into the sink.
@Suite("VirtualCameraPreviewStatus placeholder derivation")
struct VirtualCameraPreviewPlaceholderTests {
    /// Comfortably inside the grace window, for cases where the host's
    /// liveness isn't what's under test.
    private static let hostLive: TimeInterval = 0

    /// Past the grace window by a margin no rounding can close.
    private static let hostDry =
        VirtualCameraPreviewStatus.hostDeliveryGraceSeconds + 1

    @Test("host delivering plus frames arriving is a plain relay")
    func streamingWhenHostDelivers() {
        #expect(
            VirtualCameraPreviewStatus.derive(
                sourceFrames: 30,
                windowSeconds: 1,
                everDelivered: true,
                hostEverDelivered: true,
                hostDrySeconds: Self.hostLive
            ) == .streaming(fps: 30)
        )
    }

    @Test("frames arriving from a dry host are the placeholder, not a relay")
    func placeholderWhenHostIsDry() {
        // The regression this exists to stop: the extension pumps
        // placeholder frames at full rate, so a source-side frame count
        // alone would report a healthy 30 fps over a dead camera.
        #expect(
            VirtualCameraPreviewStatus.derive(
                sourceFrames: 30,
                windowSeconds: 1,
                everDelivered: true,
                hostEverDelivered: true,
                hostDrySeconds: Self.hostDry
            ) == .showingPlaceholder
        )
    }

    @Test("no frames at all still separates never-started from stopped")
    func silenceIsUnchangedByHostLiveness() {
        // A dry host must not upgrade silence to the placeholder
        // state: nothing arriving is its own, worse, fault (#113), and
        // the placeholder claim would assert pixels that aren't there.
        for dry in [Self.hostLive, Self.hostDry] {
            for hostEverDelivered in [false, true] {
                #expect(
                    VirtualCameraPreviewStatus.derive(
                        sourceFrames: 0,
                        windowSeconds: 1,
                        everDelivered: false,
                        hostEverDelivered: hostEverDelivered,
                        hostDrySeconds: dry
                    ) == .waitingForFrames
                )
                #expect(
                    VirtualCameraPreviewStatus.derive(
                        sourceFrames: 0,
                        windowSeconds: 1,
                        everDelivered: true,
                        hostEverDelivered: hostEverDelivered,
                        hostDrySeconds: dry
                    ) == .stalled
                )
            }
        }
    }

    @Test("the grace window is the boundary, exclusive at the top")
    func graceBoundary() {
        let grace = VirtualCameraPreviewStatus.hostDeliveryGraceSeconds
        // Derived from the constant rather than spelled out, so
        // retuning the window doesn't silently invalidate the test.
        #expect(
            VirtualCameraPreviewStatus.derive(
                sourceFrames: 30,
                windowSeconds: 1,
                everDelivered: true,
                hostEverDelivered: true,
                hostDrySeconds: grace.nextDown
            ) == .streaming(fps: 30)
        )
        #expect(
            VirtualCameraPreviewStatus.derive(
                sourceFrames: 30,
                windowSeconds: 1,
                everDelivered: true,
                hostEverDelivered: true,
                hostDrySeconds: grace
            ) == .showingPlaceholder
        )
    }

    @Test("the grace window clears the extension's own hold window")
    func graceClearsTheExtensionHoldWindow() {
        // Inside `NoSignalPolicy.holdWindowNs` the extension is still
        // re-emitting a genuine cached frame, so declaring "placeholder"
        // there would be wrong about the pixels. The preview's window
        // has to sit strictly past it, with room for its own sampling
        // granularity.
        let holdWindow =
            Double(NoSignalPolicy.holdWindowNs) / Double(NSEC_PER_SEC)
        #expect(
            VirtualCameraPreviewStatus.hostDeliveryGraceSeconds
                >= holdWindow + VirtualCameraPreviewController.sampleInterval
        )
    }

    @Test("a slow but real source still reads as live")
    func slowSourceIsNotAPlaceholder() {
        // A capture card at 2 fps keeps the sink wet well inside the
        // grace window; reporting it as a placeholder would be the
        // inverse of the bug being fixed.
        #expect(
            VirtualCameraPreviewStatus.derive(
                sourceFrames: 2,
                windowSeconds: 1,
                everDelivered: true,
                hostEverDelivered: true,
                hostDrySeconds: 0.5
            ) == .streaming(fps: 2)
        )
    }

    @Test("a host that has never delivered gets no grace, even at zero dryness")
    func neverDeliveredIsPlaceholderFromTheFirstSample() {
        // #125 follow-up: `startSampling()` used to seed the dryness
        // clock as "moved just now" even when the host's delivery count
        // was zero and had never moved, so the very first sample of a
        // session with the capture card off read as a fresh, live host
        // — a green "Relaying" row over a picture that was already
        // showing NO SIGNAL. `hostDrySeconds` near zero must not read
        // as "alive" when nothing has ever arrived.
        #expect(
            VirtualCameraPreviewStatus.derive(
                sourceFrames: 30,
                windowSeconds: 1,
                everDelivered: true,
                hostEverDelivered: false,
                hostDrySeconds: 0
            ) == .showingPlaceholder
        )
    }

    @Test("never-delivered stays the placeholder no matter how the dryness clock reads")
    func neverDeliveredIgnoresDryness() {
        // `hostDrySeconds` has no meaning yet when nothing has ever
        // moved — there's no "last moved" instant to measure from — so
        // `.derive` must not consult it while `hostEverDelivered` is
        // `false`. True at both ends of the grace window rules out an
        // implementation that only checks this at zero.
        for dry in [Self.hostLive, Self.hostDry] {
            #expect(
                VirtualCameraPreviewStatus.derive(
                    sourceFrames: 30,
                    windowSeconds: 1,
                    everDelivered: true,
                    hostEverDelivered: false,
                    hostDrySeconds: dry
                ) == .showingPlaceholder
            )
        }
    }

    @Test("never-delivered vs. delivered-then-stopped is the only thing that moves at zero dryness")
    func neverDeliveredVersusStoppedBoundary() {
        // The exact contrast the regression collapsed: at the same
        // instant — dryness measured as zero either way — a host that
        // has put at least one frame into the sink reads as streaming
        // (it just delivered), while a host that never has reads as
        // the placeholder (it has never delivered, so "just delivered"
        // is exactly the lie `hostEverDelivered` exists to block).
        #expect(
            VirtualCameraPreviewStatus.derive(
                sourceFrames: 30,
                windowSeconds: 1,
                everDelivered: true,
                hostEverDelivered: true,
                hostDrySeconds: 0
            ) == .streaming(fps: 30)
        )
        #expect(
            VirtualCameraPreviewStatus.derive(
                sourceFrames: 30,
                windowSeconds: 1,
                everDelivered: true,
                hostEverDelivered: false,
                hostDrySeconds: 0
            ) == .showingPlaceholder
        )
    }

    @Test("the placeholder row warns, names the dead camera, and stays out of green")
    func placeholderCopyAndTint() {
        let status = VirtualCameraPreviewStatus.showingPlaceholder
        #expect(status.dotTint(sourceName: "HDMI to U3 capture") == Theme.Color.warn)
        #expect(status.dotTint(sourceName: nil) == Theme.Color.warn)
        #expect(
            status.label(sourceName: "HDMI to U3 capture")
                == "No picture from HDMI to U3 capture — showing the no-signal placeholder."
        )
        #expect(
            status.label(sourceName: nil)
                == "No picture from your camera — showing the no-signal placeholder."
        )
    }

    @Test("the placeholder row can't be mistaken for any other state")
    func placeholderReadsDistinctly() {
        let labels = [
            VirtualCameraPreviewStatus.showingPlaceholder,
            .waitingForFrames,
            .stalled,
            .streaming(fps: 30),
        ].map { $0.label(sourceName: "Studio Display Camera") }
        #expect(Set(labels).count == 4)
    }
}
