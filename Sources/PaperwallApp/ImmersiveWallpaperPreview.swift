import AppKit
import AVFoundation
import PaperwallPlayback
import SwiftUI

struct ImmersiveWallpaperPreview: View {
    let url: URL
    let wallpapers: [URL]
    let metadata: WallpaperMetadata?
    let selectPreview: (URL) -> Void
    let isApplyingWallpaper: Bool
    let setWallpaper: () -> Void
    let setSpeed: (PlaybackSpeed) -> Void
    let saveMetadata: (String, String, [String]) -> Void
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void

    @State private var assetInfo: VideoAssetInfo?
    @State private var fileSize: Int?
    @State private var playbackSpeed = PlaybackPreferences.playbackSpeed
    @State private var isWallpaperDrawerExpanded = false
    @State private var isMetadataEditorPresented = false
    @State private var draftTitle = ""
    @State private var draftDescription = ""
    @State private var draftTags = ""

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
                previewNavigation
                    .padding(.top, 52)
                Spacer()
                VStack(spacing: 18) {
                    controlDock
                    if isWallpaperDrawerExpanded {
                        wallpaperDrawer
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 34)

            HStack {
                edgeNavigationButton(symbol: "chevron.left", action: previous)
                Spacer()
                edgeNavigationButton(symbol: "chevron.right", action: next)
            }
            .padding(.horizontal, 26)
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
            loadMetadataDrafts()
        }
    }

    private var previewNavigation: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 4) {
                Button("Home", action: close)
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(.horizontal, 18)
                    .frame(height: 36)

                Text("Library")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.black.opacity(0.86))
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                    .background(.white.opacity(0.92), in: Capsule())
            }
            .padding(6)
            .glassEffect(.regular.interactive(true), in: Capsule())
        }
    }

    private var controlDock: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                previewButton(symbol: "chevron.left", action: close)

                VStack(alignment: .leading, spacing: 5) {
                    Text(metadata?.title ?? displayName)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    if let description = metadata?.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
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
                        ForEach(Array((metadata?.tags ?? []).prefix(3)), id: \.self) { tag in
                            metadata(symbol: "tag", text: tag)
                        }
                    }
                }
                .frame(minWidth: 250, alignment: .leading)

                Spacer(minLength: 8)

                Button {
                    loadMetadataDrafts()
                    isMetadataEditorPresented = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isMetadataEditorPresented, arrowEdge: .bottom) {
                    metadataEditor
                }

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
                    HStack(spacing: 8) {
                        if isApplyingWallpaper {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isApplyingWallpaper ? "Applying…" : "Set Wallpaper")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 24)
                    .frame(height: 42)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black.opacity(0.86))
                .disabled(isApplyingWallpaper)
                .background(.white.opacity(0.94), in: Capsule())
            }
            .padding(10)
            .frame(maxWidth: 750)
            .glassEffect(
                .regular.tint(.black.opacity(0.1)),
                in: RoundedRectangle(cornerRadius: 28)
            )
            .overlay(alignment: .bottom) {
                Button {
                    withAnimation(.smooth(duration: 0.28)) {
                        isWallpaperDrawerExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isWallpaperDrawerExpanded ? 180 : 0))
                        .frame(width: 34, height: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(true), in: Capsule())
                .offset(y: 14)
                .accessibilityLabel(isWallpaperDrawerExpanded ? "Hide wallpapers" : "Show wallpapers")
            }
        }
    }

    private var wallpaperDrawer: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(wallpapers, id: \.self) { wallpaper in
                        Button {
                            selectPreview(wallpaper)
                        } label: {
                            WallpaperDrawerThumbnail(
                                url: wallpaper,
                                isSelected: wallpaper == url
                            )
                        }
                        .buttonStyle(.plain)
                        .id(wallpaper)
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: 750)
            .frame(height: 116)
            .glassEffect(
                .regular.tint(.black.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: 24)
            )
            .onAppear {
                proxy.scrollTo(url, anchor: .center)
            }
            .onChange(of: url) { _, selected in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
        }
    }

    private var metadataEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wallpaper details")
                .font(.system(size: 16, weight: .medium))

            TextField("Title", text: $draftTitle)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $draftDescription)
                    .font(.system(size: 13, weight: .regular))
                    .frame(height: 76)
                    .padding(5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            TextField("Tags, separated by commas", text: $draftTags)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { isMetadataEditorPresented = false }
                Button("Save") {
                    let tags = draftTags.split(separator: ",").map(String.init)
                    saveMetadata(draftTitle, draftDescription, tags)
                    isMetadataEditorPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func loadMetadataDrafts() {
        draftTitle = metadata?.title ?? displayName
        draftDescription = metadata?.description ?? ""
        draftTags = (metadata?.tags ?? []).joined(separator: ", ")
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

    private func edgeNavigationButton(
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(true), in: Circle())
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

private struct WallpaperDrawerThumbnail: View {
    let url: URL
    let isSelected: Bool

    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.28))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.system(size: 20, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )

            Text(displayName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .padding(8)
        }
        .frame(width: 138, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? .white.opacity(0.92) : .white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
        }
        .task(id: url) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 220)
            if let (frame, _) = try? await generator.image(at: .zero) {
                image = NSImage(cgImage: frame, size: .zero)
            }
        }
    }

    private var displayName: String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(
            of: "-[0-9a-f]{12}$",
            with: "",
            options: .regularExpression
        )
    }
}
