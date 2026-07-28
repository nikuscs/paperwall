import Foundation

public enum LaunchAtLoginManager {
    public static let label = "com.paperwall.app"
    private static let explicitlyDisabledKey = "launchAtLoginExplicitlyDisabled"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The persisted user preference. This intentionally performs no process work,
    /// so SwiftUI can read it safely during view construction.
    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public static func enableByDefaultIfNeeded(appURL: URL) throws {
        guard !UserDefaults.standard.bool(forKey: explicitlyDisabledKey) else { return }
        try enable(appURL: appURL)
    }

    public static func setEnabledByUser(_ enabled: Bool, appURL: URL) throws {
        if enabled {
            try enable(appURL: appURL)
            UserDefaults.standard.set(false, forKey: explicitlyDisabledKey)
        } else {
            try disable()
            UserDefaults.standard.set(true, forKey: explicitlyDisabledKey)
        }
    }

    public static func enable(appURL: URL) throws {
        let executable = appURL.appendingPathComponent("Contents/MacOS/Paperwall")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LaunchAtLoginError.missingInstalledApp
        }
        let resolvedApp = appURL.resolvingSymlinksInPath().standardizedFileURL
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard [userApplications, systemApplications].contains(where: {
            resolvedApp.path.hasPrefix($0.path + "/")
        }) else {
            throw LaunchAtLoginError.appMustBeInstalled
        }

        let dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let previousData = try? Data(contentsOf: plistURL)
        let wasLoaded = isLoaded
        if wasLoaded, previousData == data { return }
        if wasLoaded {
            try runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        }
        do {
            try data.write(to: plistURL, options: [.atomic])
            try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        } catch {
            let originalError = error
            do {
                if fileManager.fileExists(atPath: plistURL.path) {
                    try fileManager.removeItem(at: plistURL)
                }
                if let previousData {
                    try previousData.write(to: plistURL, options: [.atomic])
                } else if wasLoaded {
                    throw LaunchAtLoginError.missingPreviousConfiguration
                }
                if wasLoaded {
                    try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
                    guard isLoaded else { throw LaunchAtLoginError.restoreDidNotLoad }
                }
            } catch {
                throw LaunchAtLoginError.restoreFailed(
                    original: originalError.localizedDescription,
                    restoration: error.localizedDescription
                )
            }
            throw originalError
        }
    }

    public static func disable() throws {
        if isLoaded {
            try runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static var isLoaded: Bool {
        (try? runLaunchctl(["print", "gui/\(getuid())/\(label)"])) != nil
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw LaunchAtLoginError.launchctl(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return message
    }
}

public enum LaunchAtLoginError: Error, LocalizedError {
    case missingInstalledApp
    case appMustBeInstalled
    case launchctl(String)
    case missingPreviousConfiguration
    case restoreDidNotLoad
    case restoreFailed(original: String, restoration: String)

    public var errorDescription: String? {
        switch self {
        case .missingInstalledApp:
            "Paperwall.app is not installed in an Applications folder"
        case .appMustBeInstalled:
            "Move Paperwall.app to Applications before enabling launch at login"
        case .launchctl(let message):
            message.isEmpty ? "launchctl failed" : message
        case .missingPreviousConfiguration:
            "The loaded LaunchAgent had no plist to restore"
        case .restoreDidNotLoad:
            "The previous LaunchAgent plist was restored but did not load"
        case .restoreFailed(let original, let restoration):
            "Launch-at-login update failed (\(original)); restoration also failed (\(restoration))"
        }
    }
}
