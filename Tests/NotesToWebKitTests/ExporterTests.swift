import AVFoundation
import Foundation
import Testing

@testable import NotesToWebKit

/// End-to-end coverage of the seam between the exporter, the transcoder, and
/// the renderer: the part neither component's own tests can see.
@Suite("Exporter")
struct ExporterTests {
    private func withScratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "notes-to-web-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    /// A one-video note, standing in for the workout note this app exists for.
    private func document(video: URL, size: Int64) -> NoteDocument {
        let attachment = StoredAttachment(
            identifier: "video-1",
            typeUTI: "public.mpeg-4",
            filename: "clip.mp4",
            title: "Squat demo",
            urlString: nil,
            fileURL: video,
            fileSize: size
        )
        return NoteDocument(
            title: "Workout",
            blocks: [
                .heading(level: 2, spans: [Span(text: "Squats")]),
                .attachment(identifier: "video-1"),
            ],
            attachments: ["video-1": attachment]
        )
    }

    @Test("Compressing shrinks the export and still produces a playable page")
    func compressedExportShrinks() async throws {
        let source = try await SyntheticVideo.write(
            width: 1920, height: 1080, seconds: 4, bitrate: 20_000_000
        )
        defer { SyntheticVideo.remove(source) }
        let sourceSize = SyntheticVideo.byteCount(source)

        try await withScratch { destination in
            let result = try await Exporter().export(
                document: document(video: source, size: sourceSize),
                to: destination,
                options: ExportOptions(video: .webOptimized(VideoEncodeSettings(
                    quality: .small, codec: .h264, sizeBudget: 2_000_000
                )))
            )

            #expect(result.warnings.isEmpty, "unexpected warnings: \(result.warnings)")
            #expect(result.assetCount == 1)
            #expect(result.exportedByteCount < result.sourceByteCount)
            #expect(result.largestFileByteCount <= 2_000_000)

            // The page must point at the file that actually got written.
            let html = try String(contentsOf: result.indexPath, encoding: .utf8)
            #expect(html.contains("<video"))
            let src = try #require(
                html.firstMatch(of: /src="(assets\/[^"]+\.mp4)"/)?.1,
                "no mp4 source in the rendered page"
            )
            let media = destination.appending(path: String(src))
            #expect(FileManager.default.fileExists(atPath: media.path(percentEncoded: false)))

            // And that file has to be a real, decodable video, not a stub.
            let tracks = try await AVURLAsset(url: media).loadTracks(withMediaType: .video)
            #expect(tracks.count == 1)
        }
    }

    @Test("Poster frames are generated so videos are not black rectangles")
    func posterFramesAreWritten() async throws {
        let source = try await SyntheticVideo.write(width: 640, height: 480, seconds: 2)
        defer { SyntheticVideo.remove(source) }

        try await withScratch { destination in
            let result = try await Exporter().export(
                document: document(video: source, size: SyntheticVideo.byteCount(source)),
                to: destination
            )
            let html = try String(contentsOf: result.indexPath, encoding: .utf8)
            let poster = try #require(html.firstMatch(of: /poster="(assets\/[^"]+)"/)?.1)
            #expect(FileManager.default.fileExists(
                atPath: destination.appending(path: String(poster)).path(percentEncoded: false)
            ))
        }
    }

    @Test("HEVC output is declared so browsers that cannot decode it fall back")
    func hevcDeclaresItsCodec() async throws {
        let source = try await SyntheticVideo.write(width: 640, height: 480, seconds: 2)
        defer { SyntheticVideo.remove(source) }

        try await withScratch { destination in
            let result = try await Exporter().export(
                document: document(video: source, size: SyntheticVideo.byteCount(source)),
                to: destination,
                options: ExportOptions(video: .webOptimized(VideoEncodeSettings(
                    quality: .small, codec: .hevc, sizeBudget: 1_000_000
                )))
            )
            let html = try String(contentsOf: result.indexPath, encoding: .utf8)
            // Without the codecs parameter a browser lacking HEVC shows a dead
            // player instead of falling through to the download link.
            #expect(html.contains("hvc1"))
            #expect(result.warnings.isEmpty, "unexpected warnings: \(result.warnings)")
        }
    }

    @Test("Progress runs from start to finish without going backwards")
    func progressIsMonotonic() async throws {
        let source = try await SyntheticVideo.write(width: 1280, height: 720, seconds: 3)
        defer { SyntheticVideo.remove(source) }

        try await withScratch { destination in
            let recorder = ProgressRecorder()
            _ = try await Exporter().export(
                document: document(video: source, size: SyntheticVideo.byteCount(source)),
                to: destination,
                options: ExportOptions(video: .webOptimized(VideoEncodeSettings(
                    quality: .small, codec: .h264, sizeBudget: 1_000_000
                )))
            ) { recorder.record($0.fraction) }

            #expect(recorder.wasMonotonic, "progress went backwards")
            #expect(recorder.last == 1.0)
            #expect(recorder.count > 2, "no intermediate progress was reported")
        }
    }

    @Test("A missing attachment is a warning, not a failed export")
    func missingAttachmentWarns() async throws {
        try await withScratch { destination in
            let attachment = StoredAttachment(
                identifier: "video-1",
                typeUTI: "public.mpeg-4",
                filename: "clip.mp4",
                title: "Not downloaded",
                urlString: nil,
                fileURL: nil,
                fileSize: 0
            )
            let result = try await Exporter().export(
                document: NoteDocument(
                    title: "Workout",
                    blocks: [.attachment(identifier: "video-1")],
                    attachments: ["video-1": attachment]
                ),
                to: destination
            )
            #expect(result.warnings.count == 1)
            #expect(result.assetCount == 0)
            #expect(FileManager.default.fileExists(
                atPath: result.indexPath.path(percentEncoded: false)
            ))
        }
    }

    @Test("Exporting into a non-empty folder is refused unless overwriting")
    func refusesNonEmptyDestination() async throws {
        try await withScratch { destination in
            try Data("existing".utf8).write(to: destination.appending(path: "index.html"))
            let document = NoteDocument(title: "Workout", blocks: [], attachments: [:])

            await #expect(throws: ExportError.self) {
                _ = try await Exporter().export(document: document, to: destination)
            }

            // Re-exporting into a site folder relies on this being allowed.
            let result = try await Exporter().export(
                document: document,
                to: destination,
                options: ExportOptions(overwriteDestination: true)
            )
            #expect(FileManager.default.fileExists(
                atPath: result.indexPath.path(percentEncoded: false)
            ))
        }
    }
}

