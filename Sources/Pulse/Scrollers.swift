import AppKit
import SwiftUI

private struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            observer = observer ?? NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.apply()
            }
        }

        private func apply() {
            DispatchQueue.main.async {
                var views: [NSView] = [self.window?.contentView].compactMap { $0 }
                while let v = views.popLast() {
                    if let scroll = v as? NSScrollView {
                        scroll.scrollerStyle = .overlay
                        scroll.autohidesScrollers = true
                    }
                    views.append(contentsOf: v.subviews)
                }
            }
        }
    }
}

extension View {
    func overlayScrollers() -> some View { background(OverlayScrollers()) }
}
