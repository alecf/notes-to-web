import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Metal
import VideoToolbox

// MARK: - Settings

public enum VideoCodec: String, Sendable, Codable, CaseIterable, Identifiable {
    case h264
    case hevc

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }

    public var detail: String {
        switch self {
        case .h264: "Plays everywhere"
        case .hevc: "~40% smaller, not supported by every browser"
        }
    }

    /// HEVC reaches comparable quality at roughly 60% of H.264's bitrate, so the
    /// quality tiers have to be scaled per codec or choosing HEVC would not
    /// actually produce a smaller file.
    var bitrateFactor: Double {
        switch self {
        case .h264: 1.0
        case .hevc: 0.6
        }
    }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        }
    }
}

public enum VideoQuality: String, Sendable, Codable, CaseIterable, Identifiable {
    case high
    case balanced
    case small

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .high: "High"
        case .balanced: "Balanced"
        case .small: "Small"
        }
    }

    public var detail: String {
        switch self {
        case .high: "1080p, up to 6 Mbps"
        case .balanced: "1080p, up to 3.5 Mbps"
        case .small: "720p, up to 1.5 Mbps"
        }
    }

    /// Ceiling on the *long* edge, so portrait phone video keeps its orientation.
    var maxDimension: Int {
        switch self {
        case .high, .balanced: 1920
        case .small: 1280
        }
    }

    /// H.264 bitrate ceiling; `VideoCodec.bitrateFactor` scales it per codec.
    var videoBitrateCeiling: Int {
        switch self {
        case .high: 6_000_000
        case .balanced: 3_500_000
        case .small: 1_500_000
        }
    }

    var audioBitrate: Int {
        switch self {
        case .high, .balanced: 128_000
        case .small: 96_000
        }
    }
}

public struct VideoEncodeSettings: Sendable, Codable, Hashable {
    public var quality: VideoQuality
    public var codec: VideoCodec
    /// Hard per-file ceiling in bytes. Bitrate is lowered as needed to land under
    /// it. `nil` means the quality tier alone decides.
    public var sizeBudget: Int64?

    public init(
        quality: VideoQuality = .balanced,
        codec: VideoCodec = .h264,
        sizeBudget: Int64? = VideoEncodeSettings.defaultSizeBudget
    ) {
        self.quality = quality
        self.codec = codec
        self.sizeBudget = sizeBudget
    }

    /// 22 MiB — under Cloudflare's 25 MiB per-asset limit with headroom for
    /// container overhead and for hosts that count a little differently.
    public static let defaultSizeBudget: Int64 = 22 * 1024 * 1024

    public static let webDefault = VideoEncodeSettings(
        quality: .balanced,
        codec: .h264,
        sizeBudget: defaultSizeBudget
    )
}

// MARK: - Plan

public struct TranscodePlan: Sendable, Hashable {
    public let outputWidth: Int
    public let outputHeight: Int
    public let videoBitrate: Int
    public let audioBitrate: Int
    public let codec: VideoCodec
    public let durationSeconds: Double
    public let sourceByteCount: Int64
    public let estimatedByteCount: Int64
    /// The source is already small and low-bitrate enough; re-encoding would only
    /// lose quality.
    public let passesThrough: Bool
    /// Even at the minimum sane bitrate the output will not fit `sizeBudget`.
    public let exceedsBudget: Bool
    /// The ceiling this plan was built for, carried so `transcode` can check the
    /// finished file against it rather than trusting the estimate. `nil` when the
    /// settings imposed no budget.
    public let byteCeiling: Int64?
}

/// What actually came out, as opposed to what the plan hoped for.
public struct TranscodeResult: Sendable, Hashable {
    public let byteCount: Int64
    /// The file is over `TranscodePlan.byteCeiling` even after a corrective pass.
    /// It plays fine; it is just larger than the host will accept. Callers should
    /// say so rather than letting a doomed upload be discovered later.
    public let exceedsBudget: Bool
    /// 1 normally, 2 when the first attempt overshot and had to be redone.
    public let passes: Int
}

