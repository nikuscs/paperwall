import AppKit
import Darwin
import Foundation

@main
enum PaperwallCLI {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }
        switch command {
        case "set":
            guard arguments.count == 2 else { throw CLIError.usage }
            try await select(URL(fileURLWithPath: arguments[1]))
        case "wallspace-list":
            try await listWallspace()
        case "wallspace-set":
            guard arguments.count == 2,
                  arguments[1].allSatisfy(\.isNumber) else { throw CLIError.usage }
            let url = AssetLibrary.wallspaceDirectory
                .appendingPathComponent(arguments[1])
                .appendingPathExtension("mp4")
            try await select(url)
        case "generate":
            try await generate(Array(arguments.dropFirst()))
        case "start":
            try start()
        case "stop":
            try stop()
        case "status":
            try await status()
        case "enable":
            guard arguments.count == 1 else { throw CLIError.usage }
            try LaunchAtLoginManager.enable(appURL: installedAppURL)
            print("Launch at login enabled")
        case "disable":
            guard arguments.count == 1 else { throw CLIError.usage }
            try LaunchAtLoginManager.disable()
            print("Launch at login disabled")
        case "saver":
            try saver(Array(arguments.dropFirst()))
        case "asset":
            print(PaperwallConfiguration.defaultAssetURL.path)
        case "__synchronize-native-wallpaper":
            guard arguments.count == 1 else { throw CLIError.usage }
            _ = try await PaperwallService.synchronizeActiveWallpaper()
        case "__restore-native-wallpaper":
            guard arguments.count == 1 else { throw CLIError.usage }
            try await PaperwallService.restorePreviousNativeWallpaper()
        case "help", "--help", "-h":
            printUsage()
        default:
            throw CLIError.usage
        }
    }

    private static func select(_ source: URL) async throws {
        let wasRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.paperwall.app"
        ).isEmpty
        let info = try await PaperwallService.selectWallpaper(from: source)
        if wasRunning {
            try stop()
            try start()
        }
        print("Selected: \(source.path)")
        print("Active: \(PaperwallConfiguration.defaultAssetURL.path)")
        print("Video: \(info.width)×\(info.height), \(String(format: "%.2f", info.duration))s")
        if wasRunning { print("Desktop playback reloaded") }
    }

    private static func generate(_ arguments: [String]) async throws {
        var provider = GenerationProvider.pruna
        var prompt: String?
        var imageURL: URL?
        var duration = 4
        var seed = Int.random(in: 0...2_147_483_637)
        var dryRun = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--provider":
                guard index + 1 < arguments.count else { throw CLIError.usage }
                provider = try GenerationProvider(alias: arguments[index + 1])
                index += 2
            case "--prompt":
                guard index + 1 < arguments.count else { throw CLIError.usage }
                prompt = arguments[index + 1]
                index += 2
            case "--image":
                guard index + 1 < arguments.count else { throw CLIError.usage }
                imageURL = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
                index += 2
            case "--duration":
                guard index + 1 < arguments.count,
                      let value = Int(arguments[index + 1]) else { throw CLIError.usage }
                duration = value
                index += 2
            case "--seed":
                guard index + 1 < arguments.count,
                      let value = Int(arguments[index + 1]) else { throw CLIError.usage }
                seed = value
                index += 2
            case "--dry-run":
                dryRun = true
                index += 1
            default:
                throw CLIError.usage
            }
        }

        let request = GenerationRequest(
            provider: provider,
            prompt: prompt,
            imageURL: imageURL,
            duration: duration,
            seed: seed
        )
        if dryRun {
            printQuote(try PaperwallGenerationService.quote(for: request))
            print("Dry run only; no paid request was made")
            return
        }

        let token = try ReplicateCredentialStore.resolvedToken()
        let wasRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.paperwall.app"
        ).isEmpty
        let result = try await PaperwallGenerationService.generateAndSelect(
            request: request,
            token: token,
            approve: { quote in
                printQuote(quote)
                guard isatty(STDIN_FILENO) != 0 else {
                    print("Interactive approval is required; no paid request was made")
                    return false
                }
                print("Type \"\(quote.approvalPhrase)\" to approve this single paid request:")
                return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == quote.approvalPhrase
            },
            progress: { print($0) }
        )
        if wasRunning { try stop() }
        try start()
        print("Generated: \(result.generatedVideoURL.path)")
        print("Prediction: \(result.predictionID)")
        print("Provider: \(result.provider.rawValue)")
        print(wasRunning ? "Desktop playback reloaded" : "Desktop playback started")
    }

    private static func printQuote(_ quote: GenerationQuote) {
        print("Provider: \(quote.provider.displayName) [\(quote.provider.rawValue), \(quote.provider.modelID)]")
        print("Duration/resolution: \(quote.duration)s / \(quote.resolution)")
        print("Estimated maximum spend: \(quote.formattedCost) USD")
    }

    private static func listWallspace() async throws {
        let urls = AssetLibrary.wallspaceVideos()
        if urls.isEmpty {
            print("No Wallspace videos found at \(AssetLibrary.wallspaceDirectory.path)")
            return
        }
        print("ID\tDIMENSIONS\tDURATION\tSIZE")
        for url in urls {
            do {
                let info = try await VideoAssetValidator.validate(url: url)
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                let megabytes = Double(values.fileSize ?? 0) / 1_048_576
                print("\(url.deletingPathExtension().lastPathComponent)\t\(info.width)x\(info.height)\t\(String(format: "%.2fs", info.duration))\t\(String(format: "%.1fMB", megabytes))")
            } catch {
                print("\(url.lastPathComponent)\tinvalid: \(error.localizedDescription)")
            }
        }
    }

    private static var installedAppURL: URL {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Paperwall.app", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Paperwall.app", isDirectory: true),
        ]
        if let installed = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return installed
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.paperwall.app")
            ?? candidates[0]
    }

    private static var installedSaverURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers/Paperwall.saver", isDirectory: true)
    }

    private static func start() throws {
        guard FileManager.default.fileExists(atPath: installedAppURL.path) else {
            throw CLIError.appNotInstalled
        }
        guard NSWorkspace.shared.open(installedAppURL) else {
            throw CLIError.couldNotStart
        }
        print("Started Paperwall")
    }

    private static func stop() throws {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.paperwall.app"
        )
        if applications.isEmpty {
            print("Paperwall is not running")
            return
        }
        for application in applications where !application.terminate() {
            throw CLIError.couldNotStop
        }
        var deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.paperwall.app").isEmpty {
                print("Paperwall stopped")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: "com.paperwall.app") {
            _ = application.forceTerminate()
        }
        deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.paperwall.app").isEmpty {
                print("Paperwall stopped")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CLIError.couldNotStop
    }

    private static func status() async throws {
        let asset = PaperwallConfiguration.defaultAssetURL
        if FileManager.default.fileExists(atPath: asset.path) {
            let info = try await VideoAssetValidator.validate(url: asset)
            print("Asset: \(asset.path)")
            print("Video: \(info.width)×\(info.height), \(String(format: "%.2f", info.duration))s")
        } else {
            print("Asset: none")
        }
        let running = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.paperwall.app"
        ).isEmpty
        print("Desktop: \(running ? "running" : "stopped")")
        print("Launch at login: \(LaunchAtLoginManager.isEnabled ? "enabled" : "disabled")")
        print("Screen saver: \(FileManager.default.fileExists(atPath: installedSaverURL.path) ? "installed" : "not installed")")
        print("Native fallback: \(await PaperwallService.isNativeFallbackApplied ? "applied" : "not applied")")
    }

    private static func saver(_ arguments: [String]) throws {
        guard arguments.count == 1 else { throw CLIError.usage }
        switch arguments[0] {
        case "status":
            print(FileManager.default.fileExists(atPath: installedSaverURL.path) ? "installed" : "not installed")
        case "settings":
            guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else {
                throw CLIError.couldNotOpenSettings
            }
            guard NSWorkspace.shared.open(url) else { throw CLIError.couldNotOpenSettings }
        default:
            throw CLIError.usage
        }
    }

    private static func printUsage() {
        print("""
        Usage: paperwall <command>

          set VIDEO             Select a local video
          generate [options]    Generate, install, and play an AI wallpaper
            --provider pruna|seedance-1.5|seedance-2.0
            --image IMAGE and/or --prompt TEXT [--duration N] [--seed N] [--dry-run]
          wallspace-list        List cached Wallspace videos
          wallspace-set ID      Select a cached Wallspace video
          start | stop | status Control and inspect desktop playback
          enable | disable      Toggle launch at login
          saver status|settings
          asset                 Print the active asset path
        """)
    }
}

private enum CLIError: Error, LocalizedError {
    case usage
    case appNotInstalled
    case couldNotStart
    case couldNotStop
    case couldNotOpenSettings

    var errorDescription: String? {
        switch self {
        case .usage: "Invalid arguments; run `paperwall help`"
        case .appNotInstalled: "Paperwall.app is not installed in ~/Applications"
        case .couldNotStart: "Could not start Paperwall.app"
        case .couldNotStop: "Could not stop Paperwall.app"
        case .couldNotOpenSettings: "Could not open Screen Saver settings"
        }
    }
}
