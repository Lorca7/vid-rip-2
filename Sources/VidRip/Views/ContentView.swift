import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            FetchBar()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            Group {
                if let editor = app.editor {
                    EditorView(editor: editor, onClose: { app.closeEditor() })
                        .id(ObjectIdentifier(editor))
                } else {
                    WelcomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 740)
        .dropDestination(for: URL.self) { urls, _ in
            app.handleDrop(urls)
        }
        .alert(item: $app.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message))
        }
    }
}

@MainActor
struct FetchBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste a YouTube link, e.g. https://www.youtube.com/watch?v=…", text: $app.urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { app.fetch() }
                    .disabled(app.isWorking)

                Picker("Quality", selection: $app.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                .help("Maximum resolution to download. 1440p and 4K take longer: they are converted once so they can be previewed.")

                Picker("Cookies", selection: $app.cookies) {
                    ForEach(CookieSource.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                .help("If YouTube asks you to sign in, pick a browser where you're signed in to YouTube.")

                Button {
                    app.fetch()
                } label: {
                    Label("Get Video", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.isWorking || app.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if case .working(let message, let fraction) = app.activity {
                HStack(spacing: 10) {
                    if let fraction {
                        ProgressView(value: fraction)
                            .frame(width: 220)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(message)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Cancel") { app.cancel() }
                }
            }
        }
    }
}

@MainActor
struct WelcomeView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "scissors.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("VidRip")
                .font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Paste a YouTube link above and click **Get Video**.")
                step(2, "Drag the yellow **selection window** on the timeline to choose the part you want. Drag its edges to make it longer or shorter.")
                step(3, "Optionally turn on **Crop Frame** to keep only part of the picture.")
                step(4, "Click **Export Clip**. The clip (with audio) is saved to your Desktop.")
            }
            .frame(maxWidth: 520)
            Button("Or open a video file from your Mac…") { app.openLocalFile() }
                .buttonStyle(.link)
            Text("Only download videos you have the right to use.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
