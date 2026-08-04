import AVFoundation
import Foundation

public enum ExportError: Error, LocalizedError {
    case destinationNotEmpty(URL)
    case couldNotCreateDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .destinationNotEmpty(let url):
            "\(url.lastPathComponent) already contains files. Choose an empty folder or a new one."
        case .couldNotCreateDirectory(let url):
            "Could not create \(url.path(percentEncoded: false))."
        }
    }
}

public struct ExportOptions: Sendable {
    /// What to do with video attachments on the way out.
    public enum VideoTreatment: Sendable, Hashable {
        /// Rewrap as `.mp4` without re-encoding. Preserves quality exactly and
        /// is fast, but a phone's 50 Mbps clip stays a 50 Mbps clip.
        case original
        /// Re-encode for the web at a bounded bitrate and size.
        case webOptimized(VideoEncodeSettings)
    }

    public var video: VideoTreatment
    /// Generate a still frame so videos do not appear as black rectangles.
    public var generatePosterFrames: Bool
    /// Skip the empty-directory check. Set when the caller has already cleared
    /// the destination, as re-exporting into a site root does.
    public var overwriteDestination: Bool

    public init(
        video: VideoTreatment = .webOptimized(.webDefault),
        generatePosterFrames: Bool = true,
        overwriteDestination: Bool = false
    ) {
        self.video = video
        self.generatePosterFrames = generatePosterFrames
        self.overwriteDestination = overwriteDestination
    }
}

public struct ExportProgress: Sendable {
    /// 0...1 across the whole export, weighted by source bytes so a 54 MB clip
    /// does not advance the bar as fast as a 40 KB thumbnail.
    public let fraction: Double
    public let message: String
    public let detail: String?

    public init(fraction: Double, message: String, detail: String? = nil) {
        self.fraction = fraction
        self.message = message
        self.detail = detail
    }
}

public struct ExportResult: Sendable {
    public let directory: URL
    public let indexPath: URL
    public let assetCount: Int
    /// Bytes the attachments occupied in the Notes library.
    public let sourceByteCount: Int64
    /// Bytes actually written to the export directory.
    public let exportedByteCount: Int64
    /// The biggest single file written, which is what host per-file limits bite on.
    public let largestFileByteCount: Int64
    public let warnings: [String]

    /// Fraction of the original size saved, or nil when nothing was compressed.
    public var savedFraction: Double? {
        guard sourceByteCount > 0, exportedByteCount < sourceByteCount else { return nil }
        return 1 - Double(exportedByteCount) / Double(sourceByteCount)
    }
}

