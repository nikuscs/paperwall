import CryptoKit
import Foundation

public enum AssetLibrary {
    private struct MirrorIndex: Codable {
        var entries: [String: MirrorEntry] = [:]
    }

    private struct MirrorEntry: Codable {
        let fileSize: Int64
        let modificationTime: TimeInterval
        let destinationName: String
    }

    public static var discoveryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Discovery/Wallpapers", isDirectory: true)
    }

    public static var paperwallLibraryDirectory: URL {
        PaperwallConfiguration.sharedLibraryDirectory
    }

    private static var mirrorIndexURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("Library/Discovery/index.json")
    }

    public static func discoveryVideos() -> [URL] {
        videos(in: discoveryDirectory)
    }

    public static func paperwallLibraryVideos() -> [URL] {
        let directories = [
            paperwallLibraryDirectory,
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

    public static func synchronizeDiscoveryCache() async throws -> [URL] {
        try await Task.detached(priority: .utility) {
            try PaperwallStorageMigrator.migrateSynchronouslyIfNeeded()
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: paperwallLibraryDirectory,
                withIntermediateDirectories: true
            )

            try fileManager.createDirectory(
                at: mirrorIndexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var index = (try? Data(contentsOf: mirrorIndexURL))
                .flatMap { try? JSONDecoder().decode(MirrorIndex.self, from: $0) }
                ?? MirrorIndex()

            for source in discoveryVideos() {
                do {
                    let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let fileSize = Int64(values.fileSize ?? 0)
                    let modificationTime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    if let entry = index.entries[source.path],
                       entry.fileSize == fileSize,
                       entry.modificationTime == modificationTime,
                       fileManager.fileExists(
                           atPath: paperwallLibraryDirectory
                               .appendingPathComponent(entry.destinationName).path
                       ) {
                        continue
                    }

                    let digest = try sha256(source)
                    let hash = digest.map { String(format: "%02x", $0) }.joined()
                    let destination = paperwallLibraryDirectory
                        .appendingPathComponent(
                            "\(source.deletingPathExtension().lastPathComponent)-\(hash.prefix(12))"
                        )
                        .appendingPathExtension("mp4")

                    if !fileManager.fileExists(atPath: destination.path) {
                        let stage = paperwallLibraryDirectory
                            .appendingPathComponent(".import-\(UUID().uuidString)")
                            .appendingPathExtension("mp4")
                        do {
                            try fileManager.copyItem(at: source, to: stage)
                            guard try sha256(stage) == digest else {
                                throw AssetLibraryError.hashMismatch
                            }
                            try fileManager.moveItem(at: stage, to: destination)
                        } catch {
                            try? fileManager.removeItem(at: stage)
                            throw error
                        }
                    }
                    index.entries[source.path] = MirrorEntry(
                        fileSize: fileSize,
                        modificationTime: modificationTime,
                        destinationName: destination.lastPathComponent
                    )
                } catch {
                    NSLog("Paperwall: could not mirror %@: %@", source.lastPathComponent, error.localizedDescription)
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(index).write(to: mirrorIndexURL, options: .atomic)
            return paperwallLibraryVideos()
        }.value
    }

    private static func videos(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "mp4" }
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

    public var errorDescription: String? {
        switch self {
        case .hashMismatch: "Copied wallpaper failed SHA-256 verification"
        }
    }
}
