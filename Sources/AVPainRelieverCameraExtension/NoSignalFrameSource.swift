import Foundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import AVPainRelieverSharedConstants
import os.log

private let logger = Logger(
    subsystem: "com.ericwillis.avpainreliever.CameraExtension",
    category: "NoSignal"
)

/// Pixel generation for the no-signal placeholder — the picture the
/// source stream shows once `NoSignalPolicy` says the cached frame has
/// gone stale (or, at cold start, when there has never been one).
///
/// Everything is rendered at the source stream's exact format (32BGRA,
/// `frameWidth` × `frameHeight`) so nothing in the pipeline has to
/// convert — and each buffer is handed back as a `SourceFrame`, paired
/// with a format description derived from that same buffer rather than
/// from the stream's declared one. See `SourceFrame` for why that
/// matters; a rejection here would surface only as a log line and a
/// placeholder that silently never appears.
///
/// The three modes have deliberately different allocation shapes:
///
/// - `.black` and `.testPattern` are *immutable*. Each is rendered once,
///   lazily, and the same `CVPixelBuffer` is handed out forever. Nothing
///   ever writes to them again, so sharing one buffer with however many
///   sample buffers are in flight downstream is safe. `.black` is the
///   default mode, so the common path costs one `CMSampleBuffer` mint
///   per emitted frame and nothing else.
/// - `.staticNoise` is *mutated* per frame — the motion is the whole
///   point, since frozen noise reads as a corrupted still rather than as
///   snow. Mutating a shared buffer would scribble over a frame a client
///   is still reading, so noise frames come from a `CVPixelBufferPool`:
///   a buffer that's still referenced downstream simply isn't recycled
///   back to us.
///
/// Buffers are allocated lazily on first use and dropped when the mode
/// changes, so an extension sitting in the default mode isn't holding a
/// noise pool it will never draw from.
///
/// **Threading:** not synchronised, and it doesn't need to be. Every
/// entry point runs on `CameraExtensionDeviceSource.consumeQueue`,
/// which is also the only place frames are emitted — see that class's
/// threading note for how each caller gets there. The one piece of
/// shared state, `captionPlate`, is an immutable `static let`.
final class NoSignalFrameSource {
    private static let width = Int(CameraExtensionStreamSource.frameWidth)
    private static let height = Int(CameraExtensionStreamSource.frameHeight)

    /// Current mode, seeded from the shared App Group container at
    /// startup and refreshed when the host posts
    /// `CameraExtensionNotifications.noSignalModeChanged`.
    private(set) var mode: NoSignalMode

    private var blackFrame: SourceFrame?
    private var testPatternFrame: SourceFrame?
    private var noisePool: CVPixelBufferPool?

    /// Xorshift state for `.staticNoise`. Seeded with a constant: the
    /// field only has to *look* random, and a deterministic start makes
    /// a captured repro identical every run.
    private var noiseState: UInt32 = 0x9E37_79B9

    init(mode: NoSignalMode) {
        self.mode = mode
        logger.info("NoSignalFrameSource mode=\(mode.rawValue, privacy: .public)")
    }

    /// Swap modes and release whatever the new mode doesn't draw from.
    func setMode(_ newMode: NoSignalMode) {
        guard newMode != mode else { return }
        logger.info(
            "no-signal mode \(self.mode.rawValue, privacy: .public) → \(newMode.rawValue, privacy: .public)"
        )
        mode = newMode
        if newMode != .black { blackFrame = nil }
        if newMode != .testPattern { testPatternFrame = nil }
        if newMode != .staticNoise { noisePool = nil }
    }

