import AppKit
import CoreGraphics
import PaperwallPlayback

@MainActor
final class WallpaperController: NSObject {
    private struct DisplayWallpaper {
        let window: WallpaperWindow
        let playerView: PlayerView
    }

    private var wallpapers: [CGDirectDisplayID: DisplayWallpaper] = [:]
    private var desiredRunning = false
    private var requestGeneration = 0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func start() async {
        desiredRunning = true
        requestGeneration += 1
        let generation = requestGeneration
        let assetURL = PaperwallConfiguration.defaultAssetURL

        do {
            _ = try await PaperwallService.synchronizeActiveWallpaper()
        } catch {
            guard desiredRunning, generation == requestGeneration else { return }
            stopWindows()
            NSLog("Paperwall: wallpaper unavailable: %@", error.localizedDescription)
            return
        }

        guard desiredRunning, generation == requestGeneration else { return }
        synchronizeWindows(assetURL: assetURL)
    }

    func stop() {
        desiredRunning = false
        requestGeneration += 1
        stopWindows()
    }

    func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        for wallpaper in wallpapers.values {
            wallpaper.playerView.setPlaybackSpeed(speed)
        }
    }

    @objc private func screenParametersDidChange() {
        guard desiredRunning else { return }
        do {
            try PaperwallService.applyNativeFallbackToConnectedDisplays()
        } catch {
            NSLog("Paperwall: could not apply fallback to changed displays: %@", error.localizedDescription)
        }
        synchronizeWindows(assetURL: PaperwallConfiguration.defaultAssetURL)
    }

    private func synchronizeWindows(assetURL: URL) {
        let currentScreens = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                screen.displayID.map { ($0, screen) }
            }
        )

        for (displayID, wallpaper) in wallpapers where currentScreens[displayID] == nil {
            wallpaper.playerView.stopAndRelease()
            wallpaper.window.close()
            wallpapers.removeValue(forKey: displayID)
        }

        for (displayID, screen) in currentScreens {
            if let wallpaper = wallpapers[displayID] {
                wallpaper.window.setFrame(screen.frame, display: true)
                wallpaper.window.orderBack(nil)
                continue
            }

            let window = WallpaperWindow(screen: screen)
            let playerView = PlayerView(frame: window.contentView?.bounds ?? .zero)
            playerView.autoresizingMask = [.width, .height]
            playerView.prepare(assetURL: assetURL)
            window.contentView?.addSubview(playerView)
            playerView.start()
            window.orderBack(nil)
            wallpapers[displayID] = DisplayWallpaper(window: window, playerView: playerView)
        }
    }

    private func stopWindows() {
        for wallpaper in wallpapers.values {
            wallpaper.playerView.stopAndRelease()
            wallpaper.window.close()
        }
        wallpapers.removeAll()
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

@MainActor
private final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
