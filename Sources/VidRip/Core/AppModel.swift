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
        editor = EditorModel(clip: clip)
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