public actor Exporter {
    private let transcoder = VideoTranscoder()

    public init() {}

    /// Write `document` to `destination` as `index.html` plus an `assets/` directory.
    public func export(
        document: NoteDocument,
        to destination: URL,
        options: ExportOptions = ExportOptions(),
        progress: @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws -> ExportResult {
        let fm = FileManager.default

        if !options.overwriteDestination,
           let existing = try? fm.contentsOfDirectory(atPath: destination.path(percentEncoded: false)),
           !existing.filter({ !$0.hasPrefix(".") }).isEmpty {
            throw ExportError.destinationNotEmpty(destination)
        }

        let assetsDir = destination.appending(path: "assets", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        } catch {
            throw ExportError.couldNotCreateDirectory(assetsDir)
        }

        // Only attachments actually referenced by the document get exported.
        let referenced = document.blocks.compactMap { block -> String? in
            if case .attachment(let id) = block { return id }
            return nil
        }

        // Weighting the bar by source bytes keeps it honest: video dominates the
        // work, and one clip can be a thousand times the size of the next item.
        let weights = referenced.map { Double(max(document.attachments[$0]?.fileSize ?? 0, 1)) }
        let totalWeight = max(weights.reduce(0, +), 1)
        var doneWeight = 0.0

        var assets: [String: RenderedAsset] = [:]
        var warnings: [String] = []
        var usedNames: Set<String> = ["style.css"]
        var sourceBytes: Int64 = 0

        for (index, identifier) in referenced.enumerated() {
            guard let stored = document.attachments[identifier] else { continue }
            let weight = weights[index]
            let counter = "\(index + 1) of \(referenced.count)"

            guard let sourceURL = stored.fileURL else {
                warnings.append("\(stored.displayName) is not downloaded to this Mac and was skipped. Open the note in Notes to download it.")
                assets[identifier] = RenderedAsset(
                    mediaPath: nil,
                    posterPath: nil,
                    mimeType: stored.mimeType,
                    displayName: stored.displayName,
                    byteCount: stored.fileSize
                )
                doneWeight += weight
                continue
            }

            sourceBytes += stored.fileSize
            // Snapshot the running total: the callback is @Sendable and cannot
            // capture the mutable accumulator.
            let base = doneWeight

            do {
                let asset = try await write(
                    stored,
                    from: sourceURL,
                    into: assetsDir,
                    options: options,
                    usedNames: &usedNames,
                    fallbackIndex: index,
                    warnings: &warnings,
                    progress: { unit, message, detail in
                        progress(ExportProgress(
                            fraction: min((base + unit * weight) / totalWeight, 0.99),
                            message: message,
                            detail: detail.map { "\(counter) · \($0)" } ?? counter
                        ))
                    }
                )
                assets[identifier] = asset
            } catch {
                warnings.append("\(stored.displayName) could not be exported: \(error.localizedDescription)")
            }
            doneWeight += weight
        }

        progress(ExportProgress(fraction: 0.99, message: "Writing page", detail: nil))

        try Data(Stylesheet.css.utf8).write(
            to: assetsDir.appending(path: "style.css", directoryHint: .notDirectory)
        )

        let html = HTMLRenderer(assets: assets).render(document)
        let indexPath = destination.appending(path: "index.html", directoryHint: .notDirectory)
        try Data(html.utf8).write(to: indexPath)

        progress(ExportProgress(fraction: 1, message: "Done", detail: nil))

        let written = assets.values.compactMap(\.byteCount.self)
        return ExportResult(
            directory: destination,
            indexPath: indexPath,
            assetCount: assets.values.count(where: { $0.mediaPath != nil }),
            sourceByteCount: sourceBytes,
            exportedByteCount: SiteLibrary.byteCount(of: destination),
            largestFileByteCount: written.max() ?? 0,
            warnings: warnings
        )
    }

    // MARK: Assets

    private func write(
        _ stored: StoredAttachment,
        from sourceURL: URL,
        into assetsDir: URL,
        options: ExportOptions,
        usedNames: inout Set<String>,
        fallbackIndex: Int,
        warnings: inout [String],
        progress: @Sendable (Double, String, String?) -> Void
    ) async throws -> RenderedAsset {
        let baseName = uniqueName(stored.exportName(fallbackIndex: fallbackIndex), in: &usedNames)
        var mediaName = baseName
        var mimeType = stored.mimeType

        if stored.kind == .video {
            let mp4Name = uniqueName((baseName as NSString).deletingPathExtension + ".mp4", in: &usedNames)
            let mp4URL = assetsDir.appending(path: mp4Name, directoryHint: .notDirectory)

            switch await encodeVideo(
                stored,
                from: sourceURL,
                to: mp4URL,
                options: options,
                progress: progress
            ) {
            case .wrote(let codec, let oversize):
                if let oversize { warnings.append(oversize) }
                mediaName = mp4Name
                // Naming the codec lets a browser that cannot decode HEVC fall
                // through to the download link instead of showing a dead player.
                mimeType = codec == .hevc ? #"video/mp4; codecs="hvc1""# : "video/mp4"

            case .failed(let reason):
                warnings.append(reason)
                usedNames.remove(mp4Name)
                try? FileManager.default.removeItem(at: mp4URL)
                progress(0.9, "Copying \(stored.displayName)", nil)
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: assetsDir.appending(path: mediaName, directoryHint: .notDirectory)
                )
            }
        } else {
            progress(0, "Copying \(stored.displayName)", nil)
            try FileManager.default.copyItem(
                at: sourceURL,
                to: assetsDir.appending(path: mediaName, directoryHint: .notDirectory)
            )
        }

        var posterPath: String?
        if stored.kind == .video, options.generatePosterFrames {
            let posterName = uniqueName((baseName as NSString).deletingPathExtension + ".poster.jpg", in: &usedNames)
            let posterURL = assetsDir.appending(path: posterName, directoryHint: .notDirectory)
            // Taken from the source: better than a still off a compressed copy,
            // and it still works when the transcode failed.
            if await PosterFrame.write(from: sourceURL, to: posterURL) {
                posterPath = "assets/\(posterName)"
            } else {
                usedNames.remove(posterName)
            }
        }

        let mediaURL = assetsDir.appending(path: mediaName, directoryHint: .notDirectory)
        let size = (try? mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? stored.fileSize

        return RenderedAsset(
            mediaPath: "assets/\(mediaName)",
            posterPath: posterPath,
            mimeType: mimeType,
            displayName: stored.displayName,
            byteCount: size
        )
    }

    private enum VideoOutcome {
        /// `oversize` is set when the clip could not be squeezed under the
        /// budget. The video plays; it is just larger than the host will accept,
        /// and the user should hear that now rather than at upload time.
        case wrote(VideoCodec, oversize: String? = nil)
        case failed(String)
    }

    private func encodeVideo(
        _ stored: StoredAttachment,
        from sourceURL: URL,
        to destination: URL,
        options: ExportOptions,
        progress: @Sendable (Double, String, String?) -> Void
    ) async -> VideoOutcome {
        guard case .webOptimized(let settings) = options.video else {
            progress(0, "Converting \(stored.displayName)", nil)
            return await remuxToMP4(from: sourceURL, to: destination)
                ? .wrote(.h264)
                : .failed("\(stored.displayName) could not be converted to MP4; export it as Original video or open it in Notes to check the file.")
        }

        do {
            let plan = try await transcoder.plan(for: sourceURL, settings: settings)

            if plan.passesThrough {
                progress(0, "Copying \(stored.displayName)", "already web-sized")
                if await remuxToMP4(from: sourceURL, to: destination) { return .wrote(plan.codec) }
                // Fall through to a real encode rather than shipping a .mov.
            }

            let sizeLabel = ByteCountFormatter.string(fromByteCount: plan.sourceByteCount, countStyle: .file)
            let targetLabel = ByteCountFormatter.string(fromByteCount: plan.estimatedByteCount, countStyle: .file)
            let detail = "\(sizeLabel) → about \(targetLabel)"

            progress(0, "Compressing \(stored.displayName)", detail)
            let ramp = CorrectivePassRamp()
            let result = try await transcoder.transcode(
                source: sourceURL, to: destination, plan: plan
            ) { fraction in
                let (mapped, isCorrecting) = ramp.map(fraction)
                progress(
                    mapped,
                    "Compressing \(stored.displayName)",
                    isCorrecting ? "\(detail) · adjusting to fit" : detail
                )
            }

            guard result.exceedsBudget, let limit = plan.byteCeiling else {
                return .wrote(plan.codec)
            }
            let actual = ByteCountFormatter.string(fromByteCount: result.byteCount, countStyle: .file)
            let ceiling = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return .wrote(plan.codec, oversize: """
                \(stored.displayName) came out at \(actual), over the \(ceiling) limit — it is too \
                long to compress that far. Trim it, or choose a smaller quality, or publish \
                somewhere without a per-file limit.
                """)
        } catch is CancellationError {
            return .failed("\(stored.displayName) was cancelled.")
        } catch {
            return .failed("\(stored.displayName) could not be compressed: \(error.localizedDescription)")
        }
    }

    private func uniqueName(_ name: String, in used: inout Set<String>) -> String {
        guard used.contains(name) else {
            used.insert(name)
            return name
        }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var suffix = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            if !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
            suffix += 1
        }
    }

    /// Rewrap to MP4 without re-encoding, using AVFoundation so the app has no
    /// ffmpeg dependency.
    private func remuxToMP4(from source: URL, to destination: URL) async -> Bool {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4)
        else { return false }

        do {
            try await session.export(to: destination, as: .mp4)
            return FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
    }
}

/// The transcoder runs a corrective second pass when the first overshoots the
/// size budget, and that pass restarts its own progress at zero. Squash both
/// passes into one ramp that never decreases, so the bar cannot jump backwards.
/// The first pass gets most of the range because it is almost always the only one.
private final class CorrectivePassRamp: @unchecked Sendable {
    private static let firstPassShare = 0.85

    private let lock = NSLock()
    private var highest = 0.0
    private var previousRaw = 0.0
    private var isSecondPass = false

    func map(_ raw: Double) -> (fraction: Double, isCorrecting: Bool) {
        lock.withLock {
            if raw < previousRaw { isSecondPass = true }
            previousRaw = raw

            let mapped = isSecondPass
                ? Self.firstPassShare + raw * (1 - Self.firstPassShare)
                : raw * Self.firstPassShare
            highest = max(highest, min(mapped, 1))
            return (highest, isSecondPass)
        }
    }
}

extension HTMLRenderer {
    /// The stylesheet the exporter writes, for use in the in-app preview.
    public static var bundledStylesheet: String { Stylesheet.css }
}
