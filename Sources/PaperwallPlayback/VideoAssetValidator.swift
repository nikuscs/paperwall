import AVFoundation
import Foundation

public struct VideoAssetInfo: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let duration: TimeInterval

    public init(width: Int, height: Int, duration: TimeInterval) {
        self.width = width
        self.height = height
        self.duration = duration
    }
}

public enum VideoAssetValidationError: Error, Equatable, LocalizedError {
    case missing(URL)
    case unreadable(URL)
    case notPlayable(URL)
    case missingVideoTrack(URL)
    case invalidDimensions(width: Int, height: Int)

    public var errorDescription: String? {
        switch self {
        case .missing(let url):
            "Video asset does not exist: \(url.path)"
        case .unreadable(let url):
            "Video asset is not readable: \(url.path)"
        case .notPlayable(let url):
            "Video asset is not playable: \(url.path)"
        case .missingVideoTrack(let url):
            "Video asset has no video track: \(url.path)"
        case .invalidDimensions(let width, let height):
            "Video dimensions must be positive (received \(width)×\(height))"
        }
    }
}

public enum VideoAssetValidator {
    public static func validate(url: URL) async throws -> VideoAssetInfo {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw VideoAssetValidationError.missing(url)
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw VideoAssetValidationError.unreadable(url)
        }

        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw VideoAssetValidationError.notPlayable(url)
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoAssetValidationError.missingVideoTrack(url)
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let width = Int(abs(transformed.width).rounded())
        let height = Int(abs(transformed.height).rounded())
        guard width > 0, height > 0 else {
            throw VideoAssetValidationError.invalidDimensions(width: width, height: height)
        }

        let duration = try await asset.load(.duration)
        return VideoAssetInfo(
            width: width,
            height: height,
            duration: duration.seconds
        )
    }
}
