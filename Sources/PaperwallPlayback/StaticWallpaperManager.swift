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

    static var posterURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("fallback.jpg")
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
        let presentationURL = PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("native-fallback-\(UUID().uuidString).jpg")
        do {
            try await generatePoster(for: videoURL, to: presentationURL)
            try Data(contentsOf: presentationURL).write(to: posterURL, options: .atomic)
            try applyPoster(at: presentationURL)
            removeSupersededPresentationPosters(keeping: presentationURL)
        } catch {
            try? FileManager.default.removeItem(at: presentationURL)
            throw error
        }
    }

    static func applyPoster() throws {
        try applyPoster(at: currentPresentationPosterURL())
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
        do {
            for screen in screens {
                try workspace.setDesktopImageURL(
                    appliedPosterURL,
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
    }

    static func restore() throws {
        guard let snapshot = try loadSnapshot() else {
            if FileManager.default.fileExists(atPath: posterURL.path) {
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
        if FileManager.default.fileExists(atPath: posterURL.path) {
            try FileManager.default.removeItem(at: posterURL)
        }
        removeSupersededPresentationPosters(keeping: nil)
        try FileManager.default.removeItem(at: snapshotURL)
    }

    private static func currentPresentationPosterURL() -> URL {
        let candidates = presentationPosterURLs()
        return candidates.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        } ?? posterURL
    }

    private static func presentationPosterURLs() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: PaperwallConfiguration.applicationSupportDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter {
            $0.lastPathComponent.hasPrefix("native-fallback-")
                && $0.pathExtension.lowercased() == "jpg"
        }
    }

    private static func removeSupersededPresentationPosters(keeping retainedURL: URL?) {
        for url in presentationPosterURLs() where url != retainedURL {
            try? FileManager.default.removeItem(at: url)
        }
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
