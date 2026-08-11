import CryptoKit
import Foundation

public struct DiscoveredWallpaper: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: URL

    public init(id: String, title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

public enum AssetLibrary {
    public static var paperwallLibraryDirectory: URL {
        PaperwallConfiguration.sharedImportsDirectory
    }

    public static func paperwallLibraryVideos() -> [URL] {
        let directories = [
            PaperwallConfiguration.sharedImportsDirectory,
            PaperwallConfiguration.sharedGenerationDirectory
                .appendingPathComponent("Outputs", isDirectory: true),
            PaperwallConfiguration.sharedGenerationDirectory
                .appendingPathComponent("Upscaled", isDirectory: true),
        ]
        let allVideos = directories
            .flatMap { videos(in: $0) }
            .filter { !$0.lastPathComponent.lowercased().hasPrefix("pruna-") }
        return Array(Dictionary(grouping: allVideos, by: \.standardizedFileURL).keys)
            .sorted { $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                $1.deletingPathExtension().lastPathComponent
            ) == .orderedAscending }
    }

    public static func discoverCachedWallpapers() async -> [DiscoveredWallpaper] {
        let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
        return await discoverCachedWallpapers(in: cacheDirectory)
    }

    static func discoverCachedWallpapers(
        in cacheDirectory: URL,
        minimumWidth: Int = 3_840,
        minimumHeight: Int = 2_160
    ) async -> [DiscoveredWallpaper] {
        let fileManager = FileManager.default
        let containers = (try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let sourceDirectories = containers.compactMap { container -> URL? in
            guard (try? container.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let children = try? fileManager.contentsOfDirectory(
                      at: container,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  ),
                  let directory = children.first(where: {
                      $0.lastPathComponent.caseInsensitiveCompare("Wallpapers") == .orderedSame
                          && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                  }) else { return nil }
            return directory
        }
        let candidates = sourceDirectories.flatMap { videos(in: $0) }
        return await withTaskGroup(of: DiscoveredWallpaper?.self) { group in
            for url in candidates {
                group.addTask {
                    guard let info = try? await VideoAssetValidator.validate(url: url),
                          max(info.width, info.height) >= minimumWidth,
                          min(info.width, info.height) >= minimumHeight else { return nil }
                    let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
                    let id = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
                    let title = url.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
                        .capitalized
                    return DiscoveredWallpaper(id: id, title: title, url: url)
                }
            }
            var discovered: [DiscoveredWallpaper] = []
            for await candidate in group {
                if let candidate { discovered.append(candidate) }
            }
            return discovered.sorted {
                if $0.title == $1.title { return $0.id < $1.id }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    public static func synchronizeDiscoveredWallpapers(
        _ discovered: [DiscoveredWallpaper]? = nil
    ) async throws -> [URL] {
        try await PaperwallStorageMigrator.migrateLegacySharedAssetsIfNeeded()
        let candidates = if let discovered { discovered } else { await discoverCachedWallpapers() }
        for candidate in candidates {
            do {
                _ = try await importLocalVideo(candidate.url)
            } catch {
                NSLog("Paperwall: could not import discovered wallpaper %@: %@", candidate.id, error.localizedDescription)
            }
        }
        return paperwallLibraryVideos()
    }

    public static func importLocalVideo(_ sourceURL: URL) async throws -> URL {
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        _ = try await VideoAssetValidator.validate(url: source)
        let sharedRoot = PaperwallConfiguration.sharedDataDirectory.resolvingSymlinksInPath().path
        if source.path == sharedRoot || source.path.hasPrefix(sharedRoot + "/") {
            return source
        }

        return try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let directory = PaperwallConfiguration.sharedImportsDirectory
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let digest = try sha256(source)
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            let fileExtension = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
            let destination = directory
                .appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(hash.prefix(12))")
                .appendingPathExtension(fileExtension)
            if fileManager.fileExists(atPath: destination.path) {
                guard try sha256(destination) == digest else { throw AssetLibraryError.hashMismatch }
                try await FirstFrameExporter.exportLibraryFrameIfNeeded(for: destination)
                return destination
            }

            let stage = directory
                .appendingPathComponent(".import-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            do {
                try fileManager.copyItem(at: source, to: stage)
                guard try sha256(stage) == digest else { throw AssetLibraryError.hashMismatch }
                try fileManager.moveItem(at: stage, to: destination)
                try await FirstFrameExporter.exportLibraryFrameIfNeeded(for: destination)
                _ = try? await WallpaperCatalog.shared.enrich(
                    mediaURL: destination,
                    description: "Imported into Paperwall.",
                    tags: ["imported"],
                    provenance: .imported
                )
                return destination
            } catch {
                try? fileManager.removeItem(at: stage)
                throw error
            }
        }.value
    }

    public static func removeVideo(_ videoURL: URL) throws {
        let video = videoURL.standardizedFileURL
        let sharedRoot = PaperwallConfiguration.sharedDataDirectory.standardizedFileURL.path + "/"
        guard video.path.hasPrefix(sharedRoot) else {
            throw AssetLibraryError.mediaOutsideSharedStorage(video)
        }
        let fileManager = FileManager.default
        try fileManager.removeItem(at: video)
        for sidecar in [
            FirstFrameExporter.frameURL(for: video),
            video.appendingPathExtension("paperwall.json"),
        ] where fileManager.fileExists(atPath: sidecar.path) {
            try fileManager.removeItem(at: sidecar)
        }
    }

    private static func videos(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let supportedExtensions = Set(["mp4", "mov", "m4v"])
        return urls
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.deletingPathExtension().lastPathComponent < $1.deletingPathExtension().lastPathComponent }
    }

    @discardableResult
    static func select(_ sourceURL: URL) async throws -> VideoAssetInfo {
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let destination = PaperwallConfiguration.defaultAssetURL
        let info = try await VideoAssetValidator.validate(url: source)
        if source == destination.resolvingSymlinksInPath().standardizedFileURL,
           FileManager.default.fileExists(atPath: destination.path) {
            return info
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: PaperwallConfiguration.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let stage = PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent(".current.mov.import-\(UUID().uuidString)")
        let backup = PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("current.mov.backup-\(stamp)")

        do {
            try fileManager.copyItem(at: source, to: stage)
            guard try sha256(source) == sha256(stage) else {
                throw AssetLibraryError.hashMismatch
            }
            var createdBackup = false
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                createdBackup = true
            }
            do {
                try fileManager.moveItem(at: stage, to: destination)
            } catch {
                if createdBackup, !fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.moveItem(at: backup, to: destination)
                }
                throw error
            }
            return info
        } catch {
            try? fileManager.removeItem(at: stage)
            throw error
        }
    }

    private static func sha256(_ url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }
}

public enum AssetLibraryError: Error, LocalizedError {
    case hashMismatch
    case mediaOutsideSharedStorage(URL)

    public var errorDescription: String? {
        switch self {
        case .hashMismatch:
            "Copied wallpaper failed SHA-256 verification"
        case .mediaOutsideSharedStorage(let url):
            "Wallpaper is outside Paperwall's shared storage: \(url.path)"
        }
    }
}