/// Records the progress stream so tests can assert on its shape.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ fraction: Double) {
        lock.withLock { values.append(fraction) }
    }

    var wasMonotonic: Bool {
        lock.withLock { zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } }
    }
    var last: Double { lock.withLock { values.last ?? 0 } }
    var count: Int { lock.withLock { values.count } }
}

/// Approximates the note this app was built for: 17 phone clips at a phone's
/// bitrate. Gated because generating and re-encoding ~400 MB is far too slow
/// for CI. Run with `NOTES_TO_WEB_SCALE=1 swift test --filter Scale`.
@Suite("Scale", .enabled(if: ProcessInfo.processInfo.environment["NOTES_TO_WEB_SCALE"] == "1"))
struct ExporterScaleTests {
    @Test("A seventeen-video note compresses to something publishable")
    func seventeenVideoNote() async throws {
        var attachments: [String: StoredAttachment] = [:]
        var blocks: [Block] = []
        var sources: [URL] = []
        defer { sources.forEach { try? FileManager.default.removeItem(at: $0) } }

        for index in 0..<17 {
            let url = try await SyntheticVideo.write(
                width: 1920, height: 1080, seconds: 10, bitrate: 20_000_000
            )
            sources.append(url)
            let id = "video-\(index)"
            attachments[id] = StoredAttachment(
                identifier: id, typeUTI: "public.mpeg-4", filename: "IMG_\(5000 + index).mp4",
                title: nil, urlString: nil, fileURL: url,
                fileSize: SyntheticVideo.byteCount(url)
            )
            blocks.append(.paragraph([Span(text: "Exercise \(index + 1)")]))
            blocks.append(.attachment(identifier: id))
        }

        let destination = FileManager.default.temporaryDirectory
            .appending(path: "scale-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let started = ContinuousClock.now
        let result = try await Exporter().export(
            document: NoteDocument(title: "Workout", blocks: blocks, attachments: attachments),
            to: destination
        )
        let elapsed = started.duration(to: .now)

        let mb = { (b: Int64) in String(format: "%.0f MB", Double(b) / 1_048_576) }
        print("""
            \(mb(result.sourceByteCount)) -> \(mb(result.exportedByteCount)) \
            in \(elapsed), largest file \(mb(result.largestFileByteCount))
            """)

        #expect(result.warnings.isEmpty, "\(result.warnings)")
        #expect(result.assetCount == 17)
        // The whole point: every file lands under a static host's per-file cap.
        #expect(result.largestFileByteCount <= VideoEncodeSettings.defaultSizeBudget)
    }

    /// Synthetic noise is the worst case an encoder can be handed. Point this at
    /// a real file to see what actual footage does:
    /// `NOTES_TO_WEB_SCALE=1 NOTES_TO_WEB_SAMPLE=/path/to.mov swift test --filter Scale`
    @Test("Real footage compresses to something publishable")
    func realFootage() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTES_TO_WEB_SAMPLE"] else { return }
        let source = URL(filePath: path)
        let size = try #require(
            (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        )

        let attachment = StoredAttachment(
            identifier: "v", typeUTI: "com.apple.quicktime-movie", filename: "clip.mov",
            title: nil, urlString: nil, fileURL: source, fileSize: size
        )
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "sample-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let started = ContinuousClock.now
        let result = try await Exporter().export(
            document: NoteDocument(
                title: "Sample",
                blocks: [.attachment(identifier: "v")],
                attachments: ["v": attachment]
            ),
            to: destination
        )
        let elapsed = started.duration(to: .now)
        let mb = { (b: Int64) in String(format: "%.1f MB", Double(b) / 1_048_576) }
        print("real footage: \(mb(result.sourceByteCount)) -> \(mb(result.exportedByteCount)) in \(elapsed)")

        #expect(result.warnings.isEmpty, "\(result.warnings)")
        #expect(result.largestFileByteCount <= VideoEncodeSettings.defaultSizeBudget)
    }
}
