import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotesToWebKit

/// Everything here runs against video synthesised on the fly — no Notes library,
/// no personal media, nothing left behind in the temp directory.
@Suite("Video transcoder", .enabled(if: VideoTranscoder.canRunEncodingTests, "no usable hardware video encoder here"), .timeLimit(.minutes(5)))
struct VideoTranscoderTests {

    // MARK: Planning

    @Test("A small clip is never upscaled to the quality tier's dimensions")
    func neverUpscales() async throws {
        let source = try await SyntheticVideo.write(width: 320, height: 240, seconds: 1)
        defer { SyntheticVideo.remove(source) }

        let plan = try await VideoTranscoder().plan(
            for: source,
            settings: VideoEncodeSettings(quality: .high, codec: .h264, sizeBudget: nil)
        )

        #expect(plan.outputWidth == 320)
        #expect(plan.outputHeight == 240)
    }

    @Test("A tight budget pulls the bitrate below the quality ceiling")
    func budgetLowersBitrate() async throws {
        let source = try await SyntheticVideo.write(width: 320, height: 240, seconds: 2)
        defer { SyntheticVideo.remove(source) }

        let budget: Int64 = 300_000
        let plan = try await VideoTranscoder().plan(
            for: source,
            settings: VideoEncodeSettings(quality: .high, codec: .h264, sizeBudget: budget)
        )

        #expect(plan.videoBitrate < VideoQuality.high.videoBitrateCeiling)
        #expect(plan.videoBitrate > 400_000)
        #expect(plan.estimatedByteCount <= budget)
        #expect(!plan.exceedsBudget)
    }

    @Test("An impossible budget is reported, not thrown")
    func impossibleBudgetIsReported() async throws {
        let source = try await SyntheticVideo.write(width: 320, height: 240, seconds: 2)
        defer { SyntheticVideo.remove(source) }

        let plan = try await VideoTranscoder().plan(
            for: source,
            settings: VideoEncodeSettings(quality: .balanced, codec: .h264, sizeBudget: 1_000)
        )

        #expect(plan.exceedsBudget)
        #expect(plan.videoBitrate == 400_000)
        #expect(plan.outputWidth > 0)
    }

    @Test("HEVC plans a lower bitrate than H.264 at the same quality tier")
    func hevcCostsLessBitrate() async throws {
        // High bitrate so neither plan short-circuits into passthrough.
        let source = try await SyntheticVideo.write(width: 640, height: 480, seconds: 1, bitrate: 8_000_000)
        defer { SyntheticVideo.remove(source) }

        let transcoder = VideoTranscoder()
        let h264 = try await transcoder.plan(
            for: source, settings: VideoEncodeSettings(quality: .balanced, codec: .h264, sizeBudget: nil)
        )
        let hevc = try await transcoder.plan(
            for: source, settings: VideoEncodeSettings(quality: .balanced, codec: .hevc, sizeBudget: nil)
        )

        #expect(hevc.videoBitrate < h264.videoBitrate)
        #expect(hevc.estimatedByteCount < h264.estimatedByteCount)
    }

    @Test("Scaled dimensions are always even")
    func dimensionsAreEven() async throws {
        // 1004 * (1280/1920) is 669.33: naive rounding lands on an odd number.
        let source = try await SyntheticVideo.write(width: 1920, height: 1004, seconds: 0.5)
        defer { SyntheticVideo.remove(source) }

        let plan = try await VideoTranscoder().plan(
            for: source,
            settings: VideoEncodeSettings(quality: .small, codec: .h264, sizeBudget: nil)
        )

        #expect(plan.outputWidth == 1280)
        #expect(plan.outputHeight == 670)
        #expect(plan.outputWidth.isMultiple(of: 2))
        #expect(plan.outputHeight.isMultiple(of: 2))
    }

    @Test("A big high-bitrate clip does not qualify for passthrough")
    func bigClipDoesNotPassThrough() async throws {
        let source = try await SyntheticVideo.write(width: 1920, height: 1080, seconds: 1, bitrate: 15_000_000)
        defer { SyntheticVideo.remove(source) }

        let plan = try await VideoTranscoder().plan(for: source, settings: .webDefault)
        #expect(!plan.passesThrough)
    }

