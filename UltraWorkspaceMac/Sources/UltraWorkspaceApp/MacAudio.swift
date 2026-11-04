import Foundation
import CoreAudio

/// The Mac's output volume through CoreAudio, cached and kept current by property listeners,
/// so the bar's GET_VOLUME is answered at once (2026-11-04). Measured on the bar's own log: with
/// an `osascript` answer (250–600 ms, on the main thread) its PcVolumeDeviceController logged
/// "get volume timeout" on every query and asked again twice a second — ~120 queries a minute —
/// which is what made the KnobKey unusable. A cached value answers in microseconds.
///
/// Reads and writes go where the keyboard's volume keys go: the default output device's main
/// volume (what the menu-bar slider moves), so the speakers attached to the Mac are the ones
/// that change. Devices without a volume control (HDMI / DisplayPort audio) report `nil`.
final class MacAudio: @unchecked Sendable {
    static let shared = MacAudio()

    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`: the device's overall output volume,
    /// also on devices that only expose per-channel controls. Spelled out because the
    /// AudioHardwareService constants are marked deprecated while the selector itself is not.
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663) // 'vmvc'

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "deckhand.macaudio")
    private var device: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var _name = ""
    private var _volume: Int?
    private var _muted = false

    /// Name of the default output device ("KEF Coda W", "MacBook Pro Speakers"…).
    var name: String { lock.withLock { _name } }
    /// 0…100, or nil when the device has no volume control.
    var volume: Int? { lock.withLock { _volume } }
    var muted: Bool { lock.withLock { _muted } }
    var hasControl: Bool { volume != nil }

    private init() {
        deviceListener = { [weak self] _, _ in self?.refresh() }
        var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue) { [weak self] _, _ in self?.attach() }
        attach()
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private var volumeAddress: AudioObjectPropertyAddress { Self.address(Self.virtualMainVolume, scope: kAudioObjectPropertyScopeOutput) }
    private var muteAddress: AudioObjectPropertyAddress { Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput) }

    /// Follow the default output device: move the volume/mute listeners to it and read it.
    private func attach() {
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return }
        lock.lock()
        let old = device
        device = dev
        lock.unlock()
        if let block = deviceListener {
            if old != AudioDeviceID(kAudioObjectUnknown) {
                var va = volumeAddress, ma = muteAddress
                AudioObjectRemovePropertyListenerBlock(old, &va, queue, block)
                AudioObjectRemovePropertyListenerBlock(old, &ma, queue, block)
            }
            var va = volumeAddress, ma = muteAddress
            if AudioObjectHasProperty(dev, &va) { AudioObjectAddPropertyListenerBlock(dev, &va, queue, block) }
            if AudioObjectHasProperty(dev, &ma) { AudioObjectAddPropertyListenerBlock(dev, &ma, queue, block) }
        }
        refresh()
    }

    /// Read name, volume and mute from the device into the cache.
    func refresh() {
        let dev = lock.withLock { device }
        guard dev != AudioDeviceID(kAudioObjectUnknown) else { return }
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var na = Self.address(kAudioObjectPropertyName)
        _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(dev, &na, 0, nil, &size, $0) }
        var va = volumeAddress
        var vol = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        let has = AudioObjectHasProperty(dev, &va) && AudioObjectGetPropertyData(dev, &va, 0, nil, &size, &vol) == noErr
        var ma = muteAddress
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        let muted = AudioObjectHasProperty(dev, &ma) && AudioObjectGetPropertyData(dev, &ma, 0, nil, &size, &mute) == noErr && mute != 0
        lock.withLock {
            _name = name as String
            _volume = has ? Int((vol * 100).rounded()) : nil
            _muted = muted
        }
    }

    /// Set the main output volume (0…100). False when the device has no control.
    @discardableResult
    func setVolume(_ percent: Int) -> Bool {
        let dev = lock.withLock { device }
        let p = max(0, min(100, percent))
        var a = volumeAddress
        var v = Float32(p) / 100
        guard dev != AudioDeviceID(kAudioObjectUnknown), AudioObjectHasProperty(dev, &a),
              AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr else { return false }
        lock.withLock { _volume = p }
        return true
    }

    @discardableResult
    func toggleMute() -> Bool {
        let dev = lock.withLock { device }
        var a = muteAddress
        var m: UInt32 = muted ? 0 : 1
        guard dev != AudioDeviceID(kAudioObjectUnknown), AudioObjectHasProperty(dev, &a),
              AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr else { return false }
        lock.withLock { _muted = m != 0 }
        return true
    }
}
