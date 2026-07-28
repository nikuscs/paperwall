import AppKit
import PaperwallPlayback
import SwiftUI
import UniformTypeIdentifiers

struct PaperwallShellView: View {
    enum Section: String {
        case home = "Home"
        case library = "Library"
        case settings = "Settings"
    }

    private struct MainScrollMetrics: Equatable {
        let offset: CGFloat
        let contentHeight: CGFloat
        let viewportHeight: CGFloat

        var hasMoreBelow: Bool {
            contentHeight > viewportHeight + 2
                && offset + viewportHeight < contentHeight - 12
        }
    }

    private enum PipelineStage: Equatable {
        case idle
        case generatingImage
        case imageReady
        case generatingVideo
        case upscaling
        case ready
        case failed
    }

    @ObservedObject var discoveryLibrary: DiscoveryLibraryModel

    @State private var section: Section = .home
    @State private var mainScrollMetrics = MainScrollMetrics(
        offset: 0,
        contentHeight: 0,
        viewportHeight: 0
    )
    @State private var prompt = ""
    @State private var provider: GenerationProvider = .seedance15
    @State private var duration = 4
    @State private var referenceImageURL: URL?
    @State private var generationError: String?
    @State private var videoImportProgress: VideoImportProgress = .idle
    @State private var playbackSpeed = PlaybackPreferences.playbackSpeed
    @State private var launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
    @State private var showingProviderOptions = false
    @State private var showingDurationOptions = false
    @State private var showingWorkQueue = false
    @State private var workItems: [PaperwallWorkItem] = []
    @State private var generatedImageURL: URL?
    @State private var pipelineStage: PipelineStage = .idle
    @State private var pipelineStatus = ""
    @State private var pipelineError: String?
    @State private var lastGeneratedVideoURL: URL?
    @AppStorage("nativeLockSetupComplete") private var nativeLockSetupComplete = false
    @State private var previewURL: URL?
    @State private var isApplyingWallpaper = false
    @FocusState private var promptFocused: Bool
    @Namespace private var navigationSelection

    let generateImage: (String, @escaping (Result<URL, Error>) -> Void) -> Void
    let generate: (GenerationRequest, @escaping (Result<GenerationResult, Error>) -> Void) -> Void
    let upscaleVideo: (URL, @escaping (Result<URL, Error>) -> Void) -> Void
    let chooseVideo: (@escaping (VideoImportProgress) -> Void) -> Void
    let selectDiscovery: (URL, @escaping (Result<Void, Error>) -> Void) -> Void
    let setPlaybackSpeed: (PlaybackSpeed) -> Void
    let startPlayback: () -> Void
    let stopPlayback: () -> Void
    let toggleLaunchAtLogin: () -> Void
    let configureToken: () -> Void
    let openSettings: () -> Void
    let restartNativeWallpaperServices: () -> Void

    @State private var backgroundImage = StaticShellAssets.loadBackgroundImage()
    private let brandLogo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "PaperwallLogo", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                LinearGradient(
                    colors: [.black.opacity(0.16), .black.opacity(0.56), .black.opacity(0.86)],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )

                if previewURL == nil {
                    mainInterface(size: geometry.size)
                        .frame(width: geometry.size.width - 72, height: geometry.size.height)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        .transition(.opacity)
                }

