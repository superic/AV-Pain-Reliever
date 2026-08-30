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

    @Test("streaming still reports fps with no source name")
    func streamingWithoutSource() {
        let status = VirtualCameraPreviewStatus.streaming(fps: 24)
        #expect(status.label(sourceName: nil) == "Relaying 24 fps.")
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
