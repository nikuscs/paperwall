import Combine
import Foundation
import PaperwallPlayback

@MainActor
final class WallspaceLibraryModel: ObservableObject {
    @Published private(set) var videos: [URL] = AssetLibrary.paperwallLibraryVideos()
    @Published private(set) var metadataByURL: [URL: WallpaperMetadata] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func updateMetadata(
        for url: URL,
        title: String,
        description: String,
        tags: [String]
    ) {
        Task {
            do {
                let metadata = try await WallpaperCatalog.shared.update(
                    mediaURL: url,
                    title: title,
                    description: description,
                    tags: tags
                )
                metadataByURL[url.standardizedFileURL] = metadata
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func synchronize() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                _ = try await AssetLibrary.synchronizeWallspaceCache()
                let catalog = try await WallpaperCatalog.shared.refresh()
                videos = AssetLibrary.paperwallLibraryVideos()
                metadataByURL = Dictionary(uniqueKeysWithValues: catalog.map {
                    ($0.mediaURL.standardizedFileURL, $0)
                })
            } catch {
                videos = AssetLibrary.paperwallLibraryVideos()
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
