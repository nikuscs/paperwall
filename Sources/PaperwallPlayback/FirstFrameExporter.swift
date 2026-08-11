import AppKit
import AVFoundation
import Foundation

public enum FirstFrameExporter {
    public static let libraryJPEGQuality = 0.95

    public static func frameURL(for videoURL: URL) -> URL {
        videoURL.appendingPathExtension("frame.jpg")
    }

    public static func export(
        videoURL: URL,
        to destination: URL,
        quality: Double
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: .zero)
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        ) else {
            throw FirstFrameExporterError.couldNotEncodeJPEG
        }
        try data.write(to: destination, options: .atomic)
    }

    public static func exportLibraryFrameIfNeeded(for videoURL: URL) async throws {
        let destination = frameURL(for: videoURL)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try await export(
            videoURL: videoURL,
            to: destination,
            quality: libraryJPEGQuality
        )
    }
}

public enum FirstFrameExporterError: Error, LocalizedError {
    case couldNotEncodeJPEG

    public var errorDescription: String? {
        "Could not encode the video's first frame as JPEG"
    }
}
