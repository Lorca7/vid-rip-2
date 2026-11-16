import AppKit
import SwiftUI

@MainActor
struct EditorView: View {
    @ObservedObject var editor: EditorModel
    let onClose: () -> Void
    @StateObject private var keys = KeyMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
                Text(editor.clip.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: onClose) {
                    Label("Close Video", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }

            if let error = editor.loadError {
                ContentUnavailableView("Can't open this video", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !editor.isReady {
                ProgressView("Loading video…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PlayerArea(editor: editor)
                    .frame(minHeight: 240)
                    .layoutPriority(1)
                TransportBar(editor: editor)
                TimelineView(editor: editor)
                    .frame(height: 132)
                SelectionBar(editor: editor)
                Divider()
                ExportBar(editor: editor)
            }
        }
        .padding(14)
        .task { await editor.load() }
        .onAppear { keys.install { event in handleKey(event) } }
        .onDisappear { keys.remove() }
    }

    /// Keyboard shortcuts (ignored while typing in a text field).
    private func handleKey(_ event: NSEvent) -> Bool {
        guard editor.isReady, editor.loadError == nil else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: // left arrow
            if shift { editor.step(seconds: -1) } else { editor.step(frames: -1) }
            return true
        case 124: // right arrow
            if shift { editor.step(seconds: 1) } else { editor.step(frames: 1) }
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ":
            editor.togglePlay()
        case "i":
            editor.markIn()
        case "o":
            editor.markOut()
        case "p":
            editor.playSelection()
        case "[":
            editor.seek(to: editor.inPoint)
        case "]":
            editor.seek(to: editor.outPoint)
        default:
            return false
        }
        return true
    }
}

/// Listens for key presses in the window, but lets text fields have them while typing.
@MainActor
final class KeyMonitor: ObservableObject {
    private var monitor: Any?

    func install(_ handler: @escaping @MainActor (NSEvent) -> Bool) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled: Bool = MainActor.assumeIsolated {
                // Let text fields have their keys, and leave ⌘/⌃/⌥ shortcuts to menus.
                if event.window?.firstResponder is NSText { return false }
                if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
                return handler(event)
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

@MainActor
struct TransportBar: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Button { editor.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                .help("Back one frame (←)")
            Button { editor.togglePlay() } label: {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .help("Play / pause (Space)")
            Button { editor.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .help("Forward one frame (→)")

            Text("\(TimeFormat.long(editor.currentTime)) / \(TimeFormat.long(editor.duration))")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().frame(height: 18)

            Button { editor.playSelection() } label: { Label("Play Selection", systemImage: "play.square") }
                .help("Play only the selected part (P)")
            Toggle("Loop", isOn: $editor.loopSelection)
                .toggleStyle(.checkbox)

            Spacer()

            if editor.hasVideo {
                Toggle(isOn: $editor.cropEnabled) {
                    Label("Crop Frame", systemImage: "crop")
                }
                .toggleStyle(.button)
                .help("Show a window over the video to choose which part of the frame to keep. Drag on the picture to draw a new area.")
                .probe("cropToggle")

                if editor.cropEnabled {
                    Picker("Aspect", selection: $editor.cropAspect) {
                        ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    Button("Reset") { editor.resetCrop() }
                }
            }
        }
    }
}

@MainActor
struct SelectionBar: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text("Start").foregroundStyle(.secondary)
                TimecodeField(value: editor.inPoint) { editor.setIn($0) }
                Button("Set to Playhead") { editor.markIn() }
                    .help("Set the start to the playhead (I)")
            }
            HStack(spacing: 6) {
                Text("End").foregroundStyle(.secondary)
                TimecodeField(value: editor.outPoint) { editor.setOut($0) }
                Button("Set to Playhead") { editor.markOut() }
                    .help("Set the end to the playhead (O)")
            }
            Text("Length \(TimeFormat.long(editor.selectionLength))")
                .font(.system(.body, design: .monospaced))
            Spacer()
            Button("Select Whole Video") { editor.selectAll() }
        }
        .controlSize(.regular)
    }
}

/// Editable `MM:SS.mmm` field. `onCommit` returns the value actually applied.
@MainActor
struct TimecodeField: View {
    let value: Double
    let onCommit: (Double) -> Double

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("00:00.000", text: $text)
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .frame(width: 112)
            .focused($focused)
            .onSubmit(commit)
            .onAppear { text = TimeFormat.long(value) }
            .onChange(of: value) { _, newValue in
                if !focused { text = TimeFormat.long(newValue) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        if let parsed = TimeFormat.parse(text) {
            text = TimeFormat.long(onCommit(parsed))
        } else {
            text = TimeFormat.long(value)
        }
    }
}

@MainActor
struct ExportBar: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Format", selection: $editor.exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .frame(width: 400)

                TextField("File name", text: $editor.fileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)
                Toggle("Add times to name", isOn: $editor.includeRangeInName)
                    .toggleStyle(.checkbox)
            }

            HStack(spacing: 10) {
                Button { editor.chooseDestination() } label: {
                    Label("Save to: \(editor.destination.lastPathComponent)", systemImage: "folder")
                }
                .help(editor.destination.path)

                if editor.cropEnabled && editor.exportFormat.hasVideo {
                    let pixels = editor.cropRect.evenPixels
                    Text("Cropped to \(Int(pixels.width))×\(Int(pixels.height))")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                switch editor.exportState {
                case .running(let fraction):
                    ProgressView(value: fraction)
                        .frame(width: 180)
                    Text("\(Int(fraction * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                    Button("Cancel") { editor.cancelExport() }
                case .done(let url):
                    Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Show in Finder") { editor.revealExport() }
                    exportButton
                case .failed(let message):
                    Label("Export failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help(message)
                    exportButton
                case .idle:
                    exportButton
                }
            }
            if case .failed(let message) = editor.exportState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
    }

    private var exportButton: some View {
        Button {
            editor.export()
        } label: {
            Label("Export Clip", systemImage: "square.and.arrow.down")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut("e", modifiers: .command)
        .help("Save the selected part (with audio) as a new file (⌘E)")
    }
}
