import AppKit
import SwiftUI

/// A small area chart of recent samples (newest on the right). Optional second series is drawn as a line.
struct SparklineView: View {
    var values: [Double]
    var secondary: [Double]? = nil
    var scale: Sparkline.Scale
    var capacity: Int = MonitorModel.historyCapacity
    var color: Color
    var secondaryColor: Color = .orange
    var height: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            let range = Sparkline.range(for: values + (secondary ?? []), scale: scale)
            func points(_ series: [Double]) -> [CGPoint] {
                Sparkline.points(normalized: Sparkline.normalize(series, range: range), capacity: capacity,
                                 width: Double(size.width), height: Double(size.height - 1))
                    .map { CGPoint(x: $0.x, y: size.height - $0.y) } // Canvas y grows downwards
            }
            let primary = points(values)
            if primary.count >= 2 {
                var area = Path()
                area.move(to: CGPoint(x: primary[0].x, y: size.height))
                primary.forEach { area.addLine(to: $0) }
                area.addLine(to: CGPoint(x: primary[primary.count - 1].x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.45), color.opacity(0.08)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                var line = Path()
                line.addLines(primary)
                context.stroke(line, with: .color(color), lineWidth: 1.2)
            }
            if let secondary {
                let pts = points(secondary)
                if pts.count >= 2 {
                    var line = Path()
                    line.addLines(pts)
                    context.stroke(line, with: .color(secondaryColor), lineWidth: 1.2)
                }
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

/// Reports whether its window is on screen (visible, not occluded / minimised / closed).
/// Used to sample all metrics only while the settings page is actually visible.
struct VisibilityReporter: NSViewRepresentable {
    let onChange: (ObjectIdentifier, Bool) -> Void

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReporterView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: ReporterView, coordinator: ()) {
        view.detach()
    }

    final class ReporterView: NSView {
        var onChange: ((ObjectIdentifier, Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observe(window)
            report()
        }

        func detach() {
            observe(nil)
            if lastReported {
                lastReported = false
                onChange?(ObjectIdentifier(self), false)
            }
        }

        private func observe(_ window: NSWindow?) {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                                              NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                                              NSWindow.didBecomeKeyNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.report(closing: closing) }
                })
            }
        }

        private func report(closing: Bool = false) {
            var visible = false
            if !closing, let window {
                visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            }
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(ObjectIdentifier(self), visible)
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
