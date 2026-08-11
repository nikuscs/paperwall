import AppKit
import CoreGraphics
import Foundation

@MainActor
enum StaticWallpaperManager {
    private struct Snapshot: Codable {
        var displays: [Display]
    }

    private struct Display: Codable {
        let identifier: String
        let wallpaperURL: URL?
    }

    /// Primary of the two stable paths the system wallpaper points at. macOS records
    /// the URL per Space, and `setDesktopImageURL` only rewrites the Space that is
    /// active on each display, so neither path may ever change and neither file may be
    /// deleted while Paperwall is applied — otherwise every other Space resolves a
    /// missing file and falls back to the wallpaper that was set before Paperwall.
    static var posterURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("fallback.jpg")
    }

    /// Second stable path holding the same image. Each apply sets whichever of the two
    /// poster paths a screen is NOT currently on — a single set call with a genuine URL
    /// change, which forces macOS to reload without the old set-twice-in-a-row trick.
    /// Setting two URLs back to back raced inside WallpaperAgent and could persist the
    /// transient URL mid-transition, leaving Spaces gray after a reboot.
    /// (Keeps the historical "fallback-refresh.jpg" name: existing Spaces reference it.)
    static var alternatePosterURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("fallback-refresh.jpg")
    }

    private static var stagingPosterURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("fallback-staging.jpg")
    }

    static var snapshotURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("native-wallpaper-backup.json")
    }

    static var isApplied: Bool {
        FileManager.default.fileExists(atPath: posterURL.path)
            && FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    static func refreshAndApply(videoURL: URL) async throws {
        try FileManager.default.createDirectory(
            at: PaperwallConfiguration.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingPosterURL) }
        try await generatePoster(for: videoURL, to: stagingPosterURL)
        let poster = try Data(contentsOf: stagingPosterURL)
        try poster.write(to: alternatePosterURL, options: .atomic)
        try poster.write(to: posterURL, options: .atomic)
        try applyPoster()
    }

    static func applyPoster() throws {
        guard FileManager.default.fileExists(atPath: posterURL.path) else {
            throw StaticWallpaperError.missingPoster
        }
        // Both poster paths must always exist and hold the same image: any Space may
        // reference either, and a dangling URL makes macOS fall back to an old wallpaper.
        if !FileManager.default.fileExists(atPath: alternatePosterURL.path) {
            try FileManager.default.copyItem(at: posterURL, to: alternatePosterURL)
        }

        let workspace = NSWorkspace.shared
        let screens = NSScreen.screens
        let posterPaths: Set<URL> = [posterURL.standardizedFileURL, alternatePosterURL.standardizedFileURL]
        var snapshot = try loadSnapshot() ?? Snapshot(displays: [])
        let knownDisplays = Set(snapshot.displays.map(\.identifier))

        for screen in screens {
            let identifier = screen.paperwallIdentifier
            guard !knownDisplays.contains(identifier) else { continue }
            // Never record one of our own poster files as the display's "original"
            // wallpaper — restore would then reinstate Paperwall instead of the user's.
            let current = workspace.desktopImageURL(for: screen)
            let original = current.flatMap { posterPaths.contains($0.standardizedFileURL) ? nil : $0 }
            snapshot.displays.append(Display(
                identifier: identifier,
                wallpaperURL: original
            ))
        }
        try save(snapshot)

        let immediateWallpapers = screens.map { screen in
            (screen, workspace.desktopImageURL(for: screen))
        }
        do {
            for screen in screens {
                let options = workspace.desktopImageOptions(for: screen) ?? [:]
                // Alternate between the two poster paths so every apply is a single
                // set with a genuine URL change — macOS reloads the image (same-URL
                // sets are ignored, and the file is rewritten in place on refresh).
                let current = workspace.desktopImageURL(for: screen)?.standardizedFileURL
                let target = current == posterURL.standardizedFileURL ? alternatePosterURL : posterURL
                try workspace.setDesktopImageURL(target, for: screen, options: options)
            }
        } catch {
            for (screen, url) in immediateWallpapers {
                guard let url else { continue }
                try? workspace.setDesktopImageURL(
                    url,
                    for: screen,
                    options: workspace.desktopImageOptions(for: screen) ?? [:]
                )
            }
            throw error
        }
    }

    static func restore() throws {
        guard let snapshot = try loadSnapshot() else {
            // The poster outlives a restore, so its mere presence no longer means
            // Paperwall owns the desktop — only a display still showing it does.
            let posters: Set<URL> = [posterURL.standardizedFileURL, alternatePosterURL.standardizedFileURL]
            let stillApplied = NSScreen.screens.contains { screen in
                guard let current = NSWorkspace.shared.desktopImageURL(for: screen) else { return false }
                return posters.contains(current.standardizedFileURL)
            }
            if stillApplied {
                throw StaticWallpaperError.missingSnapshot
            }
            return
        }
        let workspace = NSWorkspace.shared
        let screens = NSScreen.screens
        let displays = Dictionary(uniqueKeysWithValues: snapshot.displays.map {
            ($0.identifier, $0.wallpaperURL)
        })
        let immediateWallpapers = screens.map { screen in
            (screen, workspace.desktopImageURL(for: screen))
        }

        do {
            for screen in screens {
                guard let stored = displays[screen.paperwallIdentifier], let url = stored else { continue }
                try workspace.setDesktopImageURL(
                    url,
                    for: screen,
                    options: workspace.desktopImageOptions(for: screen) ?? [:]
                )
            }
        } catch {
            for (screen, url) in immediateWallpapers {
                guard let url else { continue }
                try? workspace.setDesktopImageURL(
                    url,
                    for: screen,
                    options: workspace.desktopImageOptions(for: screen) ?? [:]
                )
            }
            throw error
        }
        // The poster files are deliberately left on disk: Spaces other than the ones
        // just restored still reference them, and a dangling reference makes macOS fall
        // back to an arbitrary older wallpaper. Removing the snapshot is what clears
        // `isApplied`.
        try FileManager.default.removeItem(at: snapshotURL)
    }

    static func generatePoster(for videoURL: URL, to destination: URL) async throws {
        try await FirstFrameExporter.export(
            videoURL: videoURL,
            to: destination,
            quality: 0.92
        )
    }

    private static func loadSnapshot() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotURL))
        // Repair snapshots poisoned by older builds that recorded one of our own
        // poster files as a display's original wallpaper: restoring that would leave
        // Paperwall applied. Keep the display known, but drop the bogus URL.
        let posterPaths: Set<URL> = [posterURL.standardizedFileURL, alternatePosterURL.standardizedFileURL]
        snapshot.displays = snapshot.displays.map { display in
            guard let url = display.wallpaperURL,
                  posterPaths.contains(url.standardizedFileURL) else { return display }
            return Display(identifier: display.identifier, wallpaperURL: nil)
        }
        return snapshot
    }

    private static func save(_ snapshot: Snapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }
}

enum StaticWallpaperError: Error, LocalizedError {
    case missingPoster
    case missingSnapshot
    case couldNotEncodePoster

    var errorDescription: String? {
        switch self {
        case .missingPoster: "Static wallpaper fallback has not been generated"
        case .missingSnapshot: "Cannot restore the previous wallpaper because its backup is missing"
        case .couldNotEncodePoster: "Could not encode the static wallpaper fallback"
        }
    }
}

private extension NSScreen {
    var paperwallIdentifier: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)) else {
            return localizedName
        }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}
