import Foundation

public struct PaperwallConfiguration: Equatable, Sendable {
    public var assetURL: URL

    public init(assetURL: URL = Self.defaultAssetURL) {
        self.assetURL = assetURL
    }

    public static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Paperwall", isDirectory: true)
    }

    /// Machine-local runtime state. Never synchronize this directory between Macs.
    public static var defaultAssetURL: URL {
        applicationSupportDirectory.appendingPathComponent("current.mov")
    }

    /// Durable Paperwall-owned media intended for user-managed synchronization.
    public static var sharedDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/paperwall", isDirectory: true)
    }

    public static var sharedLibraryDirectory: URL {
        sharedDataDirectory.appendingPathComponent("Library/Wallspace", isDirectory: true)
    }

    public static var sharedImportsDirectory: URL {
        sharedDataDirectory.appendingPathComponent("Library/Imports", isDirectory: true)
    }

    public static var sharedGenerationDirectory: URL {
        sharedDataDirectory.appendingPathComponent("Generation", isDirectory: true)
    }

    public static var generationStateDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Generation", isDirectory: true)
    }
}
