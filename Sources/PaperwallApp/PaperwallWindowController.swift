import AppKit
import PaperwallPlayback
import SwiftUI

@MainActor
final class PaperwallWindowController: NSWindowController, NSWindowDelegate {
    private let activationChanged: () -> Void

    init(
        wallspaceLibrary: WallspaceLibraryModel,
        generateImage: @escaping (String, @escaping (Result<URL, Error>) -> Void) -> Void,
        generate: @escaping (GenerationRequest, @escaping (Result<GenerationResult, Error>) -> Void) -> Void,
        upscaleVideo: @escaping (URL, @escaping (Result<URL, Error>) -> Void) -> Void,
        chooseVideo: @escaping () -> Void,
        selectWallspace: @escaping (URL) -> Void,
        setPlaybackSpeed: @escaping (PlaybackSpeed) -> Void,
        configureToken: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        activationChanged: @escaping () -> Void
    ) {
        self.activationChanged = activationChanged
        let rootView = PaperwallShellView(
            wallspaceLibrary: wallspaceLibrary,
            generateImage: generateImage,
            generate: generate,
            upscaleVideo: upscaleVideo,
            chooseVideo: chooseVideo,
            selectWallspace: selectWallspace,
            setPlaybackSpeed: setPlaybackSpeed,
            configureToken: configureToken,
            openSettings: openSettings
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Paperwall ®"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 920, height: 600)
        window.center()
        window.contentView = FirstClickHostingView(rootView: rootView)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        activationChanged()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [activationChanged] in
            activationChanged()
        }
        return false
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            window.isMovable = true
            window.performDrag(with: event)
            window.isMovable = false
        }
    }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