                if let previewURL {
                    ImmersiveWallpaperPreview(
                        url: previewURL,
                        wallpapers: discoveryLibrary.videos,
                        metadata: discoveryLibrary.metadataByURL[previewURL.standardizedFileURL],
                        selectPreview: { url in
                            withAnimation(.easeInOut(duration: 0.2)) { self.previewURL = url }
                        },
                        isApplyingWallpaper: isApplyingWallpaper,
                        setWallpaper: {
                            guard !isApplyingWallpaper else { return }
                            isApplyingWallpaper = true
                            selectDiscovery(previewURL) { result in
                                isApplyingWallpaper = false
                                guard case .success = result else { return }
                                backgroundImage = StaticShellAssets.loadBackgroundImage()
                                withAnimation(.smooth(duration: 0.3)) {
                                    section = .home
                                    self.previewURL = nil
                                }
                            }
                        },
                        setSpeed: { speed in
                            try? PlaybackPreferences.save(playbackSpeed: speed)
                            setPlaybackSpeed(speed)
                        },
                        saveMetadata: { title, description, tags in
                            discoveryLibrary.updateMetadata(
                                for: previewURL,
                                title: title,
                                description: description,
                                tags: tags
                            )
                        },
                        previous: { movePreview(by: -1) },
                        next: { movePreview(by: 1) },
                        close: {
                            withAnimation(.smooth(duration: 0.3)) {
                                section = .home
                                self.previewURL = nil
                            }
                        }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .transition(.opacity)
                }

                VStack(spacing: 0) {
                    WindowDragRegion()
                        .frame(height: 30)
                        .padding(.leading, 88)
                        .padding(.trailing, 16)
                    Spacer()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .animation(.smooth(duration: 0.3), value: previewURL)
        }
        .frame(minWidth: 920, minHeight: 600)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            if NativeWallpaperExtensionBridge.isNativeWallpaperActivated {
                nativeLockSetupComplete = true
            }
            refreshWorkQueue()
            if let resumable = PaperwallUpscaleService.latestResumableVideoURL() {
                lastGeneratedVideoURL = resumable
                pipelineStage = .failed
                pipelineError = "4K upscaling was interrupted. You can resume safely."
            }
        }
        .task {
            while !Task.isCancelled {
                refreshWorkQueue()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: discoveryLibrary.videos) { _, videos in
            if section == .library, previewURL == nil, let first = videos.first {
                withAnimation(.smooth(duration: 0.3)) { previewURL = first }
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let backgroundImage {
            Image(nsImage: backgroundImage)
                .resizable()
                .scaledToFill()
                .blur(radius: 0.25)
                .overlay(alignment: .trailing) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
        } else {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.12, blue: 0.18), .black],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
        }
    }