    /// The buffer to send for this tick. Returns the same immutable
    /// buffer every time in `.black` / `.testPattern`, and a fresh
    /// pool-vended field of noise in `.staticNoise`.
    ///
    /// Nil only when the allocation itself failed, in which case the
    /// caller skips the send and tries again on the next tick.
    func nextFrame() -> SourceFrame? {
        switch mode {
        case .black:
            if blackFrame == nil { blackFrame = Self.renderBlack() }
            return blackFrame
        case .testPattern:
            if testPatternFrame == nil {
                testPatternFrame = Self.renderTestPattern()
            }
            return testPatternFrame
        case .staticNoise:
            return renderNoise()
        }
    }

    // MARK: - Renderers

    private static func renderBlack() -> SourceFrame? {
        guard let buffer = makeBuffer() else { return nil }
        withPixels(of: buffer) { base, bytesPerRow in
            fillOpaqueBlack(base: base, bytesPerRow: bytesPerRow)
        }
        return describing(buffer)
    }

    private static func renderTestPattern() -> SourceFrame? {
        guard let buffer = makeBuffer() else { return nil }
        withPixels(of: buffer) { base, bytesPerRow in
            fillOpaqueBlack(base: base, bytesPerRow: bytesPerRow)
        }
        withContext(over: buffer) { drawColourBars(in: $0) }
        withPixels(of: buffer) { base, bytesPerRow in
            composite(captionPlate, base: base, bytesPerRow: bytesPerRow)
        }
        return describing(buffer)
    }

