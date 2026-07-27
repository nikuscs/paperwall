import AppKit
import PaperwallPlayback
import SwiftUI

struct DiscoveryLibraryView: View {
    @ObservedObject var library: DiscoveryLibraryModel
    @State private var selectedURL: URL?

    let openPreview: (URL) -> Void

    private var videos: [URL] { library.videos }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("PAPERWALL LIBRARY")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.52))
                    Text("Preview shared wallpapers")
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .tracking(-0.8)
                }
                Spacer()
                Text("← → Browse  ·  Return Preview")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.42))
                Button(action: library.synchronize) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .regular))
                        .padding(.horizontal, 13)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(true), in: Capsule())
            }

            if videos.isEmpty {
                ContentUnavailableView(
                    library.isLoading ? "Loading shared wallpapers" : "No shared wallpapers",
                    systemImage: library.isLoading ? "arrow.triangle.2.circlepath" : "film.stack",
                    description: Text(
                        library.isLoading
                            ? "Copying Discovery videos into your Paperwall library."
                            : "Open wallpapers in Discovery, then refresh this library."
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 245)
                .glassEffect(.regular.tint(.black.opacity(0.06)), in: RoundedRectangle(cornerRadius: 23))
            } else {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.black.opacity(0.34))
                        if let selectedURL {
                            DiscoveryPlayerPreview(url: selectedURL)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                        } else {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 34, weight: .ultraLight))
                                .foregroundStyle(.white.opacity(0.42))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) {
                        if let selectedURL {
                            Text(displayName(for: selectedURL))
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .glassEffect(.regular, in: Capsule())
                                .padding(12)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let selectedURL {
                            Button { openPreview(selectedURL) } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(true), in: Circle())
                            .padding(12)
                        }
                    }

                    VStack(spacing: 10) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 6) {
                                    ForEach(videos, id: \.self) { url in
                                        Button {
                                            select(url)
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: selectedURL == url ? "play.fill" : "film")
                                                    .font(.system(size: 12, weight: .regular))
                                                    .frame(width: 24, height: 24)
                                                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                                                Text(displayName(for: url))
                                                    .font(.system(size: 13, weight: .regular))
                                                    .lineLimit(1)
                                                Spacer()
                                            }
                                            .padding(.horizontal, 9)
                                            .frame(height: 40)
                                            .background(
                                                selectedURL == url ? .white.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: 11)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .id(url)
                                    }
                                }
                            }
                            .onChange(of: selectedURL) { _, selected in
                                guard let selected else { return }
                                withAnimation(.easeOut(duration: 0.16)) {
                                    proxy.scrollTo(selected, anchor: .center)
                                }
                            }
                        }

                        Button {
                            if let selectedURL { openPreview(selectedURL) }
                        } label: {
                            Label("Open preview", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.black.opacity(0.86))
                        .background(.white.opacity(0.94), in: Capsule())
                        .disabled(selectedURL == nil)
                    }
                    .frame(width: 280)
                    .padding(12)
                    .glassEffect(.regular.tint(.black.opacity(0.06)), in: RoundedRectangle(cornerRadius: 20))
                }
                .frame(height: 250)
            }
        }
        .overlay(alignment: .bottom) {
            if library.isLoading, !videos.isEmpty {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading shared wallpapers")
                        .font(.system(size: 12, weight: .regular))
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 2)
            }
        }
        .background {
            LibraryKeyboardMonitor { event in
                guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                    return false
                }
                switch event.keyCode {
                case 123, 126:
                    moveSelection(by: -1)
                    return true
                case 124, 125:
                    moveSelection(by: 1)
                    return true
                case 36, 76:
                    if let selectedURL { openPreview(selectedURL) }
                    return true
                default:
                    return false
                }
            }
        }
        .onAppear {
            if videos.isEmpty, !library.isLoading { library.synchronize() }
            if let first = videos.first { select(first) }
        }
        .onChange(of: videos) { _, updated in
            if let selectedURL, updated.contains(selectedURL) { return }
            if let first = updated.first {
                select(first)
            } else {
                selectedURL = nil
            }
        }
    }

    private func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(
            of: "-[0-9a-f]{12}$",
            with: "",
            options: .regularExpression
        )
    }

    private func select(_ url: URL) {
        selectedURL = url
    }

    private func moveSelection(by offset: Int) {
        guard !videos.isEmpty else { return }
        let current = selectedURL.flatMap { videos.firstIndex(of: $0) } ?? 0
        let next = min(max(current + offset, videos.startIndex), videos.index(before: videos.endIndex))
        select(videos[next])
    }
}

@MainActor
private struct LibraryKeyboardMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler)
    }

    func makeNSView(context: Context) -> PassthroughView {
        PassthroughView()
    }

    func updateNSView(_ view: PassthroughView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ view: PassthroughView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var handler: (NSEvent) -> Bool
        private var monitor: Any?

        init(handler: @escaping (NSEvent) -> Bool) {
            self.handler = handler
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handler(event) ? nil : event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor
struct DiscoveryPlayerPreview: NSViewRepresentable {
    let url: URL
    var playbackSpeed: PlaybackSpeed = PlaybackPreferences.playbackSpeed

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, playbackSpeed: playbackSpeed)
    }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.prepare(assetURL: url)
        view.start()
        view.setPlaybackSpeed(playbackSpeed)
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            view.prepare(assetURL: url)
            view.start()
        }
        if context.coordinator.playbackSpeed != playbackSpeed {
            context.coordinator.playbackSpeed = playbackSpeed
            view.setPlaybackSpeed(playbackSpeed)
        }
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: Coordinator) {
        view.stopAndRelease()
    }

    @MainActor
    final class Coordinator {
        var url: URL
        var playbackSpeed: PlaybackSpeed

        init(url: URL, playbackSpeed: PlaybackSpeed) {
            self.url = url
            self.playbackSpeed = playbackSpeed
        }
    }
}
