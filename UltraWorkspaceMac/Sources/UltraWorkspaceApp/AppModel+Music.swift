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
        update(\.nowPlaying, AppleMusic.nowPlaying())
    }

    /// Poll interval while something shows the result.
    static let musicPollFast: Double = 3

    /// Whether anything is looking at `nowPlaying` right now: the Music card is in the cube's list,
    /// the bar's Music page asked for its data in the last 60 s, or the Cube Cards page shows the Music
    /// preview. Without `settings` the cube test falls back to the last package sent in this session.
    /// While this Mac is idle (asleep, screens off, locked) only the bar's Music page counts: the cube does not
    /// switch then (`cubeUnseen`) and the window is not looked at.
    func musicWanted(settings: AppSettings?) -> Bool {
        if let ago = barPages.secondsSinceHit("music"), ago < 60 { return true }
        if PowerState.shared.idle { return false }
        if let settings { if settings.vivoCards.contains(.music) { return true } }
        else if vivoLayerNames.contains(Theme.music.title) { return true }
        return nav == .cubeCards && selectedAddon == .music
    }

    /// Poll Music so the Music card preview and the bar's Music page stay current: every 3 s while
    /// `musicWanted` (see there), every 30 s while only Deckhand Home's tile shows it, not at all otherwise. `AppleMusic.nowPlaying()` is an AppleScript round trip that
    /// has to run on the main thread (see `AppleMusic`), so it must not run when nothing reads it. A page or card
    /// that starts wanting it wakes the poll (`musicWake`: the bar's request, the Cube Cards page, PowerState); the
    /// minute-long wait is only a fallback. Play / next / previous refresh at once regardless.
    func startMusicPolling(settings: AppSettings? = nil) {
        guard musicPollTask == nil else { return }
        musicPollTask = Task { [weak self, weak settings] in
            while !Task.isCancelled {
                guard let self else { return }
                // Deckhand Home's Music tile shows the playing track: every 30 s while Home is on the bar's screen.
                let homeShown = self.barPages.secondsSinceHit("home").map { $0 < 120 } ?? false
                if self.musicWanted(settings: settings) {
                    self.refreshNowPlaying()
                    await Task.relaxedSleep(Self.musicPollFast)
                } else if homeShown {
                    self.refreshNowPlaying()
                    await self.musicWake.wait(30) { self.musicWanted(settings: settings) }
                } else {
                    await self.musicWake.wait(60) {
                        self.musicWanted(settings: settings) || (self.barPages.secondsSinceHit("home").map { $0 < 120 } ?? false)
                    }
                }
            }
        }
    }
}
