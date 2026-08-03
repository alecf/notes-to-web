import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Still frames for video attachments, so videos are never blank rectangles.
public enum PosterFrame {
    /// Write a JPEG still from `source` to `destination`. Returns false if the
    /// video has no readable frame, in which case callers should fall back to no
    /// poster rather than failing the whole operation.
    @discardableResult
    public static func write(from source: URL, to destination: URL, maxDimension: CGFloat = 1600) async -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        // A frame slightly into the clip avoids the black frame many recordings
        // start on, but clamp so it still works for very short videos.
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)

        do {
            let (image, _) = try await generator.image(at: time)
            guard let data = jpeg(from: image) else { return false }
            try data.write(to: destination)
            return true
        } catch {
            return false
        }
    }

    /// Generate posters into `directory`, named by attachment identifier, skipping
    /// any that already exist. Returns the poster URL for each attachment that has one.
    public static func cache(
        for attachments: [StoredAttachment],
        in directory: URL
    ) async -> [String: URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var posters: [String: URL] = [:]
        for attachment in attachments where attachment.kind == .video {
            guard let source = attachment.fileURL else { continue }
            let destination = directory
                .appending(path: "\(attachment.identifier).jpg", directoryHint: .notDirectory)

            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                posters[attachment.identifier] = destination
                continue
            }
            if await write(from: source, to: destination) {
                posters[attachment.identifier] = destination
            }
        }
        return posters
    }

    private static func jpeg(from image: CGImage, quality: CGFloat = 0.82) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