    // MARK: Transcoding

    @Test("Downscaling produces a playable, much smaller file")
    func downscaleRoundTrip() async throws {
        let source = try await SyntheticVideo.write(
            width: 1920, height: 1080, seconds: 1.5, bitrate: 15_000_000, withAudio: true
        )
        let destination = SyntheticVideo.scratchURL()
        defer {
            SyntheticVideo.remove(source)
            SyntheticVideo.remove(destination)
        }

        let transcoder = VideoTranscoder()
        let plan = try await transcoder.plan(
            for: source,
            settings: VideoEncodeSettings(quality: .small, codec: .h264, sizeBudget: nil)
        )
        #expect(plan.outputWidth == 1280)
        #expect(plan.outputHeight == 720)
        #expect(plan.audioBitrate == 96_000)

        let recorder = ProgressRecorder()
        let started = Date()
        try await transcoder.transcode(source: source, to: destination, plan: plan) { recorder.record($0) }
        let elapsed = Date().timeIntervalSince(started)

        #expect(recorder.last == 1.0)
        #expect(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))

        let output = AVURLAsset(url: destination)
        let track = try #require(try await output.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 1280)
        #expect(Int(size.height) == 720)
        #expect(try await !output.loadTracks(withMediaType: .audio).isEmpty)

        let sourceBytes = SyntheticVideo.byteCount(source)
        let outputBytes = SyntheticVideo.byteCount(destination)
        #expect(outputBytes > 0)
        #expect(outputBytes < sourceBytes / 2)

        // Rough throughput signal for a note full of clips; not an assertion.
        print("""
        transcode 1920x1080 -> \(plan.outputWidth)x\(plan.outputHeight), \
        \(String(format: "%.1f", plan.durationSeconds))s of video in \
        \(String(format: "%.2f", elapsed))s \
        (\(String(format: "%.1f", plan.durationSeconds / elapsed))x realtime), \
        \(sourceBytes) -> \(outputBytes) bytes
        """)
    }

