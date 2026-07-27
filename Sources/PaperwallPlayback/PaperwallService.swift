import Foundation

@MainActor
public enum PaperwallService {
    @discardableResult
    public static func selectWallpaper(from sourceURL: URL) async throws -> VideoAssetInfo {
        let info = try await AssetLibrary.select(sourceURL)
        try await StaticWallpaperManager.refreshAndApply(
            videoURL: PaperwallConfiguration.defaultAssetURL
        )
        return info
    }

    @discardableResult
    public static func synchronizeActiveWallpaper() async throws -> VideoAssetInfo {
        let assetURL = PaperwallConfiguration.defaultAssetURL
        let info = try await VideoAssetValidator.validate(url: assetURL)
        try await StaticWallpaperManager.refreshAndApply(videoURL: assetURL)
        return info
    }

    public static func applyNativeFallbackToConnectedDisplays() throws {
        try StaticWallpaperManager.applyPoster()
    }

    public static func restorePreviousNativeWallpaper() throws {
        try StaticWallpaperManager.restore()
    }

    public static var isNativeFallbackApplied: Bool {
        StaticWallpaperManager.isApplied
    }
}
