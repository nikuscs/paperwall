import CryptoKit
import Foundation

public enum PaperwallStorageMigrator {
    private struct MigrationSource {
        let legacySubdirectory: String
        let sharedSubdirectory: String
        let allowedExtensions: Set<String>
    }

    private static let migrationSources = [
        MigrationSource(
            legacySubdirectory: "Generation/Sources",
            sharedSubdirectory: "Generation/Sources",
            allowedExtensions: ["png", "jpg", "jpeg", "webp", "heic"]
        ),
        MigrationSource(
            legacySubdirectory: "Generation/Images",
            sharedSubdirectory: "Generation/Images",
            allowedExtensions: ["png", "jpg", "jpeg", "webp", "heic"]
        ),
        MigrationSource(
            legacySubdirectory: "Generation/Outputs",
            sharedSubdirectory: "Generation/Outputs",
            allowedExtensions: ["mp4", "mov", "m4v"]
        ),
        MigrationSource(
            legacySubdirectory: "Generation/Upscaled",
            sharedSubdirectory: "Generation/Upscaled",
            allowedExtensions: ["mp4", "mov", "m4v"]
        ),
    ]

    private static var markerURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("shared-storage-migration-v1.complete")
    }

    private static var libraryImportMarkerURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("library-import-migration-v2.complete")
    }

    private static var legacyCleanupMarkerURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("legacy-library-cleanup-v3.complete")
    }

    private static var frameBackfillMarkerURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("frame-backfill-v1.complete")
    }

    public static func migrateLegacySharedAssetsIfNeeded() async throws {
        try await Task.detached(priority: .utility) {
            try migrateSynchronouslyIfNeeded()
        }.value
        _ = try await backfillFrames(
            in: PaperwallConfiguration.sharedDataDirectory,
            markerURL: frameBackfillMarkerURL
        )
    }

    @discardableResult
    static func backfillFrames(in root: URL, markerURL: URL) async throws -> Int {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: markerURL.path) else { return 0 }

        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var exportedCount = 0
        while let videoURL = enumerator?.nextObject() as? URL {
            guard videoURL.pathExtension.lowercased() == "mp4",
                  (try? videoURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            let frameURL = FirstFrameExporter.frameURL(for: videoURL)
            guard !fileManager.fileExists(atPath: frameURL.path) else { continue }
            try await FirstFrameExporter.export(
                videoURL: videoURL,
                to: frameURL,
                quality: FirstFrameExporter.libraryJPEGQuality
            )
            exportedCount += 1
        }

        try fileManager.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("completed \(ISO8601DateFormatter().string(from: Date()))\n".utf8)
            .write(to: markerURL, options: .atomic)
        return exportedCount
    }

    static func migrateSynchronouslyIfNeeded() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: PaperwallConfiguration.sharedDataDirectory,
            withIntermediateDirectories: true
        )
        try writeSyncthingIgnoreFileIfNeeded()
        try migrateLegacyLibraryMediaIfNeeded()
        try cleanUpLegacyLibraryDirectoryIfNeeded()
        guard !fileManager.fileExists(atPath: markerURL.path) else { return }

        for source in migrationSources {
            let legacyDirectory = PaperwallConfiguration.applicationSupportDirectory
                .appendingPathComponent(source.legacySubdirectory, isDirectory: true)
            let destinationDirectory = PaperwallConfiguration.sharedDataDirectory
                .appendingPathComponent(source.sharedSubdirectory, isDirectory: true)
            try copyMedia(
                from: legacyDirectory,
                to: destinationDirectory,
                allowedExtensions: source.allowedExtensions
            )
        }

        try fileManager.createDirectory(
            at: PaperwallConfiguration.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try Data("completed \(ISO8601DateFormatter().string(from: Date()))\n".utf8)
            .write(to: markerURL, options: .atomic)
    }

    private static func migrateLegacyLibraryMediaIfNeeded() throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: libraryImportMarkerURL.path) else { return }
        let destination = PaperwallConfiguration.sharedImportsDirectory
        let roots = [
            PaperwallConfiguration.applicationSupportDirectory
                .appendingPathComponent("Library", isDirectory: true),
            PaperwallConfiguration.sharedDataDirectory
                .appendingPathComponent("Library", isDirectory: true),
        ]
        try migrateLibraryMedia(from: roots, to: destination)
        try fileManager.createDirectory(
            at: PaperwallConfiguration.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try Data("completed \(ISO8601DateFormatter().string(from: Date()))\n".utf8)
            .write(to: libraryImportMarkerURL, options: .atomic)
    }

    /// One-time removal of the pre-shared-storage library left in Application Support
    /// after the copy migrations above. Gated on a marker so subsequent launches cost a
    /// single stat. Media without a byte-identical copy anywhere under the shared
    /// library is rescued into Imports before the directory is deleted.
    private static func cleanUpLegacyLibraryDirectoryIfNeeded() throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: legacyCleanupMarkerURL.path) else { return }
        let legacyRoot = PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("Library", isDirectory: true)
        if fileManager.fileExists(atPath: legacyRoot.path) {
            try removeLegacyLibrary(
                at: legacyRoot,
                sharedLibrary: PaperwallConfiguration.sharedDataDirectory
                    .appendingPathComponent("Library", isDirectory: true),
                rescueDestination: PaperwallConfiguration.sharedImportsDirectory
            )
        }
        try fileManager.createDirectory(
            at: PaperwallConfiguration.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try Data("completed \(ISO8601DateFormatter().string(from: Date()))\n".utf8)
            .write(to: legacyCleanupMarkerURL, options: .atomic)
    }

    static func removeLegacyLibrary(
        at legacyRoot: URL,
        sharedLibrary: URL,
        rescueDestination: URL
    ) throws {
        let fileManager = FileManager.default
        let mediaExtensions: Set<String> = ["mp4", "mov", "m4v"]

        var sharedByName: [String: [URL]] = [:]
        if let enumerator = fileManager.enumerator(
            at: sharedLibrary,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = enumerator.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      mediaExtensions.contains(url.pathExtension.lowercased()) else { continue }
                sharedByName[url.lastPathComponent, default: []].append(url)
            }
        }

        let enumerator = fileManager.enumerator(
            at: legacyRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        while let source = enumerator?.nextObject() as? URL {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  mediaExtensions.contains(source.pathExtension.lowercased()) else { continue }

            // Same name + size first (cheap), hash only to confirm.
            let alreadyShared = try (sharedByName[source.lastPathComponent] ?? []).contains { candidate in
                let size = try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard size == values.fileSize else { return false }
                return try sha256(candidate) == sha256(source)
            }
            guard !alreadyShared else { continue }
            try copyMediaFile(source, to: rescueDestination)
        }

        try fileManager.removeItem(at: legacyRoot)
    }

    static func migrateLibraryMedia(from roots: [URL], to destination: URL) throws {
        for root in roots {
            try copyMedia(
                from: root,
                to: destination,
                allowedExtensions: ["mp4", "mov", "m4v"],
                excluding: destination
            )
        }
    }

    private static func copyMedia(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        allowedExtensions: Set<String>,
        excluding excludedDirectory: URL? = nil
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceDirectory.path) else { return }
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let enumerator = fileManager.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let source = enumerator?.nextObject() as? URL {
            if let excludedDirectory {
                let excludedPath = excludedDirectory.standardizedFileURL.path
                let sourcePath = source.standardizedFileURL.path
                if sourcePath == excludedPath || sourcePath.hasPrefix(excludedPath + "/") {
                    continue
                }
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true,
                  allowedExtensions.contains(source.pathExtension.lowercased()) else { continue }
            try copyMediaFile(source, to: destinationDirectory)
        }
    }

    private static func copyMediaFile(_ source: URL, to destinationDirectory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            if try sha256(source) == sha256(destination) { return }
            let digest = try sha256(source).map { String(format: "%02x", $0) }.joined()
            destination = destinationDirectory
                .appendingPathComponent(
                    "\(source.deletingPathExtension().lastPathComponent)-\(digest.prefix(12))"
                )
                .appendingPathExtension(source.pathExtension)
            if fileManager.fileExists(atPath: destination.path),
               try sha256(source) == sha256(destination) { return }
        }

        let stage = destinationDirectory
            .appendingPathComponent(".migration-\(UUID().uuidString)")
            .appendingPathExtension(source.pathExtension)
        do {
            try fileManager.copyItem(at: source, to: stage)
            guard try sha256(source) == sha256(stage) else {
                throw AssetLibraryError.hashMismatch
            }
            try fileManager.moveItem(at: stage, to: destination)
        } catch {
            try? fileManager.removeItem(at: stage)
            throw error
        }
    }

    private static func writeSyncthingIgnoreFileIfNeeded() throws {
        let url = PaperwallConfiguration.sharedDataDirectory.appendingPathComponent(".stignore")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let rules = """
        // Paperwall temporary and macOS metadata files
        (?d).DS_Store
        (?d)**/.migration-*
        (?d)**/.import-*
        (?d)**/*-partial.mp4
        """
        try Data((rules + "\n").utf8).write(to: url, options: .atomic)
    }

    private static func sha256(_ url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }
}