    @Test("A clip that needs no scaling still re-encodes to the planned size")
    func sameSizeRoundTrip() async throws {
        let source = try await SyntheticVideo.write(width: 640, height: 480, seconds: 1, bitrate: 8_000_000)
        let destination = SyntheticVideo.scratchURL()
        defer {
            SyntheticVideo.remove(source)
            SyntheticVideo.remove(destination)
        }

        let transcoder = VideoTranscoder()
        let plan = try await transcoder.plan(
            for: source,
            settings: VideoEncodeSettings(quality: .small, codec: .h264, sizeBudget: nil)
        )
        #expect(plan.outputWidth == 640)

        let recorder = ProgressRecorder()
        try await transcoder.transcode(source: source, to: destination, plan: plan) { recorder.record($0) }

        #expect(recorder.last == 1.0)
        let track = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 640)
        #expect(Int(size.height) == 480)
    }

    @Test("HEVC output really is HEVC")
    func hevcRoundTrip() async throws {
        let source = try await SyntheticVideo.write(width: 640, height: 480, seconds: 1, bitrate: 8_000_000)
        let destination = SyntheticVideo.scratchURL()
        defer {
            SyntheticVideo.remove(source)
            SyntheticVideo.remove(destination)
        }

        let transcoder = VideoTranscoder()
        let plan = try await transcoder.plan(
            for: source,
            settings: VideoEncodeSettings(quality: .small, codec: .hevc, sizeBudget: nil)
        )
        try await transcoder.transcode(source: source, to: destination, plan: plan) { _ in }

        let track = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(format.mediaSubType.rawValue == kCMVideoCodecType_HEVC)
    }

    @Test("Cancelling leaves no half-written file behind")
    func cancellationCleansUp() async throws {
        let source = try await SyntheticVideo.write(width: 1920, height: 1080, seconds: 3, bitrate: 20_000_000)
        let destination = SyntheticVideo.scratchURL()
        defer {
            SyntheticVideo.remove(source)
            SyntheticVideo.remove(destination)
        }

        let transcoder = VideoTranscoder()
        let plan = try await transcoder.plan(
            for: source,
            settings: VideoEncodeSettings(quality: .small, codec: .h264, sizeBudget: nil)
        )

        let task = Task {
            try await transcoder.transcode(source: source, to: destination, plan: plan) { _ in }
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    // MARK: Budget accuracy

    @Test("A high frame rate costs budget, because sample tables are per-frame")
    func frameRateChangesTheBudget() async throws {
        // Same pictures, same duration, same budget — only the frame count differs.
        let slow = try await SyntheticVideo.write(width: 640, height: 480, seconds: 2, fps: 30)
        let fast = try await SyntheticVideo.write(width: 640, height: 480, seconds: 2, fps: 240)
        defer {
            SyntheticVideo.remove(slow)
            SyntheticVideo.remove(fast)
        }

        let transcoder = VideoTranscoder()
        let settings = VideoEncodeSettings(quality: .high, codec: .h264, sizeBudget: 400_000)
        let slowPlan = try await transcoder.plan(for: slow, settings: settings)
        let fastPlan = try await transcoder.plan(for: fast, settings: settings)

        // 240 fps carries eight times the sample-table weight, so less of the
        // budget is left for pictures. A flat percentage margin cannot see this.
        #expect(fastPlan.videoBitrate < slowPlan.videoBitrate)
        #expect(fastPlan.estimatedByteCount <= 400_000)
        #expect(slowPlan.estimatedByteCount <= 400_000)
    }

    @Test("A frame-dense clip on a tight budget really lands under it")
    func denseClipRespectsBudget() async throws {
        // The shape of the defect this test exists for: many frames, few bytes per
        // frame, so container overhead is a large fraction of the file and the
        // encoder's overshoot has nowhere to hide.
        // 480 frames in 400 KB: the sample tables alone are ~2.5% of the file,
        // the same proportion that pushed real 4K footage over its budget. Not so
        // dense that bits-per-frame becomes the binding constraint, which is a
        // different problem the budget cannot solve.
        let source = try await SyntheticVideo.write(
            width: 640, height: 480, seconds: 4, fps: 120, bitrate: 12_000_000, content: .blocks
        )
        let destination = SyntheticVideo.scratchURL()
        defer {
            SyntheticVideo.remove(source)
            SyntheticVideo.remove(destination)
        }

        let budget: Int64 = 400_000
        let transcoder = VideoTranscoder()
        let plan = try await transcoder.plan(
            for: source,
            settings: VideoEncodeSettings(quality: .high, codec: .h264, sizeBudget: budget)
        )
        #expect(!plan.exceedsBudget)
        #expect(plan.estimatedByteCount <= budget)

        let result = try await transcoder.transcode(
            source: source, to: destination, plan: plan
        ) { _ in }

        let actual = SyntheticVideo.byteCount(destination)
        #expect(actual <= budget, "landed at \(actual) against a \(budget) budget")
        #expect(!result.exceedsBudget)
        #expect(result.byteCount == actual)
        // Real footage fits on the first pass; this synthetic blocky content is
        // harder to predict and sometimes needs the corrective one. Either is a
        // pass — what matters is that it converges rather than shipping oversize.
        #expect(result.passes <= 2)
    }

    @Test("An overshooting first pass is corrected, not shipped")
    func overshootTriggersACorrectivePass() async throws {
        let source = try await SyntheticVideo.write(
            width: 640, height: 480, seconds: 2, bitrate: 12_000_000, content: .blocks
        )
        let destination = SyntheticVideo.scratchURL()
        defer {
            SyntheticVideo.remove(source)
            SyntheticVideo.remove(destination)
        }

        // A deliberately dishonest plan: a bitrate that cannot possibly fit the
        // ceiling it claims to respect. Nothing `plan(for:)` produces looks like
        // this, which is exactly why the safety net needs its own test.
        let ceiling: Int64 = 250_000
        let plan = TranscodePlan(
            outputWidth: 640, outputHeight: 480,
            videoBitrate: 4_000_000, audioBitrate: 0, codec: .h264,
            durationSeconds: 2, sourceByteCount: SyntheticVideo.byteCount(source),
            estimatedByteCount: 1_000_000,
            passesThrough: false, exceedsBudget: false,
            byteCeiling: ceiling
        )

        let result = try await VideoTranscoder().transcode(
            source: source, to: destination, plan: plan
        ) { _ in }

        let actual = SyntheticVideo.byteCount(destination)
        #expect(actual <= ceiling, "landed at \(actual) against a \(ceiling) ceiling")
        #expect(result.passes == 2)
        #expect(!result.exceedsBudget)
    }

    @Test("A clip that cannot fit is reported, and not re-encoded pointlessly")
    func hopelessClipIsNotRetried() async throws {
        let source = try await SyntheticVideo.write(
            width: 640, height: 480, seconds: 2, bitrate: 12_000_000
        )
        let destination = SyntheticVideo.scratchURL()
        defer {
            SyntheticVideo.remove(source)
            SyntheticVideo.remove(destination)
        }

        let transcoder = VideoTranscoder()
        let plan = try await transcoder.plan(
            for: source,
            settings: VideoEncodeSettings(quality: .small, codec: .h264, sizeBudget: 5_000)
        )
        #expect(plan.exceedsBudget)
        #expect(plan.videoBitrate == 400_000)

        // Reported, not thrown, and no corrective pass to chase an impossible target.
        let result = try await transcoder.transcode(
            source: source, to: destination, plan: plan
        ) { _ in }
        #expect(result.passes == 1)
        #expect(result.exceedsBudget)
        #expect(SyntheticVideo.byteCount(destination) > 0)
    }

    @Test("A file with no video track fails with a message naming it")
    func missingVideoTrackIsActionable() async throws {
        let url = SyntheticVideo.scratchURL(extension: "mp4")
        try Data("not a movie".utf8).write(to: url)
        defer { SyntheticVideo.remove(url) }

        await #expect(throws: VideoTranscodeError.self) {
            try await VideoTranscoder().plan(for: url, settings: .webDefault)
        }

        let message = (VideoTranscodeError.noVideoTrack(url) as LocalizedError).errorDescription ?? ""
        #expect(message.contains(url.lastPathComponent))
        #expect(!message.contains("Error Domain"))
    }
}

