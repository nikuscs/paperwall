import AppKit
import PaperwallPlayback
import ScreenSaver

@objc(PaperwallScreenSaverView)
@MainActor
public final class PaperwallScreenSaverView: ScreenSaverView {
    private var playerView: PlayerView?
    private var preparationTask: Task<Void, Never>?
    private var lifecycleGeneration = 0

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        configureFallback()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureFallback()
    }

    public override func startAnimation() {
        super.startAnimation()
        releasePlayback()
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        let assetURL = PaperwallConfiguration.defaultAssetURL

        preparationTask = Task { [weak self] in
            do {
                _ = try await VideoAssetValidator.validate(url: assetURL)
                guard let self,
                      self.isAnimating,
                      self.lifecycleGeneration == generation else { return }
                self.installPlayback(assetURL: assetURL)
            } catch {
                guard let self, self.lifecycleGeneration == generation else { return }
                NSLog("Paperwall screen saver: asset unavailable: %@", error.localizedDescription)
                self.releasePlayback()
            }
        }
    }

    public override func stopAnimation() {
        lifecycleGeneration += 1
        preparationTask?.cancel()
        preparationTask = nil
        releasePlayback()
        super.stopAnimation()
    }

    private func configureFallback() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1.0 / 24.0
    }

    private func installPlayback(assetURL: URL) {
        releasePlayback()
        let view = PlayerView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        view.prepare(assetURL: assetURL)
        view.start()
        playerView = view
    }

    private func releasePlayback() {
        playerView?.stopAndRelease()
        playerView?.removeFromSuperview()
        playerView = nil
    }
}
