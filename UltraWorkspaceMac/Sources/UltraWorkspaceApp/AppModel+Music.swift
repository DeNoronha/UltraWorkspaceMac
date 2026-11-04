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

    /// Fast poll interval while something shows the result, slow one otherwise.
    static let musicPollFast: UInt64 = 3_000_000_000
    static let musicPollSlow: UInt64 = 30_000_000_000

    /// Whether anything is looking at `nowPlaying` right now: the Music card is in the cube's list,
    /// the bar's Music page asked for its data in the last 60 s, or the Widgets page shows the Music
    /// preview. Without `settings` (the launch call) the cube test falls back to the last package sent
    /// in this session.
    func musicWanted(settings: AppSettings?) -> Bool {
        if let settings { if settings.vivoCards.contains(.music) { return true } }
        else if vivoLayerNames.contains(Theme.music.title) { return true }
        if let ago = barPages.secondsSinceHit("music"), ago < 60 { return true }
        return nav == .widgets && selectedAddon == .music
    }

    /// Poll Music so the Music card preview and the bar's Music page stay current. Every 3 s while
    /// `musicWanted` (see there), every 30 s otherwise: `AppleMusic.nowPlaying()` is an AppleScript round
    /// trip that has to run on the main thread (see `AppleMusic`), so it must not run when nothing reads it.
    /// Play / next / previous refresh at once regardless of the interval.
    func startMusicPolling(settings: AppSettings? = nil) {
        guard musicPollTask == nil else { return }
        musicPollTask = Task { [weak self, weak settings] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshNowPlaying()
                // The slow wait is taken in 3 s slices so a page or card that starts wanting it is served within 3 s.
                for _ in 0..<Int(Self.musicPollSlow / Self.musicPollFast) {
                    try? await Task.sleep(nanoseconds: Self.musicPollFast)
                    if Task.isCancelled || self.musicWanted(settings: settings) { break }
                }
            }
        }
    }
}
