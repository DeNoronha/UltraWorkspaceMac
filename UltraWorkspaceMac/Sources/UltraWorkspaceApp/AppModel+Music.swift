import Foundation
import AppKit
import UltraBarKit

@MainActor
extension AppModel {
    // Transport
    func musicPlayPause() { AppleMusic.playPause(); refreshNowPlaying() }
    func musicNext() { AppleMusic.next(); refreshNowPlaying() }
    func musicPrevious() { AppleMusic.previous(); refreshNowPlaying() }
    func musicVolume(_ delta: Int) { AppleMusic.adjustVolume(by: delta) }

    func refreshNowPlaying() {
        nowPlaying = AppleMusic.nowPlaying()
    }

    /// Poll Music every few seconds so the Music card preview stays current.
    func startMusicPolling() {
        guard musicPollTask == nil else { return }
        musicPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshNowPlaying()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}
