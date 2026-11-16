import AppKit
import SwiftUI

/// Test support, off unless VidRip is launched with `--ui-probe <file.json>`.
///
/// Writes the on-screen position of the main controls (in screen points, top-left origin,
/// as used by CGEvent) and the editor's state to a JSON file a few times a second, so an
/// automated test can drive the app with the real mouse and check what happened.
@MainActor
final class UIProbe {
    static let shared = UIProbe()

    private var outputURL: URL?
    private var frames: [String: CGRect] = [:]
    private var timer: Timer?
    weak var editor: EditorModel?

    var isEnabled: Bool { outputURL != nil }

    func start(writingTo url: URL) {
        outputURL = url
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { UIProbe.shared.write() }
        }
    }

    /// Records a control's frame in SwiftUI's global (window) coordinates.
    func record(_ name: String, _ frame: CGRect) {
        guard isEnabled else { return }
        frames[name] = frame
    }

    private func write() {
        guard let outputURL,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let content = window.contentView else { return }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0

        var points: [String: [Double]] = [:]
        for (name, frame) in frames {
            // SwiftUI global coordinates are relative to the window's root view, top-left origin.
            let topLeft = NSPoint(x: frame.minX, y: content.isFlipped ? frame.minY : content.bounds.height - frame.minY)
            let onScreen = window.convertPoint(toScreen: content.convert(topLeft, to: nil))
            points[name] = [Double(onScreen.x), Double(screenHeight - onScreen.y), Double(frame.width), Double(frame.height)]
        }

        var state: [String: Any] = ["windowKey": window.isKeyWindow]
        if let editor {
            state["ready"] = editor.isReady
            state["duration"] = editor.duration
            state["in"] = editor.inPoint
            state["out"] = editor.outPoint
            state["current"] = editor.currentTime
            state["cropEnabled"] = editor.cropEnabled
            state["crop"] = [editor.cropRect.minX, editor.cropRect.minY, editor.cropRect.width, editor.cropRect.height].map(Double.init)
            state["video"] = [Double(editor.videoSize.width), Double(editor.videoSize.height)]
        }

        let json: [String: Any] = ["points": points, "state": state]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            try? data.write(to: outputURL, options: .atomic)
        }
    }
}

extension View {
    /// Reports this view's frame to `UIProbe` (no effect unless probing is on).
    func probe(_ name: String) -> some View {
        background(
            GeometryReader { geometry in
                let frame = geometry.frame(in: .global)
                Color.clear
                    .onAppear { UIProbe.shared.record(name, frame) }
                    .onChange(of: frame) { _, newFrame in UIProbe.shared.record(name, newFrame) }
            }
        )
    }
}
