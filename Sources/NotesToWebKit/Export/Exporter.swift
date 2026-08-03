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
    /// Remux QuickTime movies to `.mp4` so they play outside Safari.
    public var convertMoviesToMP4: Bool
    /// Generate a still frame so videos do not appear as black rectangles.
    public var generatePosterFrames: Bool

    public init(convertMoviesToMP4: Bool = true, generatePosterFrames: Bool = true) {
        self.convertMoviesToMP4 = convertMoviesToMP4
        self.generatePosterFrames = generatePosterFrames
    }
}

public struct ExportProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let message: String
    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

public struct ExportResult: Sendable {
    public let directory: URL
    public let indexPath: URL
    public let assetCount: Int
    public let warnings: [String]
}

public actor Exporter {
    public init() {}

    /// Write `document` to `destination` as `index.html` plus an `assets/` directory.
    public func export(
        document: NoteDocument,
        to destination: URL,
        options: ExportOptions = ExportOptions(),
        progress: @Sendable (ExportProgress) -> Void = { _ in }
    ) async throws -> ExportResult {
        let fm = FileManager.default

        if let existing = try? fm.contentsOfDirectory(atPath: destination.path(percentEncoded: false)),
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

        var assets: [String: RenderedAsset] = [:]
        var warnings: [String] = []
        var usedNames: Set<String> = ["style.css"]
        let total = referenced.count + 1

        for (index, identifier) in referenced.enumerated() {
            guard let stored = document.attachments[identifier] else { continue }
            progress(ExportProgress(
                completed: index,
                total: total,
                message: "Copying \(stored.displayName)"
            ))

            guard let sourceURL = stored.fileURL else {
                warnings.append("\(stored.displayName) is not downloaded to this Mac and was skipped. Open the note in Notes to download it.")
                assets[identifier] = RenderedAsset(
                    mediaPath: nil,
                    posterPath: nil,
                    mimeType: stored.mimeType,
                    displayName: stored.displayName,
                    byteCount: stored.fileSize
                )
                continue
            }

            do {
                let asset = try await copy(
                    stored,
                    from: sourceURL,
                    into: assetsDir,
                    options: options,
                    usedNames: &usedNames,
                    fallbackIndex: index,
                    warnings: &warnings
                )
                assets[identifier] = asset
            } catch {
                warnings.append("\(stored.displayName) could not be exported: \(error.localizedDescription)")
            }
        }

        progress(ExportProgress(completed: referenced.count, total: total, message: "Writing page"))

        try Data(Stylesheet.css.utf8).write(
            to: assetsDir.appending(path: "style.css", directoryHint: .notDirectory)
        )

        let html = HTMLRenderer(assets: assets).render(document)
        let indexPath = destination.appending(path: "index.html", directoryHint: .notDirectory)
        try Data(html.utf8).write(to: indexPath)

        progress(ExportProgress(completed: total, total: total, message: "Done"))

        return ExportResult(
            directory: destination,
            indexPath: indexPath,
            assetCount: assets.values.count(where: { $0.mediaPath != nil }),
            warnings: warnings
        )
    }

    // MARK: Assets

    private func copy(
        _ stored: StoredAttachment,
        from sourceURL: URL,
        into assetsDir: URL,
        options: ExportOptions,
        usedNames: inout Set<String>,
        fallbackIndex: Int,
        warnings: inout [String]
    ) async throws -> RenderedAsset {
        let baseName = uniqueName(stored.exportName(fallbackIndex: fallbackIndex), in: &usedNames)
        var mediaName = baseName
        var mimeType = stored.mimeType

        if stored.kind == .video, options.convertMoviesToMP4, sourceURL.pathExtension.lowercased() != "mp4" {
            let mp4Name = uniqueName((baseName as NSString).deletingPathExtension + ".mp4", in: &usedNames)
            let mp4URL = assetsDir.appending(path: mp4Name, directoryHint: .notDirectory)
            if await remuxToMP4(from: sourceURL, to: mp4URL) {
                mediaName = mp4Name
                mimeType = "video/mp4"
            } else {
                // Falling back to the original keeps the video playable in Safari
                // even though other browsers may not accept a .mov container.
                warnings.append("\(stored.displayName) could not be converted to MP4; the original QuickTime file was used.")
                usedNames.remove(mp4Name)
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: assetsDir.appending(path: mediaName, directoryHint: .notDirectory)
                )
            }
        } else {
            try FileManager.default.copyItem(
                at: sourceURL,
                to: assetsDir.appending(path: mediaName, directoryHint: .notDirectory)
            )
        }

        var posterPath: String?
        if stored.kind == .video, options.generatePosterFrames {
            let posterName = uniqueName((baseName as NSString).deletingPathExtension + ".poster.jpg", in: &usedNames)
            let posterURL = assetsDir.appending(path: posterName, directoryHint: .notDirectory)
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

    /// Remux to MP4 without re-encoding where possible, using AVFoundation so the
    /// app has no ffmpeg dependency.
    private func remuxToMP4(from source: URL, to destination: URL) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4)
        else { return false }

        do {
            if #available(macOS 15.0, *) {
                try await session.export(to: destination, as: .mp4)
            } else {
                session.outputURL = destination
                session.outputFileType = .mp4
                await session.export()
                guard session.status == .completed else { return false }
            }
            return FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
    }
}

extension HTMLRenderer {
    /// The stylesheet the exporter writes, for use in the in-app preview.
    public static var bundledStylesheet: String { Stylesheet.css }
}
