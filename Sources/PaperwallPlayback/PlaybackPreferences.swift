import Foundation

public enum PlaybackSpeed: Double, CaseIterable, Codable, Sendable {
    case fifth = 0.2
    case half = 0.5
    case normal = 1.0
    case double = 2.0

    public var displayName: String {
        switch self {
        case .fifth: "0.2×"
        case .half: "0.5×"
        case .normal: "1×"
        case .double: "2×"
        }
    }
}

public enum PlaybackPreferences {
    private struct StoredSettings: Codable {
        var playbackSpeed: PlaybackSpeed
    }

    private static var settingsURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("settings.json")
    }

    public static var playbackSpeed: PlaybackSpeed {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(StoredSettings.self, from: data) else {
            return .normal
        }
        return settings.playbackSpeed
    }

    public static func save(playbackSpeed: PlaybackSpeed) throws {
        try FileManager.default.createDirectory(
            at: PaperwallConfiguration.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(StoredSettings(playbackSpeed: playbackSpeed))
            .write(to: settingsURL, options: .atomic)
    }
}
