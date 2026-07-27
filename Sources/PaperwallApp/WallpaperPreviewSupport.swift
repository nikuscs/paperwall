import AppKit
import PaperwallPlayback
import SwiftUI

@MainActor
struct LibraryKeyboardMonitor: NSViewRepresentable {
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
