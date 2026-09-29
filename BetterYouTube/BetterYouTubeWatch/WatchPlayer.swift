import AVFoundation
import Foundation

@MainActor
final class WatchPlayer: ObservableObject {
    static let shared = WatchPlayer()

    @Published private(set) var current: WatchVideo?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var errorMessage: String?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                                                       queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.elapsed = time.seconds.isFinite ? time.seconds : 0
                let seconds = self?.player.currentItem?.duration.seconds ?? 0
                self?.duration = seconds.isFinite ? seconds : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                              object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false }
        }
    }

    func play(_ video: WatchVideo) async {
        guard let url = WatchDownloads.shared.localURL(for: video) else {
            errorMessage = "Télécharge cette vidéo sur la montre avant de l’écouter."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try await session.activate()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        current = video
        elapsed = 0
        duration = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        isPlaying = true
    }

    func toggle() {
        guard current != nil else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(by seconds: Double) {
        guard current != nil else { return }
        let target = max(0, min(elapsed + seconds, duration > 0 ? duration : .greatestFiniteMagnitude))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        elapsed = target
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        isPlaying = false
        elapsed = 0
        duration = 0
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