// MARK: - Helpers

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0

    var last: Double { lock.withLock { value } }
    func record(_ fraction: Double) { lock.withLock { value = max(value, fraction) } }
}

/// Writes throwaway MP4s so the tests never touch real media.
/// Shared with `ExporterTests`, which needs the same fixtures end to end.
enum SyntheticVideo {

    static func scratchURL(extension ext: String = "mp4") -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "notes-to-web-transcoder-\(UUID().uuidString).\(ext)", directoryHint: .notDirectory)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func byteCount(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    /// What the frames look like. This matters more than it sounds: an encoder
    /// asked for 500 kbps will only deliver it if the content can *be* compressed
    /// that far, and the two cases below sit at opposite ends of that.
    enum Content {
        /// Per-pixel noise. Incompressible — the encoder blows past any low
        /// bitrate target because max quantisation still cannot shrink it. Use it
        /// to prove output is smaller than a fat source, never to test a budget.
        case noise
        /// 16-pixel blocks of flat colour, scrolling. Detailed enough that the
        /// encoder spends its whole allowance, compressible enough that it can
        /// actually hit a low target. This is the one budgets can be tested with.
        case blocks
    }

    /// One block of randomness, reused by every frame: filling rows from a
    /// shifting offset into it is memcpy-fast but still defeats intra prediction
    /// and motion estimation. A solid colour would collapse to a few kilobytes
    /// and make the "smaller output" assertions meaningless.
    private static let noise: [UInt8] = randomBytes(runLength: 1)
    /// The same idea at 1/16 the spatial frequency.
    private static let blocks: [UInt8] = randomBytes(runLength: 16)

    private static func randomBytes(runLength: Int) -> [UInt8] {
        var seed = [UInt8](repeating: 0, count: 8_192 / runLength + 1)
        seed.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        var out = [UInt8]()
        out.reserveCapacity(8_192 + runLength)
        for byte in seed { out.append(contentsOf: repeatElement(byte, count: runLength)) }
        return out
    }

    /// A clip whose luma is high-frequency and changes every frame.
    static func write(
        width: Int,
        height: Int,
        seconds: Double,
        fps: Int32 = 24,
        bitrate: Int = 10_000_000,
        withAudio: Bool = false,
        content: Content = .noise
    ) async throws -> URL {
        let url = scratchURL()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw TestVideoError.setupFailed(writer.error?.localizedDescription ?? "startWriting refused")
        }
        writer.startSession(atSourceTime: .zero)

        // Audio has to be interleaved with video as we go. Writing every video
        // frame first and the audio afterwards stalls the writer on anything
        // longer than a second or two.
        let frameCount = max(1, Int(seconds * Double(fps)))
        var audioBuffersWritten = 0
        for frame in 0..<frameCount {
            try await waitForReady(videoInput, writer: writer)
            guard let pool = adaptor.pixelBufferPool else {
                throw TestVideoError.setupFailed("no pixel buffer pool")
            }
            let buffer = try makeFrame(pool: pool, frame: frame, content: content)
            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw TestVideoError.setupFailed(writer.error?.localizedDescription ?? "frame rejected")
            }

            if let audioInput {
                let wanted = Int(Double(frame + 1) / Double(fps) * 44_100) / audioFramesPerBuffer
                while audioBuffersWritten < wanted {
                    try await waitForReady(audioInput, writer: writer)
                    try appendSilence(to: audioInput, index: audioBuffersWritten)
                    audioBuffersWritten += 1
                }
            }
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TestVideoError.setupFailed(writer.error?.localizedDescription ?? "writer stopped early")
        }
        return url
    }

    private static func makeFrame(
        pool: CVPixelBufferPool,
        frame: Int,
        content: Content
    ) throws -> CVPixelBuffer {
        var pooled: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pooled) == kCVReturnSuccess,
              let buffer = pooled
        else { throw TestVideoError.setupFailed("could not allocate a frame") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let pattern = content == .noise ? noise : blocks
            let columns = min(CVPixelBufferGetWidthOfPlane(buffer, 0), pattern.count - 256)
            pattern.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                for row in 0..<rows {
                    let offset = (row &* 37 &+ frame &* 131) % 256
                    memcpy(luma.advanced(by: row * stride), base.advanced(by: offset), columns)
                }
            }
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, 1)
            memset(chroma, 128, stride * rows)
        }
        return buffer
    }

    /// Spin until the writer wants more, but never forever: a stalled writer is a
    /// broken fixture, and a hung test is far harder to diagnose than a failed one.
    private static func waitForReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw TestVideoError.setupFailed(writer.error?.localizedDescription ?? "writer stopped")
            }
            guard Date() < deadline else { throw TestVideoError.setupFailed("writer stalled") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    static let audioFramesPerBuffer = 1_024

    private static let pcmFormat: CMAudioFormatDescription? = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr else { return nil }
        return format
    }()

    private static func appendSilence(to input: AVAssetWriterInput, index: Int) throws {
        guard let format = pcmFormat else {
            throw TestVideoError.setupFailed("could not describe PCM audio")
        }
        let bytes = audioFramesPerBuffer * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block else {
            throw TestVideoError.setupFailed("could not allocate audio")
        }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)

        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: CMItemCount(audioFramesPerBuffer),
            presentationTimeStamp: CMTime(
                value: CMTimeValue(index * audioFramesPerBuffer),
                timescale: 44_100
            ),
            packetDescriptions: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            throw TestVideoError.setupFailed("could not package audio")
        }
        guard input.append(sample) else {
            throw TestVideoError.setupFailed("audio rejected")
        }
    }
}

private enum TestVideoError: Error {
    case setupFailed(String)
}
