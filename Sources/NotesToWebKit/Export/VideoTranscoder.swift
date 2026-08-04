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

    /// Bitrate covers elementary stream bytes only; MP4 sample tables, atoms and
    /// per-frame overhead are not free. Spend the budget at 97%.
    private static let containerHeadroom = 0.97

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
        do {
            (naturalSize, formats) = try await videoTrack.load(.naturalSize, .formatDescriptions)
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

        var videoBitrate = ceiling
        var exceedsBudget = false
        if let budget = settings.sizeBudget {
            let payloadBits = Double(budget) * 8 * Self.containerHeadroom
            let affordable = payloadBits / seconds - Double(audioBitrate)
            videoBitrate = min(ceiling, Int(affordable.rounded(.down)))
            if videoBitrate < floor {
                // Still a valid plan — the caller warns rather than refusing to export.
                videoBitrate = floor
                exceedsBudget = true
            }
        }

        var estimated = Int64((Double(videoBitrate + audioBitrate) * seconds / 8).rounded())
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
            exceedsBudget: exceedsBudget
        )
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
    /// Throws `CancellationError` if the surrounding task is cancelled; either way
    /// the partial file is deleted rather than left looking like a finished export.
    public func transcode(
        source: URL,
        to destination: URL,
        plan: TranscodePlan,
        progress: @Sendable (Double) -> Void
    ) async throws {
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
            AVVideoAverageBitRateKey: plan.videoBitrate,
            AVVideoExpectedSourceFrameRateKey: Int(frameRate > 0 ? frameRate.rounded() : 30),
            // Two-second GOP: without it the encoder emits very few keyframes and
            // scrubbing the exported page becomes unusable.
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if plan.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
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
        progress(1.0)
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

    private static func hasHardwareEncoder(for codec: VideoCodec) -> Bool {
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
