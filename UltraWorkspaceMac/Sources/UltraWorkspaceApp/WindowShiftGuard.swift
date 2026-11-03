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
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.dump() }
        }
        private func check() {
            guard let root = window?.contentView else { return }
            var found: [String] = []
            walk(root, depth: 0, into: &found)
            if !found.isEmpty {
                let report = found.joined(separator: " | ")
                if report != lastReport { WireLog.shared.event("window-shift guard: \(report)"); lastReport = report }
            }
        }
        /// One-off layout dump (class, frame) of the window tree, to find what sits above the window.
        private func dump() {
            guard let win = window, let root = win.contentView else { return }
            var lines = ["window=\(Int(win.frame.width))x\(Int(win.frame.height)) content=\(Int(root.frame.width))x\(Int(root.frame.height))"]
            func rec(_ v: NSView, _ d: Int) {
                guard d < 16 else { return }
                let f = v.frame
                let name = String(describing: type(of: v))
                if v.frame.height > 250 || (v.frame.width > 200 && v.frame.width < 270) {
                    lines.append("\(String(repeating: ".", count: d))\(name) x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))\(v.isFlipped ? " flipped" : "")\(v.isHidden ? " hidden" : "")")
                }
                for s in v.subviews { rec(s, d + 1) }
            }
            rec(root, 0)
            for l in lines { WireLog.shared.event("layout: \(l)") }
        }
        /// Any clip view scrolled beyond what its document allows is the glitch; reset it.
        private func walk(_ v: NSView, depth: Int, into out: inout [String]) {
            if let clip = v as? NSClipView {
                let o = clip.bounds.origin
                let docH = clip.documentView?.frame.height ?? 0
                let maxY = max(0, docH - clip.bounds.height)
                if o.y < -1 || o.y > maxY + 1 || abs(o.x) > 1 {
                    out.append("RESET \(type(of: clip)) doc=\(clip.documentView.map { String(describing: type(of: $0)) } ?? "nil") origin=(\(Int(o.x)),\(Int(o.y))) docH=\(Int(docH)) clipH=\(Int(clip.bounds.height)) depth=\(depth)")
                    clip.scroll(to: NSPoint(x: 0, y: min(max(0, o.y), maxY)))
                    clip.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            } else if !(v is NSScrollView), v.bounds.origin != .zero {
                out.append("RESET \(type(of: v)) origin=(\(Int(v.bounds.origin.x)),\(Int(v.bounds.origin.y))) depth=\(depth)")
                v.setBoundsOrigin(.zero)
            }
            for sub in v.subviews { walk(sub, depth: depth + 1, into: &out) }
        }
    }
}
