import SwiftUI
import AppKit

/// The sidebar edge is a 1-pt vibrant (NSVisualEffectView) line inside
/// NavigationSplitView's divider, which renders darker than SwiftUI's
/// `Divider()` (pure black in dark mode). This hides it and draws a plain
/// separator line in its place, so it matches the header lines.
/// If AppKit's internals change and nothing is found, the system line stays.
struct SplitDividerFix: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ nsView: Anchor, context: Context) { nsView.fixSoon() }

    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fixSoon()
        }

        func fixSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let root = self?.window?.contentView else { return }
                Self.fix(in: root)
            }
        }

        private var observer: NSObjectProtocol?

        private static func fix(in view: NSView) {
            if let split = view as? NSSplitView, let container = split.superview {
                place(split: split, in: container)
                return
            }
            view.subviews.forEach(fix)
        }

        /// The divider view blends its contents (vibrancy), so the replacement
        /// line lives above the split view and follows the divider around.
        private static func place(split: NSSplitView, in container: NSView) {
            let effects = split.subviews
                .filter { NSStringFromClass(type(of: $0)).contains("SplitDivider") }
                .flatMap { $0.subviews.compactMap { $0 as? NSVisualEffectView } }
            guard let effect = effects.first else { return }
            effects.forEach { $0.isHidden = true }
            let line = container.subviews.compactMap { $0 as? SeparatorLine }.first ?? {
                let l = SeparatorLine()
                container.addSubview(l, positioned: .above, relativeTo: split)
                NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                                       object: split, queue: .main) { [weak l, weak split, weak container] _ in
                    guard let l, let split, let container else { return }
                    place(split: split, in: container)
                    l.needsDisplay = true
                }
                return l
            }()
            // Collapsed sidebar: no line.
            line.isHidden = split.arrangedSubviews.contains { $0.isHidden }
                || (effect.superview?.frame.minX ?? 0) <= 0
            line.frame = effect.convert(effect.bounds, to: container)
        }
    }

    /// Drawn like SwiftUI's Divider over the content background.
    final class SeparatorLine: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? NSColor.hex(0x1E1F21) : NSColor.hex(0xFFFFFF)).setFill()
            bounds.fill()
            NSColor.separatorColor.setFill()
            bounds.fill(using: .sourceOver)
        }
        override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
