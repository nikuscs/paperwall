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

    public static var defaultAssetURL: URL {
        applicationSupportDirectory.appendingPathComponent("current.mov")
    }
}
