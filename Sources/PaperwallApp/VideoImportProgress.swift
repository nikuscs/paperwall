import Foundation

enum VideoImportProgress: Equatable {
    case idle
    case validating(String)
    case importing
    case upscaling
    case installing
    case completed(URL, wasUpscaled: Bool)
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .validating, .importing, .upscaling, .installing: true
        default: false
        }
    }

    var statusText: String? {
        switch self {
        case .idle: nil
        case .validating(let name): "Validating \(name)…"
        case .importing: "Copying into Paperwall’s synced library…"
        case .upscaling: "Upscaling to 4K… Track details in Work Queue."
        case .installing: "Installing wallpaper on this Mac…"
        case .completed(_, let wasUpscaled):
            wasUpscaled ? "4K upscale complete and installed" : "4K video imported and installed"
        case .failed(let message): message
        }
    }
}
