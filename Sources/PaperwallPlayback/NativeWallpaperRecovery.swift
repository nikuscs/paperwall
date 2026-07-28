import Foundation

public struct NativeWallpaperRecoveryHealth: Codable, Equatable, Sendable {
    public var pendingInvalidations: [String: TimeInterval]

    public init(pendingInvalidations: [String: TimeInterval] = [:]) {
        self.pendingInvalidations = pendingInvalidations
    }
}

public enum NativeWallpaperRecovery {
    public static let surfaceInvalidatedNotification = "com.paperwall.wallpaper.surfaceInvalidated"
    public static let agentStuckNotification = "com.paperwall.wallpaper.agentStuck"

    public static var healthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(NativeWallpaperExtensionBridge.extensionBundleIdentifier)/Data/Documents/recovery-health.json"
            )
    }

    public static func readHealth(from url: URL? = nil) -> NativeWallpaperRecoveryHealth? {
        guard let data = try? Data(contentsOf: url ?? healthURL) else { return nil }
        return try? JSONDecoder().decode(NativeWallpaperRecoveryHealth.self, from: data)
    }

    public static func unresolvedInvalidations(
        in health: NativeWallpaperRecoveryHealth?,
        expected: [String: TimeInterval]
    ) -> [String: TimeInterval] {
        guard let health else { return [:] }
        return expected.filter { surfaceID, timestamp in
            health.pendingInvalidations[surfaceID] == timestamp
        }
    }

    public static func shouldRecover(
        health: NativeWallpaperRecoveryHealth?,
        transitionStartedAt: Date,
        now: Date = Date(),
        maximumAge: TimeInterval = 30
    ) -> Bool {
        guard let health else { return false }
        return health.pendingInvalidations.values.contains { timestamp in
            let eventDate = Date(timeIntervalSince1970: timestamp)
            return eventDate >= transitionStartedAt.addingTimeInterval(-1)
                && now.timeIntervalSince(eventDate) >= 0
                && now.timeIntervalSince(eventDate) <= maximumAge
        }
    }
}
