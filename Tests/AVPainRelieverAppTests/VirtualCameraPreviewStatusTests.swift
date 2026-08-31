import Testing
@testable import AVPainRelieverApp

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
