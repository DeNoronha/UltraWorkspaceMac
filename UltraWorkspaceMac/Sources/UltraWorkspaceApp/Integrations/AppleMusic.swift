import Foundation
import AppKit

/// Controls the local Music.app via Apple Events (AppleScript). First use
/// triggers the macOS Automation permission prompt; the app declares
/// NSAppleEventsUsageDescription for it.
///
/// Everything here runs on the main thread on purpose: Apple documents `NSAppleScript` as usable
/// from the main thread only (Threading Programming Guide, "Thread-Unsafe Classes"; the compile and
/// execute go through the shared OSA component), so the script cannot be moved to a detached task.
/// The cost is kept down by asking less often instead: `AppModel.startMusicPolling` polls every 3 s
/// only while something shows the result and every 30 s otherwise.
@MainActor
enum AppleMusic {
    struct NowPlaying: Equatable {
        var isPlaying: Bool
        var title: String
        var artist: String
        var album: String
        var hasTrack: Bool
    }

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var errorDict: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&errorDict)
        if let errorDict { NSLog("AppleMusic script error: \(errorDict)") }
        return result
    }

    static func playPause() { run(#"tell application "Music" to playpause"#) }
    static func next()      { run(#"tell application "Music" to next track"#) }
    static func previous()  { run(#"tell application "Music" to previous track"#) }

    static func adjustVolume(by delta: Int) {
        run("tell application \"Music\" to set sound volume to (sound volume + \(delta))")
    }

    /// Field separator in the script's reply; a plain "|" occurs in track titles ("Live | Remastered") and
    /// shifted the artist and album into the wrong fields.
    private static let sep = "<|>"

    static func nowPlaying() -> NowPlaying {
        let src = #"""
        tell application "Music"
            if it is not running then return "stopped<|><|><|>"
            set s to (player state as string)
            set t to ""
            set a to ""
            set al to ""
            try
                set t to name of current track
                set a to artist of current track
                set al to album of current track
            end try
            return s & "<|>" & t & "<|>" & a & "<|>" & al
        end tell
        """#
        guard let desc = run(src), let str = desc.stringValue else {
            return NowPlaying(isPlaying: false, title: "", artist: "", album: "", hasTrack: false)
        }
        let parts = str.components(separatedBy: sep)
        let state = parts.count > 0 ? parts[0] : "stopped"
        let title = parts.count > 1 ? parts[1] : ""
        let artist = parts.count > 2 ? parts[2] : ""
        let album = parts.count > 3 ? parts[3] : ""
        return NowPlaying(isPlaying: state == "playing",
                          title: title, artist: artist, album: album,
                          hasTrack: !title.isEmpty)
    }

    /// Raw artwork bytes of the current track (JPEG/PNG/TIFF), if available.
    static func currentArtwork() -> NSImage? {
        let src = #"tell application "Music" to get raw data of artwork 1 of current track"#
        guard let desc = run(src) else { return nil }
        let data = desc.data
        guard !data.isEmpty else { return nil }
        return NSImage(data: data)
    }
}
