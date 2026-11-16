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

            // Bottom layer: drag anywhere on the picture to draw a new crop area.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: videoRect.width, height: videoRect.height)
                .contentShape(Rectangle())
                .gesture(drawGesture)
                .onHover { inside in
                    if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                }
                .probe("video")
                .position(x: videoRect.midX, y: videoRect.midY)

            // The crop window: drag inside it to move it. (Gestures go before `.position`,
            // which would otherwise make each control cover the whole picture.)
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().strokeBorder(Color.yellow, lineWidth: 2))
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .contentShape(Rectangle())
                .gesture(moveGesture)
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .probe("cropRect")
                .position(x: rect.midX, y: rect.midY)

            // Resize handles (corners only when an aspect ratio is locked).
            ForEach(Handle.allCases.filter { !locked || $0.isCorner }) { handle in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.yellow)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.5), lineWidth: 1))
                    .frame(width: handle.isCorner ? 14 : (handle.movesTop || handle.movesBottom ? 28 : 8),
                           height: handle.isCorner ? 14 : (handle.movesLeft || handle.movesRight ? 28 : 8))
                    .padding(6)   // bigger hit area
                    .contentShape(Rectangle())
                    .gesture(resizeGesture(handle))
                    .onHover { inside in
                        if inside { handle.cursor.push() } else { NSCursor.pop() }
                    }
                    .probe("cropHandle.\(handle)")
                    .position(handle.point(in: rect))
            }

            // Output size label.
            let pixels = editor.cropRect.evenPixels
            Text("\(Int(pixels.width)) × \(Int(pixels.height))")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .allowsHitTesting(false)
                .position(x: rect.minX + 46, y: rect.minY + 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "crop")
    }

    /// Converts a point in this view to video pixels, clamped to the picture.
    private func toPixels(_ point: CGPoint) -> CGPoint {
        let size = editor.videoSize
        let x = (point.x - videoRect.minX) / scale
        let y = (point.y - videoRect.minY) / scale
        return CGPoint(x: min(max(x, 0), size.width), y: min(max(y, 0), size.height))
    }

    /// Rectangle from `a` to `b` in video pixels, respecting the locked aspect ratio.
    private func drawnRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let bounds = editor.cropBounds
        var width = abs(b.x - a.x)
        var height = abs(b.y - a.y)
        if let ratio = editor.cropAspect.ratio {
            // Follow the larger movement, then shrink to fit inside the picture.
            if width / max(height, 1) > ratio { height = width / ratio } else { width = height * ratio }
            let maxWidth = b.x >= a.x ? bounds.maxX - a.x : a.x
            let maxHeight = b.y >= a.y ? bounds.maxY - a.y : a.y
            let fit = min(1, maxWidth / max(width, 1), maxHeight / max(height, 1))
            width *= fit
            height *= fit
        }
        let x = b.x >= a.x ? a.x : a.x - width
        let y = b.y >= a.y ? a.y : a.y - height
        return CGRect(x: x, y: y, width: width, height: height).intersection(bounds)
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("crop"))
            .onChanged { value in
                let rect = drawnRect(from: toPixels(value.startLocation), to: toPixels(value.location))
                if rect.width >= 8 && rect.height >= 8 { editor.cropRect = rect }
            }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("crop"))
            .onChanged { value in
                let start = dragStartRect ?? editor.cropRect
                if dragStartRect == nil { dragStartRect = start }
                let bounds = editor.cropBounds
                // A window covering the whole picture can't move, so draw a new one instead.
                if start.width >= bounds.width - 1 && start.height >= bounds.height - 1 {
                    let rect = drawnRect(from: toPixels(value.startLocation), to: toPixels(value.location))
                    if rect.width >= 8 && rect.height >= 8 { editor.cropRect = rect }
                    return
                }
                var moved = start.offsetBy(dx: value.translation.width / scale, dy: value.translation.height / scale)
                moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
                moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
                editor.cropRect = moved
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("crop"))
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
