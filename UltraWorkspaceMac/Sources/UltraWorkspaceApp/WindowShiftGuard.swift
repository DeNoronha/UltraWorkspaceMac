import SwiftUI
import AppKit
import UltraBarKit

/// Diagnoses and undoes the "whole window content jumps up" AppKit glitch:
/// every 0.5 s it walks up from the root hosting view and, if any ancestor
/// (clip view / hosting view / content view) has a non-zero bounds origin,
/// logs it once and resets it. Legitimate ScrollViews are descendants, never
/// ancestors, of this view, so they are left alone.
struct WindowShiftGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> GuardView { GuardView() }
    func updateNSView(_ nsView: GuardView, context: Context) {}

    final class GuardView: NSView {
        private var timer: Timer?
        private var lastReport = ""
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            guard window != nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        }
        private func check() {
            var v: NSView? = superview
            var fixed: [String] = []
            while let cur = v {
                let o = cur.bounds.origin
                if abs(o.x) > 0.5 || abs(o.y) > 0.5 {
                    fixed.append("\(type(of: cur)) origin=(\(Int(o.x)),\(Int(o.y)))")
                    if let clip = cur as? NSClipView { clip.scroll(to: .zero); clip.enclosingScrollView?.reflectScrolledClipView(clip) }
                    else { cur.setBoundsOrigin(.zero) }
                }
                v = cur.superview
            }
            if !fixed.isEmpty {
                let report = fixed.joined(separator: " > ")
                if report != lastReport { WireLog.shared.event("window-shift guard: reset \(report)"); lastReport = report }
            }
        }
    }
}
