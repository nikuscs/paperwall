import AppKit
import AVFoundation

@MainActor
public final class PlayerView: NSView {
    public private(set) var loopingPlayer: LoopingPlayer?

    private var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else {
            preconditionFailure("PlayerView must be backed by AVPlayerLayer")
        }
        return layer
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    public override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    public func prepare(assetURL: URL) {
        stopAndRelease()
        let loopingPlayer = LoopingPlayer(assetURL: assetURL)
        self.loopingPlayer = loopingPlayer
        playerLayer.player = loopingPlayer.player
    }

    public func start() {
        loopingPlayer?.start()
    }

    public func stop() {
        loopingPlayer?.stop()
    }

    public func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        loopingPlayer?.setPlaybackSpeed(speed)
    }

    public func stopAndRelease() {
        loopingPlayer?.tearDown()
        loopingPlayer = nil
        playerLayer.player = nil
    }
}
