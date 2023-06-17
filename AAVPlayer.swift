import AVFoundation
import UIKit

// MARK: - AVEPreviewVideoPlayerEvent

@frozen
public enum AAVPlayerEvent {
    case updateListenedTime(CMTime)
    case startPlaying
    case pausePlaying
    case endPlaying
    case restartPlaying
    case isReadyForPlay
}

// MARK: - AVEPreviewVideoPlayerDelegate

public protocol AAVPlayerDelegate: AnyObject {
    func aavPlayer(_: AAVPLayer, didReciveEvent type: AAVPlayerEvent)
}

// MARK: - AVEPreviewPlayer

public class AAVPLayer: NSObject {
    
    private enum Constants {
        static let preferredTimescale: Int32 = 600
    }
    
    // MARK: Properties
    
    public let playerLayer: AVPlayerLayer
    public let player = AVPlayer()
    
    public var isPlaying: Bool {
        player.rate != 0 && player.error == nil
    }

    public var isLooped: Bool = true
    
    public var playerItem: AVPlayerItem?
    
    private var playerLayerObserver = 0
    private var playerObserver = 0
    private var playerItemObserver = 0
    private var oftenPeriodicTimeObserver: Any?
    
    private let observers = NSHashTable<AnyObject>.weakObjects()
    
    private var needsStartPlaying: Bool = false
    private var interrupted: Bool = false
    private var initialStart: CMTime = .zero
    
    private var videoTrackSegmentsRanges: [CMTimeRange] = []
    private var currentSegment: Int = 0
    
    // MARK: Initialization
    
    public override init() {
        player.isMuted = false
        player.actionAtItemEnd = .none
        
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        
        super.init()

        createObservers()
    }
    
    deinit {
        pause()
        
        player.removeObserver(self, forKeyPath: #keyPath(AVPlayer.status))
        playerLayer.removeObserver(self, forKeyPath: #keyPath(AVPlayerLayer.isReadyForDisplay))
        removeTimeObserver()
    }
    
    private func createObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillResignActive(notification:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive(notification:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        createPlayerLayerObserver(playerLayer: playerLayer)
        createPlayerObserver(player: player)
        
        setupTimeObserver()
    }
    
    // MARK: Interaction with the player
    
    public func replaceCurrentItem(withAsset asset: AVAsset) {
        asset.loadValuesAsynchronously(forKeys: [
            #keyPath(AVAsset.duration),
            #keyPath(AVAsset.tracks)
        ]) { [weak self] in
            let playerItem = AVPlayerItem(asset: asset)
            self?.replaceCurrentItemSafely(withItem: playerItem)
        }
    }
    
    public func applyAudioMix(_ audioMix: AVAudioMix) {
        playerItem?.audioMix = audioMix
    }
    
    public func seekToStart(completion: (() -> Void)? = nil) {
        seekTo(time: initialStart, completion: completion)
    }
    
    public func seekTo(time: CMTime, completion: (() -> Void)? = nil) {
        removeTimeObserver()
        
        let duration = playerItem?.duration ?? .zero
        let clampedTime = min(max(initialStart, time), duration)
        
        player.seek(to: clampedTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            if self.player.status == .readyToPlay && self.player.rate == .zero {
                if let currentFragmentIndex = self.videoTrackSegmentsRanges.firstIndex(where: { timeRange in
                    timeRange.containsTime(time)
                }), self.currentSegment != currentFragmentIndex {
                    self.player.preroll(atRate: 1.0)
                    self.currentSegment = currentFragmentIndex
                }
            }
            
            self.setupTimeObserver()
            completion?()
        }
    }
    
    public func play() {
        if !readyToPlay() {
            needsStartPlaying = true
            return
        }
        
        if player.rate < 1 {
            player.play()
            notifyObserversAboundHandleEvent(.startPlaying)
        }
    }
    
    public func pause() {
        needsStartPlaying = false
        
        if player.rate > 0 {
            player.pause()
            notifyObserversAboundHandleEvent(.pausePlaying)
        }
    }
    
    // MARK: Private
    
    private func replaceCurrentItemSafely(withItem item: AVPlayerItem) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
        
        playerItem?.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
        
        playerItem = item
        
        createPlayerItemObserver(playerItem: item)
        
        player.replaceCurrentItem(with: playerItem)
        seekToStart()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.handlePlayerItemDidPlayToEnd(notification:)),
            name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
    }
    
    // MARK: Notification Obseervers
    
    @objc
    private func handlePlayerItemDidPlayToEnd(notification: Notification) {
        pause()
        notifyObserversAboundHandleEvent(.endPlaying)
        seekToStart { [weak self] in
            guard
                let self = self,
                self.isLooped
            else { return }
            
            self.play()
            self.notifyObserversAboundHandleEvent(.restartPlaying)
        }
    }
    
    @objc
    private func handleApplicationWillResignActive(notification: Notification) {
        if player.rate > 0 {
            interrupted = true
            pause()
        }
    }
    
    @objc
    private func handleApplicationDidBecomeActive(notification: Notification) {
        if interrupted {
            interrupted = false
            play()
        }
    }
    
    // MARK: Delegate Observers
    
    private func setupTimeObserver() {
        removeTimeObserver()
        
        let observeInterval = CMTime(value: 1, timescale: Constants.preferredTimescale)
        
        oftenPeriodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: observeInterval,
            queue: .main
        ) {  [weak self] time in
            self?.notifyObserversAboundHandleEvent(.updateListenedTime(time))
        }
    }
    
