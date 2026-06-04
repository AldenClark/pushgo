import AVFoundation
import Foundation

@MainActor
final class NotificationSoundPreviewPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = NotificationSoundPreviewPlayer()

    private var player: AVAudioPlayer?
    private var onFinish: (@MainActor () -> Void)?
    private var scopedURL: URL?

    var isPlaying: Bool {
        player?.isPlaying == true
    }

    func play(url: URL, onFinish: @escaping @MainActor () -> Void) throws {
        player?.stop()
        player = nil
        stopScopedAccess()
        self.onFinish = nil

        let didAccess = url.startAccessingSecurityScopedResource()
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            throw error
        }
        player.delegate = self
        player.prepareToPlay()
        player.play()
        self.player = player
        if didAccess {
            scopedURL = url
        }
        self.onFinish = onFinish
    }

    func stop() {
        player?.stop()
        player = nil
        stopScopedAccess()
        onFinish = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if self.player === player {
            self.player = nil
            stopScopedAccess()
            let finish = onFinish
            onFinish = nil
            finish?()
        }
    }

    private func stopScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}
