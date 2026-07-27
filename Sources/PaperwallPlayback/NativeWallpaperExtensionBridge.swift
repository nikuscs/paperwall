import AVFoundation
import CryptoKit
import Foundation

public enum NativeWallpaperExtensionError: Error, LocalizedError {
    case copyVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .copyVerificationFailed:
            "The native Lock Screen wallpaper copy failed verification"
        }
    }
}

public enum NativeWallpaperExtensionBridge {
    public static let extensionBundleIdentifier = "com.paperwall.app.wallpaper-extension"
    public static let wallpaperID = "5D37D1E8-7B6A-4C1D-9F34-51AF24C57D65"

    private struct DeploymentMetadata: Codable {
        let id: String
        let name: String
        let filename: String
        let duration: Double
        let fps: Double
        let resolution: CGSize
        let dateAdded: Date
        let variants: [VideoVariant]?
    }

    private struct VideoVariant: Codable {
        let filename: String
        let fps: Int
        let resolution: CGSize
    }

    private static var documentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(extensionBundleIdentifier)/Data/Documents",
                isDirectory: true
            )
    }

    public static var isNativeWallpaperActivated: Bool {
        FileManager.default.fileExists(
            atPath: documentsDirectory.appendingPathComponent("native-lock-active").path
        )
    }

    private static var entryDirectory: URL {
        documentsDirectory
            .appendingPathComponent("videos", isDirectory: true)
            .appendingPathComponent(wallpaperID, isDirectory: true)
    }

    public static func deployActiveWallpaper(from sourceURL: URL) async throws {
        let fileManager = FileManager.default
        let videosDirectory = entryDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)

        let digest = SHA256.hash(data: try Data(contentsOf: sourceURL, options: [.mappedIfSafe]))
            .map { String(format: "%02x", $0) }
            .joined()
        let filename = "paperwall-\(digest.prefix(16)).\(sourceURL.pathExtension.lowercased())"
        let stage = videosDirectory.appendingPathComponent(".\(wallpaperID).stage-\(UUID().uuidString)")
        let backup = videosDirectory.appendingPathComponent(".\(wallpaperID).backup-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: stage)
            try? fileManager.removeItem(at: backup)
        }

        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        let stagedVideo = stage.appendingPathComponent(filename)
        try fileManager.copyItem(at: sourceURL, to: stagedVideo)
        let stagedDigest = SHA256.hash(data: try Data(contentsOf: stagedVideo, options: [.mappedIfSafe]))
        guard stagedDigest == SHA256.hash(data: try Data(contentsOf: sourceURL, options: [.mappedIfSafe])) else {
            throw NativeWallpaperExtensionError.copyVerificationFailed
        }

        let asset = AVURLAsset(url: stagedVideo)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var fps = 0.0
        var resolution = CGSize.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
            let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let transformed = naturalSize.applying(transform)
            resolution = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        }
        let metadata = DeploymentMetadata(
            id: wallpaperID,
            name: "Paperwall",
            filename: filename,
            duration: duration,
            fps: fps,
            resolution: resolution,
            dateAdded: Date(),
            variants: nil
        )
        try JSONEncoder().encode(metadata)
            .write(to: stage.appendingPathComponent("metadata.json"), options: .atomic)

        var backedUp = false
        if fileManager.fileExists(atPath: entryDirectory.path) {
            try fileManager.moveItem(at: entryDirectory, to: backup)
            backedUp = true
        }
        do {
            try fileManager.moveItem(at: stage, to: entryDirectory)
        } catch {
            if backedUp, !fileManager.fileExists(atPath: entryDirectory.path) {
                try? fileManager.moveItem(at: backup, to: entryDirectory)
            }
            throw error
        }

        notifyExtension()
    }

    public static func notifyExtension() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.paperwall.wallpaper.libraryChanged" as CFString),
            nil,
            nil,
            true
        )
    }
}