    private func mainInterface(size: CGSize) -> some View {
        let viewportHeight = max(0, size.height)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 116)
                        .id("main-top")
                    content
                        .padding(.vertical, 28)
                    Spacer(minLength: 18)
                    bottomPanel
                    Color.clear
                        .frame(height: 44)
                        .id("main-bottom")
                }
                .frame(minHeight: viewportHeight)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: MainScrollMetrics.self) { geometry in
                MainScrollMetrics(
                    offset: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height
                )
            } action: { _, metrics in
                mainScrollMetrics = metrics
            }
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask {
                            LinearGradient(
                                colors: [.black, .black.opacity(0.82), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .allowsHitTesting(false)

                    LinearGradient(
                        colors: [.black.opacity(0.24), .black.opacity(0.08), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)

                    topBar
                        .padding(.top, 44)
                }
                .frame(height: 132, alignment: .top)
            }
            .overlay(alignment: .bottom) {
                if mainScrollMetrics.hasMoreBelow {
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .mask {
                                LinearGradient(
                                    colors: [.clear, .black.opacity(0.9)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                            .frame(height: 88)
                            .allowsHitTesting(false)

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.32)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 88)
                        .allowsHitTesting(false)

                        Button {
                            withAnimation(.smooth(duration: 0.38)) {
                                proxy.scrollTo("main-bottom", anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 38, height: 32)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(true), in: Capsule())
                        .padding(.bottom, 10)
                        .accessibilityLabel("Scroll to more content")
                    }
                    .transition(.opacity)
                }
            }
            .onChange(of: section) { _, _ in
                withAnimation(.smooth(duration: 0.25)) {
                    proxy.scrollTo("main-top", anchor: .top)
                }
            }
        }
    }

    private var topBar: some View {
        ZStack {
            HStack {
                HStack(spacing: 12) {
                    Group {
                        if let brandLogo {
                            Image(nsImage: brandLogo)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .padding(8)
                        } else {
                            Image(systemName: "photo.circle")
                                .font(.system(size: 19, weight: .regular))
                        }
                    }
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.tint(.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 13))
                    Text("Paperwall ®")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        refreshWorkQueue()
                        showingWorkQueue.toggle()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "tray.full")
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 40, height: 40)
                            if workItems.contains(where: \.isActive) {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 8, height: 8)
                                    .offset(x: -2, y: 2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(true), in: Circle())
                    .popover(isPresented: $showingWorkQueue, arrowEdge: .top) {
                        workQueuePopover
                    }
                    .accessibilityLabel("Work queue")

                    circleButton(symbol: "gearshape") {
                        withAnimation(.smooth(duration: 0.32)) { section = .settings }
                    }
                }
            }

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach([Section.home, .library], id: \.self) { item in
                        Button {
                            if item == .library {
                                openLibraryPreview()
                            } else {
                                withAnimation(.smooth(duration: 0.32)) { section = item }
                            }
                        } label: {
                            Text(item.rawValue)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(section == item ? .black : .white)
                                .padding(.horizontal, 18)
                                .frame(height: 36)
                                .background {
                                    if section == item {
                                        Capsule()
                                            .fill(.white.opacity(0.92))
                                            .matchedGeometryEffect(
                                                id: "navigation-selection",
                                                in: navigationSelection
                                            )
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .glassEffect(.regular.interactive(true), in: Capsule())
            }
        }
        .frame(height: 52)
    }

    private var workQueuePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Work Queue")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                Text("\(workItems.count) jobs")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            if workItems.isEmpty {
                ContentUnavailableView(
                    "No generation jobs yet",
                    systemImage: "tray",
                    description: Text("Image, video, and 4K processing will appear here.")
                )
                .frame(height: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(workItems) { item in
                            HStack(spacing: 10) {
                                Image(systemName: workQueueSymbol(for: item))
                                    .foregroundStyle(item.isFailed ? .orange : (item.isActive ? .blue : .green))
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text("\(item.kind.rawValue) · \(item.status.capitalized)")
                                        .font(.system(size: 10, weight: .regular))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if item.isActive {
                                    ProgressView()
                                        .controlSize(.small)
                                } else if let outputURL = item.outputURL,
                                          FileManager.default.fileExists(atPath: outputURL.path) {
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                    } label: {
                                        Image(systemName: "folder")
                                            .frame(width: 28, height: 28)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Show output in Finder")
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 48)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .frame(maxHeight: 330)
            }
        }
        .padding(14)
        .frame(width: 390)
    }

    private func workQueueSymbol(for item: PaperwallWorkItem) -> String {
        if item.isFailed { return "exclamationmark.triangle.fill" }
        if item.isActive { return "clock.arrow.circlepath" }
        return "checkmark.circle.fill"
    }

    private func refreshWorkQueue() {
        workItems = PaperwallWorkQueue.items()
    }

    private var content: some View {
        ZStack(alignment: .leading) {
            if section == .home {
                homeContent
                    .transition(pageTransition)
            }
            if section == .library {
                libraryLoadingContent
                    .transition(pageTransition)
            }
            if section == .settings {
                settingsContent
                    .transition(pageTransition)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.32), value: section)
    }

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity.combined(with: .offset(y: -4))
        )
    }

    private var libraryLoadingContent: some View {
        VStack(spacing: 12) {
            if discoveryLibrary.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading shared wallpapers")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.68))
            } else {
                Image(systemName: "film.stack")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.48))
                Text("No shared wallpapers yet")
                    .font(.system(size: 16, weight: .medium))
                Button("Refresh", action: discoveryLibrary.synchronize)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .glassEffect(.regular.interactive(true), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openLibraryPreview() {
        withAnimation(.smooth(duration: 0.3)) {
            section = .library
            previewURL = discoveryLibrary.videos.first
        }
        if discoveryLibrary.videos.isEmpty { discoveryLibrary.synchronize() }
    }

    private func movePreview(by offset: Int) {
        let videos = discoveryLibrary.videos
        guard !videos.isEmpty else { return }
        let current = previewURL.flatMap { videos.firstIndex(of: $0) } ?? 0
        let next = (current + offset + videos.count) % videos.count
        withAnimation(.easeInOut(duration: 0.2)) {
            previewURL = videos[next]
        }
    }

    private var homeContent: some View {
        HStack {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ANIMATED WALLPAPERS")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.52))

                    Text("Motion that belongs on your Mac.")
                        .font(.system(size: 38, weight: .medium, design: .rounded))
                        .tracking(-1.15)

                    Text("Describe a scene or add a reference image. Paperwall generates it, installs it, and keeps every display in sync.")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.66))
                        .frame(maxWidth: 660, alignment: .leading)
                        .lineSpacing(3)
                }

                if !nativeLockSetupComplete {
                    nativeLockSetupCard
                }

                generationComposer
            }
            .frame(maxWidth: 760, alignment: .leading)
            Spacer(minLength: 80)
        }
    }

    private var nativeLockSetupCard: some View {
        HStack(spacing: 13) {
            Image(systemName: "lock.display")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Enable animated Lock Screen")
                    .font(.system(size: 13, weight: .medium))
                Text("Select Paperwall in Wallpaper settings, then enable Show as Screen Saver.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }

            Spacer(minLength: 10)

            Button("Open Settings", action: openSettings)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .glassEffect(.regular.interactive(true), in: Capsule())

            Button("Done") {
                withAnimation(.smooth(duration: 0.25)) {
                    nativeLockSetupComplete = true
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.66))
        }
        .padding(12)
        .frame(maxWidth: 760)
        .glassEffect(.regular.tint(.black.opacity(0.08)), in: RoundedRectangle(cornerRadius: 18))
        .task {
            while !nativeLockSetupComplete && !Task.isCancelled {
                if NativeWallpaperExtensionBridge.isNativeWallpaperActivated {
                    withAnimation(.smooth(duration: 0.25)) {
                        nativeLockSetupComplete = true
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var generationComposer: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 0) {
                Button {
                    promptFocused = true
                } label: {
                    Label("Generate with AI", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black.opacity(0.84))
                .background(.white.opacity(0.92), in: Capsule())

                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 1, height: 18)
                    .padding(.horizontal, 10)

                Button {
                    chooseVideo { progress in
                        videoImportProgress = progress
                        refreshWorkQueue()
                        if case .completed = progress {
                            discoveryLibrary.synchronize()
                            backgroundImage = StaticShellAssets.loadBackgroundImage()
                        }
                    }
                } label: {
                    Label("Use your own", systemImage: "film")
                        .font(.system(size: 13, weight: .regular))
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.72))
                .disabled(videoImportProgress.isRunning)

                Spacer()

                Text(referenceImageURL == nil ? "Step 1 of 2 · image first" : "Step 2 of 2 · approve animation")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.42))
            }

            if let imageURL = referenceImageURL,
               let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .bottomLeading) {
                        Text("Image ready · approve to animate")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .glassEffect(.regular, in: Capsule())
                            .padding(10)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button(action: clearReferenceImage) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(true), in: Circle())
                        .padding(10)
                    }
            } else {
                TextField(
                    "Describe the image you want to create…",
                    text: $prompt,
                    axis: .vertical
                )
                .focused($promptFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .regular))
                .lineLimit(2...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
            }

            HStack(spacing: 9) {
                Button(action: chooseReferenceImage) {
                    Label(
                        referenceImageURL?.lastPathComponent ?? "Add image",
                        systemImage: referenceImageURL == nil ? "photo.badge.plus" : "photo.fill"
                    )
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 170)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 13)
                .frame(height: 36)
                .glassEffect(.regular.interactive(true), in: Capsule())

                Button {
                    showingProviderOptions.toggle()
                } label: {
                    composerMenuLabel(provider.displayName)
                        .frame(width: 166)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(true), in: Capsule())
                .popover(isPresented: $showingProviderOptions, arrowEdge: .bottom) {
                    optionPopover(width: 220, height: 126) {
                        ForEach(GenerationProvider.availableCases, id: \.self) { option in
                            optionButton(option.displayName, selected: provider == option) {
                                provider = option
                                if !providerDuration.contains(duration) {
                                    duration = providerDuration.lowerBound
                                }
                                showingProviderOptions = false
                            }
                        }
                    }
                }

                Button {
                    showingDurationOptions.toggle()
                } label: {
                    composerMenuLabel("\(duration) sec")
                        .frame(width: 88)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(true), in: Capsule())
                .popover(isPresented: $showingDurationOptions, arrowEdge: .bottom) {
                    optionPopover(width: 120, height: 260) {
                        ForEach(Array(providerDuration), id: \.self) { seconds in
                            optionButton("\(seconds) sec", selected: duration == seconds) {
                                duration = seconds
                                showingDurationOptions = false
                            }
                        }
                    }
                }

                Spacer()

                Button(action: primaryGenerationAction) {
                    HStack(spacing: 7) {
                        if isPipelineRunning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: referenceImageURL == nil ? "photo.badge.plus" : "film")
                        }
                        Text(referenceImageURL == nil ? "Generate Image · \(imageGenerationCost)" : "Animate · \(generationCost)")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 17)
                    .frame(height: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black.opacity(0.86))
                .background(.white.opacity(0.94), in: Capsule())
                .disabled(isPipelineRunning)
            }

            if let importStatus = videoImportProgress.statusText {
                HStack(spacing: 8) {
                    if videoImportProgress.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: importProgressSymbol)
                            .foregroundStyle(importProgressColor)
                    }
                    Text(importStatus)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(videoImportProgress.isRunning ? .white.opacity(0.68) : importProgressColor)
                        .lineLimit(2)
                }
            }

            if isPipelineRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(pipelineStatus)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.68))
                }
            } else if pipelineStage == .ready {
                Label("4K wallpaper ready and installed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            }

            if let pipelineError {
                HStack(spacing: 10) {
                    Label(pipelineError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    Spacer()
                    if lastGeneratedVideoURL != nil {
                        Button("Retry Upscale", action: retryUpscale)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .glassEffect(.regular.interactive(true), in: Capsule())
                    }
                }
            }

            if let generationError {
                Label(generationError, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(.black.opacity(0.06)), in: RoundedRectangle(cornerRadius: 23))
    }

    private func optionPopover<Content: View>(
        width: CGFloat,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(spacing: 4) {
                content()
            }
            .padding(6)
        }
        .scrollIndicators(.hidden)
        .frame(width: width, height: height)
    }

    private func optionButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(selected ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func composerMenuLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 13)
        .frame(height: 36)
        .contentShape(Capsule())
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("SETTINGS")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.52))
                Text("Playback & system")
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .tracking(-0.8)
            }

            VStack(spacing: 0) {
                settingsRow(
                    symbol: "play.circle",
                    title: "Desktop playback",
                    detail: "Start or stop animated wallpaper windows"
                ) {
                    HStack(spacing: 8) {
                        settingsButton("Start", action: startPlayback)
                        settingsButton("Stop", action: stopPlayback)
                    }
                }

                settingsDivider

                settingsRow(
                    symbol: "speedometer",
                    title: "Playback speed",
                    detail: "Applies to the desktop and screen saver"
                ) {
                    HStack(spacing: 3) {
                        ForEach(PlaybackSpeed.allCases, id: \.self) { speed in
                            Button {
                                playbackSpeed = speed
                                setPlaybackSpeed(speed)
                            } label: {
                                Text(speed.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 30)
                                    .foregroundStyle(playbackSpeed == speed ? .black.opacity(0.84) : .white.opacity(0.68))
                                    .background {
                                        if playbackSpeed == speed {
                                            Capsule().fill(.white.opacity(0.9))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                    .frame(width: 190)
                    .glassEffect(.regular.interactive(true), in: Capsule())
                }

                settingsDivider

                settingsRow(
                    symbol: "power",
                    title: "Launch at login",
                    detail: "Start Paperwall automatically after signing in"
                ) {
                    Toggle("", isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: { _ in
                            toggleLaunchAtLogin()
                            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                settingsDivider

                settingsRow(
                    symbol: "lock.display",
                    title: "Native Lock Screen",
                    detail: "One-time setup: select Paperwall in Wallpaper settings"
                ) {
                    settingsButton("Choose Paperwall", action: openSettings)
                }

                settingsDivider

                settingsRow(
                    symbol: "arrow.clockwise.circle",
                    title: "Native wallpaper service",
                    detail: "Restart if the Lock Screen is black after an app update"
                ) {
                    settingsButton("Restart Service", action: restartNativeWallpaperServices)
                }

                settingsDivider

                settingsRow(
                    symbol: "key",
                    title: "Replicate API token",
                    detail: "Stored securely in your macOS Keychain"
                ) {
                    settingsButton("Configure", action: configureToken)
                }

                settingsDivider

                settingsRow(
                    symbol: "folder",
                    title: "Synced Paperwall storage",
                    detail: "Wallpapers and generated media · ~/.config/paperwall"
                ) {
                    settingsButton("Open Folder") {
                        NSWorkspace.shared.open(PaperwallConfiguration.sharedDataDirectory)
                    }
                }

                settingsDivider

                settingsRow(
                    symbol: "internaldrive",
                    title: "Local runtime storage",
                    detail: "Active wallpaper, queue state, logs, and catalog"
                ) {
                    settingsButton("Open Folder") {
                        NSWorkspace.shared.open(PaperwallConfiguration.applicationSupportDirectory)
                    }
                }
            }
            .padding(.horizontal, 16)
            .glassEffect(.regular.tint(.black.opacity(0.06)), in: RoundedRectangle(cornerRadius: 23))
        }
    }

    private func settingsRow<Accessory: View>(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(detail)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.46))
            }
            Spacer()
            accessory()
                .frame(width: 230, alignment: .trailing)
        }
        .frame(height: 58)
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.1))
            .frame(height: 1)
    }

    private func settingsButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .regular))
            .padding(.horizontal, 13)
            .frame(height: 34)
            .glassEffect(.regular.interactive(true), in: Capsule())
    }

    private var providerDuration: ClosedRange<Int> {
        switch provider {
        case .pruna: 1...20
        case .seedance15: 2...12
        case .seedance20: 1...15
        }
    }

    private var isPipelineRunning: Bool {
        [.generatingImage, .generatingVideo, .upscaling].contains(pipelineStage)
    }

    private var importProgressSymbol: String {
        if case .failed = videoImportProgress { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var importProgressColor: Color {
        if case .failed = videoImportProgress { return .orange }
        return .green
    }

    private var imageGenerationCost: String {
        (try? PaperwallImageGenerationService.quote(prompt: prompt).formattedCost) ?? "$0.04"
    }

    private var generationCost: String {
        (try? PaperwallGenerationService.quote(for: generationRequest).formattedCost) ?? "Preview"
    }

    private var generationRequest: GenerationRequest {
        GenerationRequest(
            provider: provider,
            prompt: prompt,
            imageURL: referenceImageURL,
            duration: duration
        )
    }

    private func chooseReferenceImage() {
        let panel = NSOpenPanel()
        panel.message = "Choose an optional reference image"
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        generatedImageURL = nil
        referenceImageURL = panel.url
        generationError = nil
        pipelineError = nil
        pipelineStage = .imageReady
    }

    private func clearReferenceImage() {
        generatedImageURL = nil
        referenceImageURL = nil
        lastGeneratedVideoURL = nil
        generationError = nil
        pipelineError = nil
        pipelineStage = .idle
        promptFocused = true
    }

    private func primaryGenerationAction() {
        if referenceImageURL != nil {
            submitGeneration()
        } else {
            submitImageGeneration()
        }
    }

    private func submitImageGeneration() {
        do {
            _ = try PaperwallImageGenerationService.quote(prompt: prompt)
        } catch {
            generationError = error.localizedDescription
            return
        }

        pipelineStage = .generatingImage
        pipelineStatus = "Step 1 of 3 · generating image"
        pipelineError = nil
        generationError = nil
        generateImage(prompt) { result in
            switch result {
            case .success(let url):
                generatedImageURL = url
                referenceImageURL = url
                pipelineStage = .imageReady
                pipelineStatus = "Image ready"
            case .failure(let error):
                if (error as? GenerationError) == .approvalDeclined {
                    pipelineStage = .idle
                } else {
                    pipelineStage = .failed
                    pipelineError = error.localizedDescription
                }
            }
        }
    }

    private func submitGeneration() {
        let request = generationRequest
        do {
            _ = try PaperwallGenerationService.quote(for: request)
        } catch {
            generationError = error.localizedDescription
            return
        }

        pipelineStage = .generatingVideo
        pipelineStatus = "Step 2 of 3 · generating slow ambient video"
        pipelineError = nil
        generationError = nil
        generate(request) { result in
            switch result {
            case .success(let generated):
                lastGeneratedVideoURL = generated.generatedVideoURL
                beginUpscale(generated.generatedVideoURL)
            case .failure(let error):
                if (error as? GenerationError) == .approvalDeclined {
                    pipelineStage = .imageReady
                } else {
                    pipelineStage = .failed
                    pipelineError = error.localizedDescription
                }
            }
        }
    }

    private func beginUpscale(_ videoURL: URL) {
        pipelineStage = .upscaling
        pipelineStatus = "Step 3 of 3 · upscaling to 4K"
        pipelineError = nil
        upscaleVideo(videoURL) { result in
            switch result {
            case .success:
                pipelineStage = .ready
                pipelineStatus = "4K wallpaper ready"
                pipelineError = nil
            case .failure(let error):
                pipelineStage = .failed
                pipelineError = error.localizedDescription
            }
        }
    }

    private func retryUpscale() {
        guard let lastGeneratedVideoURL else { return }
        beginUpscale(lastGeneratedVideoURL)
    }

    private var bottomPanel: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 12) {
                statusItem(symbol: "desktopcomputer", title: "Desktop", value: "Active")
                divider
                statusItem(symbol: "lock.display", title: "Lock Screen", value: "Ready")
                divider
                statusItem(symbol: "wand.and.stars", title: "AI Models", value: "3 available")
                Spacer()
                Button {
                    withAnimation(.smooth(duration: 0.32)) { section = .settings }
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(true), in: Circle())
            }
            .padding(16)
            .glassEffect(.regular.tint(.black.opacity(0.12)), in: RoundedRectangle(cornerRadius: 25))
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: 1, height: 36)
            .padding(.horizontal, 10)
    }

    private func statusItem(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Text(value)
                    .font(.system(size: 14, weight: .medium))
            }
        }
    }

    private func circleButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(true), in: Circle())
    }
}

private enum StaticShellAssets {
    static var backgroundURL: URL {
        PaperwallConfiguration.applicationSupportDirectory
            .appendingPathComponent("fallback.jpg")
    }

    static func loadBackgroundImage() -> NSImage? {
        guard let data = try? Data(contentsOf: backgroundURL),
              let image = NSImage(data: data) else { return nil }
        image.cacheMode = .always
        return image
    }
}
