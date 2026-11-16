import AVFoundation
import AppKit
import SwiftUI

/// Shows an AVPlayer's video with no built-in controls (the editor provides its own).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// The video, plus the crop window on top when cropping is on.
@MainActor
struct PlayerArea: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let videoRect = editor.videoSize.width > 0
                ? AVMakeRect(aspectRatio: editor.videoSize, insideRect: bounds)
                : bounds
            ZStack(alignment: .topLeading) {
                PlayerLayerView(player: editor.player)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                if !editor.hasVideo {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 48))
                        Text("Audio only")
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if editor.cropEnabled && editor.hasVideo && videoRect.width > 1 {
                    CropOverlay(editor: editor, videoRect: videoRect)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
