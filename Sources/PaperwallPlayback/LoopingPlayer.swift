import AVFoundation
import Foundation

@MainActor
public final class LoopingPlayer {
    public let player: AVQueuePlayer

    private var templateItem: AVPlayerItem?
    private var looper: AVPlayerLooper?

    public init(assetURL: URL) {
        let item = AVPlayerItem(url: assetURL)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none

        self.player = player
        self.templateItem = item
        self.looper = AVPlayerLooper(player: player, templateItem: item)
    }

    public var isPrepared: Bool {
        looper != nil && templateItem != nil
    }

    public func start() {
        guard isPrepared else { return }
        setPlaybackSpeed(PlaybackPreferences.playbackSpeed)
        player.play()
    }

    public func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        let rate = Float(speed.rawValue)
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
    }

    public func stop() {
        player.pause()
    }

    public func tearDown() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        templateItem = nil
        player.removeAllItems()
    }

    deinit {
        player.pause()
        looper?.disableLooping()
        player.removeAllItems()
    }
}
