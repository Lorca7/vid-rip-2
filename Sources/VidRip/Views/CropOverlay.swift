import AppKit
import SwiftUI

/// A movable, resizable window drawn over the video that chooses which part of the
/// frame is kept on export.
@MainActor
struct CropOverlay: View {
    @ObservedObject var editor: EditorModel
    /// Where the video is drawn inside this view.
    let videoRect: CGRect

    @State private var dragStartRect: CGRect?

    enum Handle: CaseIterable, Identifiable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var id: Self { self }
        var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }
        var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

        func point(in rect: CGRect) -> CGPoint {
            let x = movesLeft ? rect.minX : (movesRight ? rect.maxX : rect.midX)
            let y = movesTop ? rect.minY : (movesBottom ? rect.maxY : rect.midY)
            return CGPoint(x: x, y: y)
        }

        @MainActor var cursor: NSCursor {
            switch self {
            case .left, .right: .resizeLeftRight
            case .top, .bottom: .resizeUpDown
            default: .crosshair
            }
        }
    }

    private var scale: CGFloat {
        videoRect.width / max(editor.videoSize.width, 1)
    }

    private func toView(_ rect: CGRect) -> CGRect {
        CGRect(x: videoRect.minX + rect.minX * scale,
               y: videoRect.minY + rect.minY * scale,
               width: rect.width * scale,
               height: rect.height * scale)
    }

    var body: some View {
        let rect = toView(editor.cropRect)
        let locked = editor.cropAspect.ratio != nil

        ZStack(alignment: .topLeading) {
            // Darken everything outside the crop window.
            Path { path in
                path.addRect(videoRect)
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Rule-of-thirds guides.
            Path { path in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 1)
            .allowsHitTesting(false)

            // The window body: drag to move.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().strokeBorder(Color.yellow, lineWidth: 2))
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .position(x: rect.midX, y: rect.midY)
                .gesture(moveGesture)
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }

            // Resize handles (corners only when an aspect ratio is locked).
            ForEach(Handle.allCases.filter { !locked || $0.isCorner }) { handle in
                let point = handle.point(in: rect)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.yellow)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.5), lineWidth: 1))
                    .frame(width: handle.isCorner ? 14 : (handle.movesTop || handle.movesBottom ? 28 : 8),
                           height: handle.isCorner ? 14 : (handle.movesLeft || handle.movesRight ? 28 : 8))
                    .padding(6)   // bigger hit area
                    .contentShape(Rectangle())
                    .position(point)
                    .gesture(resizeGesture(handle))
                    .onHover { inside in
                        if inside { handle.cursor.push() } else { NSCursor.pop() }
                    }
            }

            // Output size label.
            let pixels = editor.cropRect.evenPixels
            Text("\(Int(pixels.width)) × \(Int(pixels.height))")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .position(x: rect.minX + 46, y: rect.minY + 14)
                .allowsHitTesting(false)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStartRect ?? editor.cropRect
                if dragStartRect == nil { dragStartRect = start }
                let bounds = editor.cropBounds
                var moved = start.offsetBy(dx: value.translation.width / scale, dy: value.translation.height / scale)
                moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
                moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
                editor.cropRect = moved
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStartRect ?? editor.cropRect
                if dragStartRect == nil { dragStartRect = start }
                editor.cropRect = resized(start, handle: handle,
                                          dx: value.translation.width / scale,
                                          dy: value.translation.height / scale)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    /// Resizes `start` by dragging `handle` by (dx, dy) video pixels.
    private func resized(_ start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let bounds = editor.cropBounds
        let minSize: CGFloat = max(32, min(bounds.width, bounds.height) * 0.05)
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY

        if handle.movesLeft { minX = min(max(start.minX + dx, 0), maxX - minSize) }
        if handle.movesRight { maxX = max(min(start.maxX + dx, bounds.maxX), minX + minSize) }
        if handle.movesTop { minY = min(max(start.minY + dy, 0), maxY - minSize) }
        if handle.movesBottom { maxY = max(min(start.maxY + dy, bounds.maxY), minY + minSize) }

        var width = maxX - minX
        var height = maxY - minY

        guard let ratio = editor.cropAspect.ratio, handle.isCorner else {
            return CGRect(x: minX, y: minY, width: width, height: height)
        }

        // Keep the aspect ratio, anchored at the opposite corner. Shrinking only, so it stays in bounds.
        if width / height > ratio { width = height * ratio } else { height = width / ratio }
        let anchorX = handle.movesLeft ? start.maxX : start.minX
        let anchorY = handle.movesTop ? start.maxY : start.minY
        let x = handle.movesLeft ? anchorX - width : anchorX
        let y = handle.movesTop ? anchorY - height : anchorY
        return CGRect(x: x, y: y, width: width, height: height).intersection(bounds)
    }
}
