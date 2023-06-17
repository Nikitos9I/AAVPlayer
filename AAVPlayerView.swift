import UIKit
import AVFoundation

class AAVPlayerView: UIView {
    
    private lazy var playerView: UIView = {
        let view = UIView()
        view.layer.addSublayer(player.playerLayer)
        return view
    }()
    
    private let player = AAVPLayer()
    
    // MARK: Initialization
    
    init() {
        super.init(frame: .zero)
        
        configureView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSublayers(of layer: CALayer) {
        super.layoutSublayers(of: layer)
        
        player.playerLayer.frame = bounds.insetBy(
            dx: -1 / UIScreen.main.scale,
            dy: -1 / UIScreen.main.scale
        )
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        playerView.frame = bounds
    }
    
    // MARK: Configure
    
    func configure(url: URL) {
        let asset = AVURLAsset(url: url)
        player.replaceCurrentItem(withAsset: asset)
    }
    
    private func configureView() {
        addSubview(playerView)
        
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: .mixWithOthers
            )
        } catch {
            Log.error(error)
        }
    }
    
    // MARK: Playback
    
    func play() {
        player.play()
    }
    
    func pause() {
        player.pause()
    }
}