// MARK: - Errors

public enum VideoTranscodeError: Error, LocalizedError {
    case unreadable(URL, reason: String)
    case noVideoTrack(URL)
    case encoderUnavailable(URL, VideoCodec)
    case encodeFailed(URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let reason):
            "\(url.lastPathComponent) could not be read: \(reason)."
        case .noVideoTrack(let url):
            "\(url.lastPathComponent) has no video track, so there is nothing to re-encode."
        case .encoderUnavailable(let url, let codec):
            "This Mac has no \(codec.displayName) encoder for \(url.lastPathComponent)'s dimensions. Try the other codec."
        case .encodeFailed(let url, let reason):
            "\(url.lastPathComponent) could not be compressed: \(reason)."
        }
    }
}

// MARK: - Transcoder

/// Re-encodes phone video down to something a static host will actually serve.
///
/// Planning is separated from encoding so callers can show the damage — or warn
/// about a clip that cannot fit — before committing to minutes of work.
public actor VideoTranscoder {
    /// Never go below this, budget or not: past here the video is mush and file
    /// size has stopped being the interesting problem.
    private static let minimumVideoBitrate = 400_000

    /// MP4 sample tables cost a fixed handful of bytes for *every frame* —
    /// offset, size, duration, composition offset — regardless of how few bytes
    /// that frame's picture took. So container overhead scales with frame count,
    /// not with file size, and no flat percentage can model it: a 120 s 240 fps
    /// clip carries 28,805 frames and spends 0.58 MiB on tables alone, which at a
    /// budget-constrained 1.5 Mbps is 2.6% of the file. Measured at 21.0
    /// bytes/frame on our own encoder settings; 24 leaves room to be wrong.
    private static let containerBytesPerVideoFrame = 24.0
    private static let containerBytesPerAudioPacket = 10.0
    /// Atoms that do not scale with anything. Measured at ~1.4 KiB; 16 KiB is
    /// generous without eating a small clip's whole budget.
    private static let containerFixedBytes = 16_384.0

    /// `AVVideoAverageBitRateKey` is a target the encoder aims at, not a ceiling
    /// it respects, and it runs over on sustained high-motion content. Measured
    /// at +2.2% on 4K nature footage downscaled to 1080p; budget for 6%.
    private static let encoderOvershoot = 1.06

    /// Downscaling stays inside VideoToolbox: it works natively on the biplanar
    /// YCbCr buffers the decoder hands us, so there is no YCbCr -> RGB -> YCbCr
    /// round trip and no CPU-side pixel work at all. Created once per file.
    private var pixelTransfer: VTPixelTransferSession?
    /// Fallback for the rare buffer VideoToolbox refuses to transfer. Bound to the
    /// GPU explicitly — a default `CIContext()` scales on the CPU and is far slower.
    private var scalingContext: CIContext?

    public init() {}

    // MARK: Planning

    public func plan(for source: URL, settings: VideoEncodeSettings) async throws -> TranscodePlan {
        let asset = AVURLAsset(url: source)

        let duration: CMTime
        let videoTrack: AVAssetTrack?
        let hasAudio: Bool
        do {
            duration = try await asset.load(.duration)
            videoTrack = try await asset.loadTracks(withMediaType: .video).first
            hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        } catch {
            throw VideoTranscodeError.unreadable(source, reason: error.localizedDescription)
        }

        guard let videoTrack else { throw VideoTranscodeError.noVideoTrack(source) }

        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            throw VideoTranscodeError.unreadable(source, reason: "it reports no duration")
        }

        let naturalSize: CGSize
        let formats: [CMFormatDescription]
        let frameRate: Float
        do {
            (naturalSize, formats, frameRate) = try await videoTrack.load(
                .naturalSize, .formatDescriptions, .nominalFrameRate
            )
        } catch {
            throw VideoTranscodeError.unreadable(source, reason: error.localizedDescription)
        }

        // Work in storage space: orientation is carried by the rotation matrix,
        // not by swapping width and height.
        let sourceWidth = abs(naturalSize.width)
        let sourceHeight = abs(naturalSize.height)
        guard sourceWidth >= 1, sourceHeight >= 1 else {
            throw VideoTranscodeError.unreadable(source, reason: "its video track has no usable dimensions")
        }

        let sourceBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        // Never upscale: a 480p clip stays 480p no matter which tier is chosen.
        let scale = min(1, Double(settings.quality.maxDimension) / Double(max(sourceWidth, sourceHeight)))
        let outputWidth = Self.evenDimension(Double(sourceWidth) * scale)
        let outputHeight = Self.evenDimension(Double(sourceHeight) * scale)

        let audioBitrate = hasAudio ? settings.quality.audioBitrate : 0
        let ceiling = Int((Double(settings.quality.videoBitrateCeiling) * settings.codec.bitrateFactor).rounded())
        let floor = Int((Double(Self.minimumVideoBitrate) * settings.codec.bitrateFactor).rounded())

        let overhead = Self.containerOverhead(
            seconds: seconds,
            frameRate: frameRate,
            hasAudio: hasAudio
        )

        var videoBitrate = ceiling
        var exceedsBudget = false
        if let budget = settings.sizeBudget {
            // Only what is left after the container has taken its cut can be spent
            // on pictures, and the encoder needs headroom on top of that.
            let payloadBits = Double(max(0, budget - overhead)) * 8
            let affordable = (payloadBits / seconds - Double(audioBitrate)) / Self.encoderOvershoot
            videoBitrate = min(ceiling, Int(affordable.rounded(.down)))
            if videoBitrate < floor {
                // Still a valid plan — the caller warns rather than refusing to export.
                videoBitrate = floor
                exceedsBudget = true
            }
        }

        var estimated = Self.estimatedSize(
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate,
            seconds: seconds,
            overhead: overhead
        )
        if let budget = settings.sizeBudget, estimated > budget { exceedsBudget = true }

        let sourceBitrate = sourceBytes > 0 ? Double(sourceBytes) * 8 / seconds : .infinity
        let fitsBudget = settings.sizeBudget.map { sourceBytes > 0 && sourceBytes <= $0 } ?? true
        let passesThrough = scale == 1
            && sourceBitrate <= Double(videoBitrate + audioBitrate)
            && fitsBudget
            && Self.isWebPlayableCodec(formats)
        if passesThrough { estimated = sourceBytes }

        return TranscodePlan(
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate,
            codec: settings.codec,
            durationSeconds: seconds,
            sourceByteCount: sourceBytes,
            estimatedByteCount: estimated,
            passesThrough: passesThrough,
            exceedsBudget: exceedsBudget,
            byteCeiling: settings.sizeBudget
        )
    }

    private static func frameRate(of source: URL) async -> Float {
        guard let track = try? await AVURLAsset(url: source).loadTracks(withMediaType: .video).first,
              let rate = try? await track.load(.nominalFrameRate), rate > 0
        else { return 30 }
        return rate
    }

    /// What the MP4 container itself will cost, before a single picture byte.
    private static func containerOverhead(seconds: Double, frameRate: Float, hasAudio: Bool) -> Int64 {
        let fps = frameRate > 0 ? Double(frameRate) : 30
        let videoFrames = seconds * fps
        // AAC packets are 1024 samples each at the 44.1 kHz we re-encode to.
        let audioPackets = hasAudio ? seconds * 44_100 / 1_024 : 0
        return Int64(
            videoFrames * containerBytesPerVideoFrame
                + audioPackets * containerBytesPerAudioPacket
                + containerFixedBytes
        )
    }

    private static func estimatedSize(
        videoBitrate: Int,
        audioBitrate: Int,
        seconds: Double,
        overhead: Int64
    ) -> Int64 {
        let payload = (Double(videoBitrate) * encoderOvershoot + Double(audioBitrate)) * seconds / 8
        return Int64(payload.rounded()) + overhead
    }

    /// H.264 requires even dimensions, and odd ones make some encoders fail outright.
    private static func evenDimension(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }

    /// ProRes and friends decode fine but are useless on the web, so they never
    /// pass through no matter how small the file is.
    private static func isWebPlayableCodec(_ formats: [CMFormatDescription]) -> Bool {
        let hev1 = FourCharCode(0x6865_7631)
        let avc3 = FourCharCode(0x6176_6333)
        return !formats.isEmpty && formats.allSatisfy { format in
            switch format.mediaSubType.rawValue {
            case kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, hev1, avc3: true
            default: false
            }
        }
    }

    // MARK: Transcoding

    /// Writes an MP4 with the moov atom first (faststart), reporting 0...1.
    ///
    /// When the plan carries a `byteCeiling`, the finished file is measured
    /// against it and re-encoded once under a hard rate cap if it came out over.
    /// That second pass restarts progress at 0 — it is rare, and reporting it is
    /// better than a bar that sits at 1.0 for another minute.
    ///
    /// Throws `CancellationError` if the surrounding task is cancelled; either way
    /// the partial file is deleted rather than left looking like a finished export.
    ///
    /// The return value is discardable, but callers that set a budget should check
    /// `exceedsBudget` — some clips cannot be made to fit at any bitrate.
    @discardableResult
    public func transcode(
        source: URL,
        to destination: URL,
        plan: TranscodePlan,
        progress: @Sendable (Double) -> Void
    ) async throws -> TranscodeResult {
        let written = try await encode(
            source: source, to: destination, plan: plan,
            videoBitrate: plan.videoBitrate, hardCapBytesPerSecond: nil,
            progress: progress
        )

        // A plan that already knows it cannot fit was clamped to the minimum
        // bitrate; a second pass would only make it uglier, not smaller.
        guard let ceiling = plan.byteCeiling, written > ceiling, !plan.exceedsBudget else {
            progress(1.0)
            return TranscodeResult(
                byteCount: written,
                exceedsBudget: plan.byteCeiling.map { written > $0 } ?? false,
                passes: 1
            )
        }

        // The estimate was wrong for this content, so stop estimating. Aim a hard
        // `DataRateLimits` cap straight at the ceiling: `AVVideoAverageBitRateKey`
        // is a target the encoder may miss, but `DataRateLimits` is enforced.
        // Scaling the planned bitrate by how far it missed would be sharper, but
        // it assumes the first pass hit its own target — and it demonstrably did
        // not, which is why we are here.
        //
        // VideoToolbox enforces conservatively, landing around 30% under whatever
        // cap it is given. That undershoot is quality we would rather have spent,
        // but this pass only runs when the estimate has already failed once, and
        // a file the host will accept beats a sharper one it will reject.
        //
        // The cap governs the elementary stream, so the container's cut has to
        // come off the ceiling first, and 5% is held back because the cap is not
        // quite absolute on very short clips.
        let frameRate = await Self.frameRate(of: source)
        let overhead = Self.containerOverhead(
            seconds: plan.durationSeconds,
            frameRate: frameRate,
            hasAudio: plan.audioBitrate > 0
        )
        let payloadCeiling = Double(max(0, ceiling - overhead)) * 0.95
        let floor = Int((Double(Self.minimumVideoBitrate) * plan.codec.bitrateFactor).rounded())
        let capBitsPerSecond = max(
            floor,
            Int(payloadCeiling * 8 / plan.durationSeconds) - plan.audioBitrate
        )
        let corrected = try await encode(
            source: source, to: destination, plan: plan,
            videoBitrate: capBitsPerSecond, hardCapBytesPerSecond: capBitsPerSecond / 8,
            progress: progress
        )
        progress(1.0)
        // Frame-dense clips have a floor on bits *per frame* that no bitrate cap
        // can push past — 240 fps slow motion on a small budget can simply be
        // impossible. Say so instead of pretending.
        return TranscodeResult(
            byteCount: corrected,
            exceedsBudget: corrected > ceiling,
            passes: 2
        )
    }

    /// One encode from start to finish. Returns the size of the file it wrote.
    private func encode(
        source: URL,
        to destination: URL,
        plan: TranscodePlan,
        videoBitrate: Int,
        hardCapBytesPerSecond: Int?,
        progress: @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let asset = AVURLAsset(url: source)

        let videoTrack: AVAssetTrack?
        let audioTrack: AVAssetTrack?
        do {
            videoTrack = try await asset.loadTracks(withMediaType: .video).first
            audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        } catch {
            throw VideoTranscodeError.unreadable(source, reason: error.localizedDescription)
        }
        guard let videoTrack else { throw VideoTranscodeError.noVideoTrack(source) }

        let naturalSize: CGSize
        let transform: CGAffineTransform
        let frameRate: Float
        let timeRange: CMTimeRange
        do {
            (naturalSize, transform, frameRate, timeRange) = try await videoTrack.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .timeRange
            )
        } catch {
            throw VideoTranscodeError.unreadable(source, reason: error.localizedDescription)
        }
        let startTime = timeRange.start

        try? FileManager.default.removeItem(at: destination)

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        } catch {
            throw VideoTranscodeError.encodeFailed(source, reason: error.localizedDescription)
        }
        // Moov atom up front so browsers can start playing before the whole file
        // has arrived.
        writer.shouldOptimizeForNetworkUse = true

        // MARK: video

        let needsScaling = Int(abs(naturalSize.width)) != plan.outputWidth
            || Int(abs(naturalSize.height)) != plan.outputHeight

        // 420v end to end — decode, scale and encode all speak the same biplanar
        // format, so nothing has to convert pixels behind our back.
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw VideoTranscodeError.unreadable(source, reason: "its video track could not be decoded")
        }
        reader.add(videoOutput)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrate,
            AVVideoExpectedSourceFrameRateKey: Int(frameRate > 0 ? frameRate.rounded() : 30),
            // Two-second GOP: without it the encoder emits very few keyframes and
            // scrubbing the exported page becomes unusable.
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if plan.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        if let cap = hardCapBytesPerSecond {
            // [bytes, seconds]: no more than this many bytes in any window that
            // long. AVFoundation forwards unrecognised compression properties
            // straight to VTCompressionSessionSetProperty, which is how a raw
            // VideoToolbox key reaches the encoder at all.
            compression[kVTCompressionPropertyKey_DataRateLimits as String] =
                [NSNumber(value: cap), NSNumber(value: 1.0)] as CFArray
        }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: plan.codec.avCodecType,
            AVVideoWidthKey: plan.outputWidth,
            AVVideoHeightKey: plan.outputHeight,
            AVVideoCompressionPropertiesKey: compression,
        ]
        // VideoToolbox ships a software avc1/hvc1 encoder alongside the hardware
        // one and will silently pick it. Rule it out where hardware exists — the
        // difference across a note full of clips is minutes. Asking for hardware
        // that is not there is a hard failure, so only ask when it is listed.
        if Self.hasHardwareEncoder(for: plan.codec) {
            videoSettings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
            ] as [String: Any]
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw VideoTranscodeError.encoderUnavailable(source, plan.codec)
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // Orientation stays in the rotation matrix, exactly as the passthrough
        // remux leaves it, so playback looks the same either way.
        videoInput.transform = transform
        writer.add(videoInput)

        let adaptor: AVAssetWriterInputPixelBufferAdaptor? = needsScaling
            ? AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferWidthKey as String: plan.outputWidth,
                    kCVPixelBufferHeightKey as String: plan.outputHeight,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ]
            )
            : nil
        if needsScaling { prepareScaler() }

        // MARK: audio

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack, plan.audioBitrate > 0 {
            let channels = min(2, await Self.channelCount(of: audioTrack))
            let layoutData = Self.channelLayout(channels: channels)

            // Decoding straight to the target rate and channel count means the
            // writer only has to encode, never resample.
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: channels,
                    AVChannelLayoutKey: layoutData,
                ]
            )
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVNumberOfChannelsKey: channels,
                        AVSampleRateKey: 44_100,
                        AVEncoderBitRateKey: plan.audioBitrate,
                        AVChannelLayoutKey: layoutData,
                    ]
                )
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                audioOutput = output
                audioInput = input
            }
            // A track we cannot decode is not worth failing the whole export over;
            // the video still exports, silently.
        }

        // MARK: run

        guard writer.startWriting() else {
            throw VideoTranscodeError.encodeFailed(
                source,
                reason: writer.error?.localizedDescription ?? "the encoder refused to start"
            )
        }
        writer.startSession(atSourceTime: startTime)
        guard reader.startReading() else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw VideoTranscodeError.unreadable(
                source,
                reason: reader.error?.localizedDescription ?? "the decoder refused to start"
            )
        }

        do {
            try await pump(
                reader: reader,
                writer: writer,
                videoOutput: videoOutput,
                videoInput: videoInput,
                adaptor: adaptor,
                audioOutput: audioOutput,
                audioInput: audioInput,
                source: source,
                plan: plan,
                startTime: startTime,
                progress: progress
            )
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw VideoTranscodeError.encodeFailed(
                source,
                reason: writer.error?.localizedDescription ?? "the encoder stopped early"
            )
        }
        // Deliberately not `URL.resourceValues`: it caches per URL instance, so
        // asking the same URL twice reports the first pass's size for the second.
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: destination.path(percentEncoded: false)
        )
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// One interleaved loop over both tracks, so the output is laid out for
    /// streaming rather than in two long runs. `requestMediaDataWhenReady` would
    /// mean handing mutable state to AVFoundation's own queue, which Swift 6
    /// concurrency will not allow; polling costs a few sleeps and stays cancellable.
    private func pump(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor?,
        audioOutput: AVAssetReaderTrackOutput?,
        audioInput: AVAssetWriterInput?,
        source: URL,
        plan: TranscodePlan,
        startTime: CMTime,
        progress: @Sendable (Double) -> Void
    ) async throws {
        var videoDone = false
        var audioDone = audioInput == nil
        var reported = 0.0

        while !videoDone || !audioDone {
            try Task.checkCancellation()
            var didWork = false

            if !videoDone, videoInput.isReadyForMoreMediaData {
                didWork = true
                if let sample = videoOutput.copyNextSampleBuffer() {
                    let time = sample.presentationTimeStamp
                    if let adaptor {
                        try scaleAndAppend(sample, at: time, to: adaptor, plan: plan, source: source, writer: writer)
                    } else if !videoInput.append(sample) {
                        // No scaling: the decoded buffer goes straight to the
                        // encoder, which is meaningfully faster than a round trip
                        // through a scaler that would do nothing.
                        throw VideoTranscodeError.encodeFailed(
                            source,
                            reason: writer.error?.localizedDescription ?? "a frame was rejected by the encoder"
                        )
                    }
                    let fraction = min(1, max(0, (time - startTime).seconds / plan.durationSeconds))
                    if fraction - reported >= 0.01 {
                        reported = fraction
                        progress(fraction)
                    }
                } else {
                    videoInput.markAsFinished()
                    videoDone = true
                }
            }

            if !audioDone, let audioInput, audioInput.isReadyForMoreMediaData {
                didWork = true
                if let sample = audioOutput?.copyNextSampleBuffer() {
                    guard audioInput.append(sample) else {
                        throw VideoTranscodeError.encodeFailed(
                            source,
                            reason: writer.error?.localizedDescription ?? "an audio packet was rejected by the encoder"
                        )
                    }
                } else {
                    audioInput.markAsFinished()
                    audioDone = true
                }
            }

            if !didWork {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        if reader.status == .failed {
            throw VideoTranscodeError.unreadable(
                source,
                reason: reader.error?.localizedDescription ?? "decoding stopped part way through"
            )
        }
    }

    // MARK: Scaling

    private func prepareScaler() {
        guard pixelTransfer == nil else { return }
        var session: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
           let session {
            // Aspect ratio is already preserved by the plan (both edges scaled by
            // the same factor), so a plain stretch is exactly right; averaging
            // avoids the aliasing a nearest-neighbour downscale would produce.
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            VTSessionSetProperty(
                session,
                key: kVTPixelTransferPropertyKey_DownsamplingMode,
                value: kVTDownsamplingMode_Average
            )
            pixelTransfer = session
        }
    }

    private func gpuContext() -> CIContext? {
        if let scalingContext { return scalingContext }
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let context = CIContext(mtlDevice: device, options: [
            // Frames round-trip YCbCr -> working space -> YCbCr; disabling colour
            // management keeps that neutral instead of quietly shifting colour.
            .workingColorSpace: NSNull(),
            // Batch throughput, not interactive latency: no intermediate caching,
            // and ask for the full-rate GPU queue.
            .cacheIntermediates: false,
            .priorityRequestLow: false,
        ])
        scalingContext = context
        return context
    }

    private func scaleAndAppend(
        _ sample: CMSampleBuffer,
        at time: CMTime,
        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
        plan: TranscodePlan,
        source: URL,
        writer: AVAssetWriter
    ) throws {
        guard let sourceBuffer = sample.imageBuffer else { return }
        // The pool only exists once the writer has started, which is why scaling
        // cannot be wired up any earlier than this. Recycling its buffers keeps
        // the encoder's IOSurfaces warm instead of allocating per frame.
        guard let pool = adaptor.pixelBufferPool else {
            throw VideoTranscodeError.encodeFailed(source, reason: "no pixel buffer pool was available for scaling")
        }

        var pooled: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pooled) == kCVReturnSuccess,
              let destination = pooled
        else {
            throw VideoTranscodeError.encodeFailed(source, reason: "ran out of memory while scaling frames")
        }

        var scaled = false
        if let pixelTransfer {
            scaled = VTPixelTransferSessionTransferImage(pixelTransfer, from: sourceBuffer, to: destination) == noErr
        }
        if !scaled {
            guard let context = gpuContext() else {
                throw VideoTranscodeError.encodeFailed(source, reason: "no GPU is available to scale frames")
            }
            let image = CIImage(cvPixelBuffer: sourceBuffer)
            let transformed = image.transformed(by: CGAffineTransform(
                scaleX: Double(plan.outputWidth) / image.extent.width,
                y: Double(plan.outputHeight) / image.extent.height
            ))
            context.render(transformed, to: destination)
        }

        guard adaptor.append(destination, withPresentationTime: time) else {
            throw VideoTranscodeError.encodeFailed(
                source,
                reason: writer.error?.localizedDescription ?? "a scaled frame was rejected by the encoder"
            )
        }
    }

    /// Cached: enumerating encoders is not free and the answer cannot change
    /// while the app is running.
    private static let hardwareEncoderCodecs: Set<FourCharCode> = {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr,
              let entries = list as? [[String: Any]]
        else { return [] }
        return Set(entries.compactMap { entry in
            guard entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool == true,
                  let codec = entry[kVTVideoEncoderList_CodecType as String] as? Int
            else { return nil }
            return FourCharCode(truncatingIfNeeded: codec)
        })
    }()

    /// Whether this machine can hardware-encode at all. Virtualized CI runners
    /// often cannot, and encoding through a software fallback is slow enough to
    /// look like a hang, so the encoding tests skip themselves rather than
    /// stalling the build.
    public static var supportsHardwareEncoding: Bool { !hardwareEncoderCodecs.isEmpty }

    static func hasHardwareEncoder(for codec: VideoCodec) -> Bool {
        switch codec {
        case .h264: hardwareEncoderCodecs.contains(kCMVideoCodecType_H264)
        case .hevc: hardwareEncoderCodecs.contains(kCMVideoCodecType_HEVC)
        }
    }

    // MARK: Audio helpers

    private static func channelCount(of track: AVAssetTrack) async -> Int {
        guard let formats = try? await track.load(.formatDescriptions),
              let asbd = formats.first?.audioStreamBasicDescription
        else { return 2 }
        return max(1, Int(asbd.mChannelsPerFrame))
    }

    private static func channelLayout(channels: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return withUnsafeBytes(of: &layout) { Data($0) }
    }
}
