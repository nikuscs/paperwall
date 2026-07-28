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

    public static func migrateLegacySharedAssetsIfNeeded() async throws {
        try await Task.detached(priority: .utility) {
            try migrateSynchronouslyIfNeeded()
        }.value
    }

    static func migrateSynchronouslyIfNeeded() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: PaperwallConfiguration.sharedDataDirectory,
            withIntermediateDirectories: true
        )
        try writeSyncthingIgnoreFileIfNeeded()
        try migrateLegacyLibraryMediaIfNeeded()
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

            var destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                if try sha256(source) == sha256(destination) { continue }
                let digest = try sha256(source).map { String(format: "%02x", $0) }.joined()
                destination = destinationDirectory
                    .appendingPathComponent(
                        "\(source.deletingPathExtension().lastPathComponent)-\(digest.prefix(12))"
                    )
                    .appendingPathExtension(source.pathExtension)
                if fileManager.fileExists(atPath: destination.path),
                   try sha256(source) == sha256(destination) { continue }
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