    private func renderNoise() -> SourceFrame? {
        if noisePool == nil { noisePool = Self.makeNoisePool() }
        guard let noisePool else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            noisePool,
            &buffer
        )
        guard let buffer, status == kCVReturnSuccess else {
            logger.error(
                "noise pool allocation failed: \(status, privacy: .public)"
            )
            return nil
        }
        // Noise and caption share one base-address lock: the caption is
        // a straight row-wise copy now, so there's nothing left that
        // needs its own drawing pass.
        Self.withPixels(of: buffer) { base, bytesPerRow in
            fillNoise(base: base, bytesPerRow: bytesPerRow)
            Self.composite(
                Self.captionPlate,
                base: base,
                bytesPerRow: bytesPerRow
            )
        }
        return Self.describing(buffer)
    }

    /// Greyscale snow, written straight into the buffer. One xorshift
    /// step yields 32 bits, which is four pixels' worth of luma — the
    /// per-pixel cost is a shift, a mask and a store, no `arc4random`
    /// call and no allocation.
    private func fillNoise(base: UnsafeMutableRawPointer, bytesPerRow: Int) {
        var state = noiseState
        for y in 0..<Self.height {
            let row = base
                .advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt32.self)
            var x = 0
            while x < Self.width {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                var bits = state
                var lane = 0
                while lane < 4 && x < Self.width {
                    let luma = bits & 0xFF
                    row[x] = 0xFF00_0000 | (luma << 16) | (luma << 8) | luma
                    bits >>= 8
                    lane += 1
                    x += 1
                }
            }
        }
        noiseState = state
    }

    // MARK: - Caption

    /// No app name, no branding: a placeholder broadcast into someone
    /// else's call is no place for either. "NO SIGNAL" earns its place
    /// by explaining the picture; nothing else does.
    private static let captionText = "NO SIGNAL"
    private static let captionFontSize: CGFloat = 46
    private static let captionKern: CGFloat = 14
    private static let captionPadding: CGFloat = 34

    /// A centred white caption on a black plate, rasterised into a
    /// standalone BGRA tile. The plate is what makes the text legible
    /// over colour bars and over snow without per-mode tuning.
    ///
    /// Rows are top-down and `width` pixels wide — the same layout and
    /// byte order the frame buffers use, so compositing is a row-wise
    /// copy with no format handling.
    private struct CaptionPlate {
        let pixels: [UInt32]
        let width: Int
        let height: Int
        /// Top-left corner in the destination frame, in pixels.
        let originX: Int
        let originY: Int
    }

    /// Rasterised exactly once for the life of the process. The text
    /// never changes, but `.staticNoise` stamps it onto every emitted
    /// frame, and laying the glyph run out per frame — a fresh colour
    /// space, a fresh `CGContext` and a `CTLineDraw` on a
    /// `.userInteractive` queue inside a system extension — measured
    /// 27 µs a frame against 5 µs for the row copy that replaced it.
    /// Small next to the 0.6 ms noise fill it decorates, but it was
    /// also the only part of the frame that was pure waste.
    private static let captionPlate = renderCaptionPlate()

    /// Built through CoreText/CoreFoundation rather than the AppKit
    /// attribute keys so the extension keeps its dependency list to
    /// what a CMIO process should be loading.
    private static func renderCaptionPlate() -> CaptionPlate {
        let font = CTFontCreateWithName(
            "Helvetica-Bold" as CFString,
            captionFontSize,
            nil
        )
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1),
            kCTKernAttributeName: captionKern,
        ]
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            captionText as CFString,
            attributes as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advance = CGFloat(
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        )
        // Kerning is applied after the last glyph too; drop it back out
        // so the text sits optically centred rather than nudged left.
        let textWidth = advance - captionKern
        let plateWidth = Int((textWidth + captionPadding * 2).rounded())
        let plateHeight = Int((ascent + descent + captionPadding).rounded())

        // Opaque black, which is both the plate's background and the
        // alpha byte `noneSkipFirst` refuses to write.
        var pixels = [UInt32](
            repeating: 0xFF00_0000,
            count: plateWidth * plateHeight
        )
        pixels.withUnsafeMutableBytes { raw in
            guard
                let ctx = CGContext(
                    data: raw.baseAddress,
                    width: plateWidth,
                    height: plateHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: plateWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                )
            else {
                logger.error("caption plate CGContext creation failed")
                return
            }
            ctx.textPosition = CGPoint(
                x: captionPadding,
                y: captionPadding / 2 + descent
            )
            CTLineDraw(line, ctx)
        }

        // The plate is centred on both axes, so its distance from the
        // top of the frame is the same number as its CoreGraphics
        // bottom-up offset — no flip to reason about.
        return CaptionPlate(
            pixels: pixels,
            width: plateWidth,
            height: plateHeight,
            originX: (width - plateWidth) / 2,
            originY: Int(
                ((CGFloat(height) - (ascent + descent)) / 2
                    - captionPadding / 2).rounded()
            )
        )
    }

    /// Stamp the pre-rendered caption over a frame's pixels.
    private static func composite(
        _ plate: CaptionPlate,
        base: UnsafeMutableRawPointer,
        bytesPerRow: Int
    ) {
        plate.pixels.withUnsafeBufferPointer { src in
            let srcBase = src.baseAddress!
            for row in 0..<plate.height {
                base.advanced(by: (plate.originY + row) * bytesPerRow)
                    .assumingMemoryBound(to: UInt32.self)
                    .advanced(by: plate.originX)
                    .update(
                        from: srcBase.advanced(by: row * plate.width),
                        count: plate.width
                    )
            }
        }
    }

    // MARK: - Colour bars

    /// SMPTE-style 75% bars: seven equal colour bars over a reverse-blue
    /// strip over the PLUGE row. Drawn in CoreGraphics' native
    /// bottom-left origin, so the fractions below read bottom-up.
    private static func drawColourBars(in ctx: CGContext) {
        let w = CGFloat(width)
        let h = CGFloat(height)
        let bottomHeight = h * 0.25
        let stripHeight = h * 0.08
        let barsBottom = bottomHeight + stripHeight
        let seventh = w / 7

        let bars: [UInt32] = [
            0xC0C0C0, 0xC0C000, 0x00C0C0, 0x00C000,
            0xC000C0, 0xC00000, 0x0000C0,
        ]
        for (i, colour) in bars.enumerated() {
            fill(
                ctx,
                colour,
                CGRect(
                    x: CGFloat(i) * seventh,
                    y: barsBottom,
                    width: seventh,
                    height: h - barsBottom
                )
            )
        }

        let strip: [UInt32] = [
            0x0000C0, 0x131313, 0xC000C0, 0x131313,
            0x00C0C0, 0x131313, 0xC0C0C0,
        ]
        for (i, colour) in strip.enumerated() {
            fill(
                ctx,
                colour,
                CGRect(
                    x: CGFloat(i) * seventh,
                    y: bottomHeight,
                    width: seventh,
                    height: stripHeight
                )
            )
        }

        // -I, white, +Q, black, then the PLUGE triple squeezed into one
        // seventh, then black across the remaining two.
        let bottom: [UInt32] = [0x00214C, 0xFFFFFF, 0x32006A, 0x131313]
        for (i, colour) in bottom.enumerated() {
            fill(
                ctx,
                colour,
                CGRect(
                    x: CGFloat(i) * seventh,
                    y: 0,
                    width: seventh,
                    height: bottomHeight
                )
            )
        }
        let pluge: [UInt32] = [0x0A0A0A, 0x131313, 0x1D1D1D]
        let plugeWidth = seventh / 3
        for (i, colour) in pluge.enumerated() {
            fill(
                ctx,
                colour,
                CGRect(
                    x: 4 * seventh + CGFloat(i) * plugeWidth,
                    y: 0,
                    width: plugeWidth,
                    height: bottomHeight
                )
            )
        }
        fill(
            ctx,
            0x131313,
            CGRect(
                x: 5 * seventh,
                y: 0,
                width: w - 5 * seventh,
                height: bottomHeight
            )
        )
    }

    private static func fill(_ ctx: CGContext, _ rgb: UInt32, _ rect: CGRect) {
        ctx.setFillColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
        ctx.fill(rect)
    }

    // MARK: - Buffer plumbing

    private static var bufferAttributes: CFDictionary {
        [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            // IOSurface-backed, because these buffers cross the process
            // boundary into the AVCapture client exactly like the real
            // frames the host pushes through the sink do.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
    }

    private static func makeBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            bufferAttributes,
            &buffer
        )
        if status != kCVReturnSuccess {
            logger.error(
                "placeholder buffer allocation failed: \(status, privacy: .public)"
            )
        }
        return buffer
    }

    private static func makeNoisePool() -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            bufferAttributes,
            &pool
        )
        if status != kCVReturnSuccess {
            logger.error(
                "noise pool creation failed: \(status, privacy: .public)"
            )
        }
        return pool
    }

    /// Pair a rendered buffer with a format description derived from
    /// it. See `SourceFrame`.
    private static func describing(_ buffer: CVPixelBuffer) -> SourceFrame? {
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            logger.error(
                "placeholder format description failed: \(status, privacy: .public)"
            )
            return nil
        }
        return (buffer, format)
    }

    private static func fillOpaqueBlack(
        base: UnsafeMutableRawPointer,
        bytesPerRow: Int
    ) {
        for y in 0..<height {
            let row = base
                .advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt32.self)
            for x in 0..<width { row[x] = 0xFF00_0000 }
        }
    }

    /// Run `body` against the buffer's raw pixels under a single
    /// base-address lock.
    private static func withPixels(
        of buffer: CVPixelBuffer,
        _ body: (UnsafeMutableRawPointer, Int) -> Void
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        body(base, CVPixelBufferGetBytesPerRow(buffer))
    }

    /// Run `body` against a CoreGraphics context drawn straight into the
    /// buffer's pixels. `noneSkipFirst` leaves the alpha byte alone,
    /// which is why every renderer lays down opaque black first.
    private static func withContext(
        over buffer: CVPixelBuffer,
        _ body: (CGContext) -> Void
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let base = CVPixelBufferGetBaseAddress(buffer),
            let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else {
            logger.error("placeholder CGContext creation failed")
            return
        }
        body(ctx)
    }
}
