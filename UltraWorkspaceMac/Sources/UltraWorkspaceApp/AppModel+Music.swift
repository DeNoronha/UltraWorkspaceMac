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

    /// Poll Music every few seconds; auto-push to the cube when the track changes.
    func startMusicPolling() {
        guard musicPollTask == nil else { return }
        musicPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshNowPlaying()
                if self.autoPushNowPlaying {
                    let key = self.nowPlaying.title + "—" + self.nowPlaying.artist
                    if self.nowPlaying.hasTrack, key != self.lastPushedKey {
                        self.lastPushedKey = key
                        self.pushNowPlaying(silent: true)
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopMusicPolling() {
        musicPollTask?.cancel()
        musicPollTask = nil
    }

    /// Render the current track as a card and push it to the selected module.
    func pushNowPlaying(silent: Bool = false) {
        guard let bar = selectedCoreBar, let session = session(for: bar),
              let serial = selectedModuleSerial else {
            if !silent { say("Select a CoreBar and a module first.") }
            return
        }
        guard nowPlaying.hasTrack else {
            if !silent { say("Nothing is playing in Music.") }
            return
        }
        let size = canvasSize
        let pressedSize = max(1, Int(Double(size) * 0.8))
        let art = AppleMusic.currentArtwork()
        let np = nowPlaying
        guard let defRGBA = NowPlayingCard.render(size: size, art: art, title: np.title, artist: np.artist),
              let preRGBA = NowPlayingCard.render(size: pressedSize, art: art, title: np.title, artist: np.artist) else {
            if !silent { say("Could not render the now-playing card.") }
            return
        }
        if !silent { say("Pushing “\(np.title)” to \(serial)…") }
        Task.detached {
            let def = DeviceImage.encode(width: size, height: size, rgba: defRGBA)
            let pre = DeviceImage.encode(width: pressedSize, height: pressedSize, rgba: preRGBA)
            let layer = DeployPackager.Layer(layerId: 1, widgetId: 101, defaultBin: def, pressedBin: pre)
            let tgz = DeployPackager.buildTgz(layers: [layer], defaultLayer: 1)
            do {
                _ = try await session.upload(serial: serial, tgz: tgz)
                await MainActor.run {
                    self.selectFirstLayerAfterSettle(session: session, serial: serial)
                    self.say("Now playing on \(serial): \(np.title) — \(np.artist) ✓")
                }
            } catch {
                await MainActor.run { self.say("Now-playing push failed: \(error.localizedDescription)") }
            }
        }
    }
}
