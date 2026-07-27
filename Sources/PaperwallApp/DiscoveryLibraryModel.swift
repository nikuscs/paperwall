import Combine
import Foundation
import PaperwallPlayback

@MainActor
final class DiscoveryLibraryModel: ObservableObject {
    @Published private(set) var videos: [URL] = AssetLibrary.paperwallLibraryVideos()
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func synchronize() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                videos = try await AssetLibrary.synchronizeDiscoveryCache()
            } catch {
                videos = AssetLibrary.paperwallLibraryVideos()
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
