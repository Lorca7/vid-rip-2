import AppKit
import Foundation
import UniformTypeIdentifiers

struct Clip {
    let fileURL: URL
    let title: String
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Top-level state: fetching a video and holding the open editor.
@MainActor
final class AppModel: ObservableObject {
    enum Activity: Equatable {
        case idle
        case working(String, Double?)
    }

    @Published var urlText = ""
    @Published var quality: VideoQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    @Published var cookies: CookieSource {
        didSet { UserDefaults.standard.set(cookies.rawValue, forKey: "cookies") }
    }
    @Published private(set) var activity: Activity = .idle
    @Published var alert: AlertInfo?
    @Published private(set) var editor: EditorModel?

    private var job: Task<Void, Never>?
    private var jobID = UUID()
    private let toolsReady: Task<Void, Never>

    init() {
        quality = VideoQuality(rawValue: UserDefaults.standard.integer(forKey: "quality")) ?? .p1080
        cookies = CookieSource(rawValue: UserDefaults.standard.string(forKey: "cookies") ?? "") ?? .none
        toolsReady = Task.detached(priority: .userInitiated) {
            ToolBox.shared.prepare()
        }
        handleLaunchArguments()
    }

    // MARK: Launch arguments

    /// `--open <file>` opens a video at launch. Adding `--selftest-export <output.mp4>` also
    /// selects 1.0–2.5 s, crops to a square, exports, and quits (exit 0 on success).
    /// Used by the automated build to check the whole editing pipeline.
    private func handleLaunchArguments() {
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let probePath = value(after: "--ui-probe") {
            UIProbe.shared.start(writingTo: URL(fileURLWithPath: probePath))
        }
        guard let path = value(after: "--open") else { return }
        let selfTestOutput = value(after: "--selftest-export").map { URL(fileURLWithPath: $0) }

        Task {
            openLocalFile(URL(fileURLWithPath: path))
            guard let output = selfTestOutput else { return }
            await runSelfTest(output: output)
        }
    }

    private func runSelfTest(output: URL) async {
        func finish(_ code: Int32, _ message: String) -> Never {
            FileHandle.standardError.write(Data("VidRip self-test: \(message)\n".utf8))
            exit(code)
        }
        let deadline = Date().addingTimeInterval(240)
        while editor == nil {
            if let alert { finish(1, "open failed: \(alert.message)") }
            if Date() > deadline { finish(1, "timed out opening the file") }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let editor else { finish(1, "no editor") }
        await editor.load()
        if let error = editor.loadError { finish(1, "load failed: \(error)") }
        FileHandle.standardError.write(Data("VidRip self-test: loaded \(editor.duration)s \(Int(editor.videoSize.width))x\(Int(editor.videoSize.height)) @ \(editor.frameRate) fps\n".utf8))

        editor.setSelection(start: 1, end: 2.5)
        editor.seek(to: 1.5)
        editor.cropEnabled = true
        editor.cropAspect = .square
        editor.exportFormat = output.pathExtension.lowercased() == "mov" ? .prores : .mp4
        editor.destination = output.deletingLastPathComponent()
        editor.fileName = output.deletingPathExtension().lastPathComponent
        editor.includeRangeInName = false
        editor.export()

        while editor.isExporting {
            if Date() > deadline { finish(1, "timed out exporting") }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        switch editor.exportState {
        case .done(let url): finish(0, "exported \(url.path)")
        case .failed(let message): finish(1, "export failed: \(message)")
        default: finish(1, "export did not finish")
        }
    }

    var isWorking: Bool {
        if case .working = activity { return true }
        return false
    }

    // MARK: Fetching

    func fetch() {
        let link = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        guard let url = URL(string: link), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            alert = AlertInfo(title: "That isn't a web link", message: "Paste the full address of a YouTube video, for example https://www.youtube.com/watch?v=…")
            return
        }
        let quality = quality
        let cookies = cookies
        start { report in
            let download = try await Downloader.download(url: link, quality: quality, cookies: cookies, onStatus: report)
            let file = try await MediaPrep.makeEditable(download.fileURL, cacheKey: download.cacheKey, onStatus: report)
            return Clip(fileURL: file, title: download.title)
        }
    }

    func openLocalFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video file to clip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLocalFile(url)
    }

    func openLocalFile(_ url: URL) {
        start { report in
            report("Opening \(url.lastPathComponent)…", nil)
            let file = try await MediaPrep.makeEditable(url, cacheKey: nil, onStatus: report)
            return Clip(fileURL: file, title: url.deletingPathExtension().lastPathComponent)
        }
    }

    /// Runs a fetch/open job, showing progress and opening the result in the editor.
    private func start(_ work: @escaping (@escaping @Sendable (String, Double?) -> Void) async throws -> Clip) {
        job?.cancel()
        let id = UUID()
        jobID = id
        activity = .working("Starting…", nil)

        let report: @Sendable (String, Double?) -> Void = { [weak self] message, fraction in
            Task { @MainActor in
                guard let self, self.jobID == id, self.isWorking else { return }
                self.activity = .working(message, fraction)
            }
        }

        job = Task {
            await toolsReady.value
            do {
                let clip = try await work(report)
                try Task.checkCancellation()
                open(clip)
            } catch is CancellationError {
                // Cancelled by the user.
            } catch {
                if jobID == id {
                    alert = AlertInfo(title: "Couldn't get that video", message: error.localizedDescription)
                }
            }
            if jobID == id {
                activity = .idle
                job = nil
            }
        }
    }

    func cancel() {
        job?.cancel()
        job = nil
        jobID = UUID()
        activity = .idle
    }

    private func open(_ clip: Clip) {
        editor?.teardown()
        let newEditor = EditorModel(clip: clip)
        editor = newEditor
        UIProbe.shared.editor = newEditor
    }

    func closeEditor() {
        editor?.teardown()
        editor = nil
    }

    // MARK: Tools menu

    func updateYtDlp() {
        guard !isWorking else { return }
        activity = .working("Updating the YouTube downloader…", nil)
        Task {
            await toolsReady.value
            do {
                let message = try await Downloader.updateYtDlp()
                alert = AlertInfo(title: "YouTube downloader", message: message)
            } catch {
                alert = AlertInfo(title: "Update failed", message: error.localizedDescription)
            }
            activity = .idle
        }
    }

    func revealCache() {
        let directory = Downloader.cacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func clearCache() {
        let keep = editor?.clip.fileURL.standardizedFileURL
        let files = (try? FileManager.default.contentsOfDirectory(at: Downloader.cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for file in files where file.standardizedFileURL != keep {
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        alert = AlertInfo(title: "Downloads cache cleared", message: removed == 1 ? "Removed 1 file." : "Removed \(removed) files.")
    }

    /// Handles a link or file dropped onto the window.
    func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        if url.isFileURL {
            openLocalFile(url)
        } else {
            urlText = url.absoluteString
            fetch()
        }
        return true
    }
}
