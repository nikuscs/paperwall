import AppKit
import AVFoundation
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

    /// Stable path the system wallpaper always points at. macOS records this URL per
    /// Space, and `setDesktopImageURL` only rewrites the Space that is active on each
    /// display, so the path must never change and the file must never be deleted while
    /// Paperwall is applied — otherwise every other Space resolves a missing file and
    /// falls back to the wallpaper that was set before Paperwall.
    static var posterURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("fallback.jpg")
    }

    /// Second stable path holding the same image. Setting it immediately before
    /// `posterURL` forces macOS to drop the desktop image it cached for that URL, which
    /// is what the old per-refresh UUID filenames were working around.
    private static var cacheBustURL: URL {
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
        try poster.write(to: cacheBustURL, options: .atomic)
        try poster.write(to: posterURL, options: .atomic)
        try applyPoster(at: posterURL)
    }

    static func applyPoster() throws {
        try applyPoster(at: posterURL)
    }

    private static func applyPoster(at appliedPosterURL: URL) throws {
        guard FileManager.default.fileExists(atPath: appliedPosterURL.path) else {
            throw StaticWallpaperError.missingPoster
        }

        let workspace = NSWorkspace.shared
        let screens = NSScreen.screens
        var snapshot = try loadSnapshot() ?? Snapshot(displays: [])
        let knownDisplays = Set(snapshot.displays.map(\.identifier))

        for screen in screens {
            let identifier = screen.paperwallIdentifier
            guard !knownDisplays.contains(identifier) else { continue }
            snapshot.displays.append(Display(
                identifier: identifier,
                wallpaperURL: workspace.desktopImageURL(for: screen)
            ))
        }
        try save(snapshot)

        let immediateWallpapers = screens.map { screen in
            (screen, workspace.desktopImageURL(for: screen))
        }
        let shouldBustCache = appliedPosterURL == posterURL
            && FileManager.default.fileExists(atPath: cacheBustURL.path)
        do {
            for screen in screens {
                let options = workspace.desktopImageOptions(for: screen) ?? [:]
                if shouldBustCache {
                    try? workspace.setDesktopImageURL(cacheBustURL, for: screen, options: options)
                }
                try workspace.setDesktopImageURL(appliedPosterURL, for: screen, options: options)
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
            let posters: Set<URL> = [posterURL.standardizedFileURL, cacheBustURL.standardizedFileURL]
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
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: .zero)
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.92]
        ) else {
            throw StaticWallpaperError.couldNotEncodePoster
        }
        try data.write(to: destination, options: .atomic)
    }

    private static func loadSnapshot() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotURL))
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
