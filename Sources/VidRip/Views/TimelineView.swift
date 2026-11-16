import AppKit
import SwiftUI

/// Filmstrip timeline with the selection window: drag the yellow window to move it,
/// drag its handles to expand or shrink it. Zoom in for precise selections.
@MainActor
struct TimelineView: View {
    @ObservedObject var editor: EditorModel
    @State private var zoom: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1) * min(zoom, maxZoom(for: geometry.size.width))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: zoom > 1.01) {
                        TimelineTrack(editor: editor, width: width, height: geometry.size.height)
                            .frame(width: width, height: geometry.size.height)
                            .id("track")
                    }
                    .onChange(of: zoom) { _, _ in
                        // Keep the selection in view when zooming.
                        let anchor = editor.duration > 0 ? (editor.inPoint + editor.outPoint) / 2 / editor.duration : 0
                        proxy.scrollTo("track", anchor: UnitPoint(x: anchor, y: 0.5))
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...12)
                    .frame(width: 180)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Button("Zoom to Selection") { zoomToSelection() }
                    .controlSize(.small)
                Button("Fit") { zoom = 1 }
                    .controlSize(.small)
                Spacer()
                Text("Drag the yellow window to move it · drag its edges to resize · click anywhere on the timeline to place the playhead")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// Very wide views can't be drawn, so cap the zoomed width.
    private func maxZoom(for baseWidth: CGFloat) -> Double {
        max(1, Double(14_000 / max(baseWidth, 1)))
    }

    private func zoomToSelection() {
        guard editor.selectionLength > 0 else { return }
        zoom = min(max(editor.duration / (editor.selectionLength * 1.4), 1), 12)
    }
}

@MainActor
struct TimelineTrack: View {
    @ObservedObject var editor: EditorModel
    let width: CGFloat
    let height: CGFloat

    @State private var dragOrigin: (start: Double, end: Double)?

    private let rulerHeight: CGFloat = 20
    private let handleWidth: CGFloat = 14
    private var pad: CGFloat { handleWidth }
    private var usable: CGFloat { max(width - pad * 2, 1) }
    private var stripHeight: CGFloat { max(height - rulerHeight, 10) }

    private func x(_ seconds: Double) -> CGFloat {
        guard editor.duration > 0 else { return pad }
        return pad + CGFloat(seconds / editor.duration) * usable
    }

    private func time(_ x: CGFloat) -> Double {
        editor.duration * Double(min(max((x - pad) / usable, 0), 1))
    }

    private func seconds(forDistance dx: CGFloat) -> Double {
        editor.duration * Double(dx / usable)
    }