    private func removeTimeObserver() {
        if let oftenPeriodicTimeObserver = oftenPeriodicTimeObserver {
            player.removeTimeObserver(oftenPeriodicTimeObserver)
        }
        
        oftenPeriodicTimeObserver = nil
    }
    
    public func addObserver(_ observer: AAVPlayerDelegate) {
        observers.add(observer)
    }
    
    public func removeObserver(_ observer: AAVPlayerDelegate) {
        observers.remove(observer)
    }
    
    private func eachObserver(_ block: (AAVPlayerDelegate) -> Void) {
        observers.allObjects.forEach { observer in
            block(observer as! AAVPlayerDelegate)
        }
    }
    
    private func notifyObserversAboundHandleEvent(_ event: AAVPlayerEvent) {
        eachObserver { observer in
            observer.aavPlayer(self, didReciveEvent: event)
        }
    }
    
    // MARK: KVO Observers
    
    private func createPlayerObserver(player: AVPlayer) {
        player.addObserver(
            self,
            forKeyPath: #keyPath(AVPlayer.status),
            options: [.old, .new],
            context: &playerObserver
        )
    }
    
    private func createPlayerItemObserver(playerItem: AVPlayerItem) {
        playerItem.addObserver(
            self,
            forKeyPath: #keyPath(AVPlayerItem.status),
            options: [.old, .new],
            context: &playerItemObserver
        )
    }
    
    private func createPlayerLayerObserver(playerLayer: AVPlayerLayer) {
        playerLayer.addObserver(
            self,
            forKeyPath: #keyPath(AVPlayerLayer.isReadyForDisplay),
            options: [.old, .new],
            context: &playerLayerObserver
        )
    }
    
    // MARK: KVO Handling
    
    private func handlePlayerLayerReadyForDisplayChange(readyForDisplay: Bool) {
        if readyForDisplay {
            handlePlayerState()
        }
    }
    
    private func handlePlayer(_ player: AVPlayer, statusChange newStatus: AVPlayer.Status) {
        guard self.player == player else { return }
        handlePlayerState()
    }
    
    private func handlePlayerItem(_ playerItem: AVPlayerItem, statusChange newStatus: AVPlayerItem.Status) {
        guard self.playerItem == playerItem else { return }
        handlePlayerState()
    }
    
    private func handlePlayerState() {
        if readyToPlay() {
            notifyObserversAboundHandleEvent(.isReadyForPlay)
            if needsStartPlaying {
                needsStartPlaying = false
                play()
            }
        }
    }
    
    private func readyToPlay() -> Bool {
        return player.status == .readyToPlay
            && playerItem?.status == .readyToPlay
            && playerLayer.isReadyForDisplay
    }
}

// MARK: Observations

extension AAVPLayer {
    
    public override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey : Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard
            context == &playerItemObserver
            || context == &playerObserver
            || context == &playerLayerObserver
        else {
            super.observeValue(
                forKeyPath: keyPath, of: object, change: change, context: context
            )
            
            return
        }
        
        if keyPath == #keyPath(AVPlayerItem.status) {
            let status: AVPlayerItem.Status
            
            if let statusNumber = change?[.newKey] as? NSNumber {
                status = AVPlayerItem.Status(rawValue: statusNumber.intValue)!
            } else {
                status = .unknown
            }

            switch status {
            case .readyToPlay:
                handlePlayerState()
            default:
                return
            }
        }

        if keyPath == #keyPath(AVPlayer.status) {
            let status: AVPlayer.Status
            
            if let statusNumer = change?[.newKey] as? NSNumber {
                status = AVPlayer.Status(rawValue: statusNumer.intValue)!
            } else {
                status = .unknown
            }

            switch status {
            case .readyToPlay:
                handlePlayerState()
            default:
                return
            }
        }

        if keyPath == #keyPath(AVPlayerLayer.isReadyForDisplay) {
            let isReadyForDisplay = change?[.newKey] as? Bool

            if isReadyForDisplay ?? false {
                handlePlayerState()
            }
        }
    }
    
}
