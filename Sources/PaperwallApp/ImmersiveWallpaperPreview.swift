import AppKit
import PaperwallPlayback
import SwiftUI

struct ImmersiveWallpaperPreview: View {
    let url: URL
    let setWallpaper: () -> Void
    let setSpeed: (PlaybackSpeed) -> Void
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void

    @State private var assetInfo: VideoAssetInfo?
    @State private var fileSize: Int?
    @State private var playbackSpeed = PlaybackPreferences.playbackSpeed

    var body: some View {
        ZStack {
            Color.black
            DiscoveryPlayerPreview(url: url, playbackSpeed: playbackSpeed)
                .id(url)
                .transition(.opacity)

            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.12), .black.opacity(0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack {
                Spacer()
                controlDock
                    .padding(.bottom, 34)
            }
            .padding(.horizontal, 34)
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: url)
        .background {
            LibraryKeyboardMonitor { event in
                guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                    return false
                }
                switch event.keyCode {
                case 123:
                    previous()
                    return true
                case 124:
                    next()
                    return true
                case 36, 76:
                    setWallpaper()
                    return true
                case 53:
                    close()
                    return true
                default:
                    return false
                }
            }
        }
        .onExitCommand(perform: close)
        .task(id: url) {
            assetInfo = nil
            fileSize = nil
            async let info = try? VideoAssetValidator.validate(url: url)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            assetInfo = await info
            fileSize = values?.fileSize
        }
    }

    private var controlDock: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                previewButton(symbol: "chevron.left", action: close)

                VStack(alignment: .leading, spacing: 5) {
                    Text(displayName)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 12) {
                        if let assetInfo {
                            metadata(symbol: "rectangle", text: "\(assetInfo.width)×\(assetInfo.height)")
                        }
                        if let fileSize {
                            metadata(symbol: "doc", text: formattedFileSize(fileSize))
                        }
                        if let assetInfo {
                            metadata(symbol: "clock", text: formattedDuration(assetInfo.duration))
                        }
                    }
                }
                .frame(minWidth: 250, alignment: .leading)

                Spacer(minLength: 8)

                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)

                Button(action: cycleSpeed) {
                    HStack(spacing: 6) {
                        Image(systemName: "tortoise")
                        Text(playbackSpeed.displayName)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 42)
                }
                .buttonStyle(.plain)

                Button(action: setWallpaper) {
                    Text("Set Wallpaper")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 24)
                        .frame(height: 42)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black.opacity(0.86))
                .background(.white.opacity(0.94), in: Capsule())
            }
            .padding(10)
            .frame(maxWidth: 750)
            .glassEffect(
                .regular.tint(.black.opacity(0.1)),
                in: RoundedRectangle(cornerRadius: 28)
            )
        }
    }

    private var displayName: String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(
            of: "-[0-9a-f]{12}$",
            with: "",
            options: .regularExpression
        )
    }

    private func metadata(symbol: String, text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.white.opacity(0.72))
    }

    private func previewButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
    }

    private func cycleSpeed() {
        let speeds = PlaybackSpeed.allCases
        let index = speeds.firstIndex(of: playbackSpeed) ?? 0
        playbackSpeed = speeds[(index + 1) % speeds.count]
        setSpeed(playbackSpeed)
    }

    private func formattedFileSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.1fs", duration)
    }
}