    var body: some View {
        let inX = x(editor.inPoint)
        let outX = x(editor.outPoint)
        let stripMid = rulerHeight + stripHeight / 2

        // Note: gestures and hover handlers must be attached *before* `.position`,
        // because `.position` makes a view fill its whole parent; otherwise the topmost
        // control would capture every click on the timeline.
        ZStack(alignment: .topLeading) {
            // Bottom layer: click or drag anywhere on the timeline to place the playhead.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(scrubGesture)
                .probe("track")

            Ruler(duration: editor.duration, pad: pad)
                .frame(width: width, height: rulerHeight)
                .allowsHitTesting(false)

            Filmstrip(images: editor.thumbnails, hasVideo: editor.hasVideo)
                .frame(width: usable, height: stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .allowsHitTesting(false)
                .position(x: pad + usable / 2, y: stripMid)

            // Dim what's outside the selection.
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .frame(width: max(inX - pad, 0), height: stripHeight)
                .allowsHitTesting(false)
                .position(x: pad + max(inX - pad, 0) / 2, y: stripMid)
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .frame(width: max(pad + usable - outX, 0), height: stripHeight)
                .allowsHitTesting(false)
                .position(x: outX + max(pad + usable - outX, 0) / 2, y: stripMid)

            // Selection window body: drag to move it (keeping its length), click to place the playhead.
            Rectangle()
                .fill(Color.yellow.opacity(0.08))
                .overlay(Rectangle().strokeBorder(Color.yellow, lineWidth: 3))
                .frame(width: max(outX - inX, 2), height: stripHeight)
                .contentShape(Rectangle())
                .gesture(moveGesture)
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .probe("selection")
                .position(x: (inX + outX) / 2, y: stripMid)

            // Left and right handles: drag to expand or shrink the window.
            SelectionHandle(edge: .leading)
                .frame(width: handleWidth, height: stripHeight)
                .contentShape(Rectangle())
                .gesture(handleGesture(isStart: true))
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .probe("leftHandle")
                .position(x: inX - handleWidth / 2, y: stripMid)
            SelectionHandle(edge: .trailing)
                .frame(width: handleWidth, height: stripHeight)
                .contentShape(Rectangle())
                .gesture(handleGesture(isStart: false))
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .probe("rightHandle")
                .position(x: outX + handleWidth / 2, y: stripMid)

            // Playhead.
            Playhead()
                .frame(width: 11, height: height)
                .allowsHitTesting(false)
                .position(x: x(editor.currentTime), y: height / 2)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .coordinateSpace(name: "timeline")
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                editor.pause()
                editor.seek(to: time(value.location.x))
            }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = (editor.inPoint, editor.outPoint)
                    editor.pause()
                }
                guard let origin = dragOrigin, abs(value.translation.width) >= 2 else { return }
                let length = origin.end - origin.start
                let start = min(max(origin.start + seconds(forDistance: value.translation.width), 0), editor.duration - length)
                editor.setSelection(start: start, end: start + length)
                editor.seek(to: start)
            }
            .onEnded { value in
                if abs(value.translation.width) < 2 {
                    editor.seek(to: time(value.location.x))
                }
                dragOrigin = nil
            }
    }

    private func handleGesture(isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = (editor.inPoint, editor.outPoint)
                    editor.pause()
                }
                guard let origin = dragOrigin else { return }
                let delta = seconds(forDistance: value.translation.width)
                if isStart {
                    let start = min(max(origin.start + delta, 0), origin.end - editor.minimumSelection)
                    editor.setSelection(start: start, end: origin.end)
                    editor.seek(to: editor.inPoint)
                } else {
                    let end = max(min(origin.end + delta, editor.duration), origin.start + editor.minimumSelection)
                    editor.setSelection(start: origin.start, end: end)
                    editor.seek(to: editor.outPoint)
                }
            }
            .onEnded { _ in dragOrigin = nil }
    }
}

@MainActor
private struct SelectionHandle: View {
    enum Edge { case leading, trailing }
    let edge: Edge

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? 5 : 0,
            bottomLeadingRadius: edge == .leading ? 5 : 0,
            bottomTrailingRadius: edge == .trailing ? 5 : 0,
            topTrailingRadius: edge == .trailing ? 5 : 0
        )
        .fill(Color.yellow)
        .overlay(
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(Color.black.opacity(0.55)).frame(width: 4, height: 2)
                }
            }
        )
        .contentShape(Rectangle())
    }
}

@MainActor
private struct Playhead: View {
    var body: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Color.red)
                .frame(width: 11, height: 8)
            Rectangle()
                .fill(Color.red)
                .frame(width: 2)
        }
        .shadow(color: .black.opacity(0.4), radius: 1)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

@MainActor
private struct Filmstrip: View {
    let images: [CGImage]
    let hasVideo: Bool

    var body: some View {
        GeometryReader { geometry in
            if images.isEmpty {
                ZStack {
                    Rectangle().fill(Color.gray.opacity(0.25))
                    if !hasVideo {
                        Image(systemName: "waveform")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                let cellWidth = geometry.size.width / CGFloat(images.count)
                HStack(spacing: 0) {
                    ForEach(images.indices, id: \.self) { index in
                        Image(decorative: images[index], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: cellWidth, height: geometry.size.height)
                            .clipped()
                    }
                }
            }
        }
        .background(Color.black)
    }
}

@MainActor
private struct Ruler: View {
    let duration: Double
    let pad: CGFloat

    var body: some View {
        Canvas { context, size in
            let usable = size.width - pad * 2
            guard duration > 0, usable > 0 else { return }
            let pixelsPerSecond = usable / duration
            let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
            let step = steps.first { $0 * pixelsPerSecond >= 70 } ?? 7200
            let minor = step / 5

            var t = 0.0
            var index = 0
            while t <= duration + 0.0001 {
                let x = pad + CGFloat(t) * pixelsPerSecond
                let major = index % 5 == 0
                let tickHeight: CGFloat = major ? 7 : 3
                context.fill(Path(CGRect(x: x, y: size.height - tickHeight, width: 1, height: tickHeight)),
                             with: .color(.secondary))
                if major {
                    context.draw(
                        Text(TimeFormat.ruler(t, step: step))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.secondary),
                        at: CGPoint(x: x + 3, y: 1),
                        anchor: .topLeading
                    )
                }
                index += 1
                t = Double(index) * minor
            }
        }
    }
}
