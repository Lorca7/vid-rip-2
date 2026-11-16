import Foundation

enum VideoQuality: Int, CaseIterable, Identifiable {
    case p720 = 720
    case p1080 = 1080
    case p1440 = 1440
    case p2160 = 2160

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p HD"
        case .p1440: "1440p 2K"
        case .p2160: "2160p 4K"
        }
    }
}

/// Browser whose YouTube sign-in yt-dlp may borrow when YouTube asks "are you a bot?".
enum CookieSource: String, CaseIterable, Identifiable {
    case none, safari, chrome, firefox, edge, brave

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "No browser cookies"
        case .safari: "Cookies from Safari"
        case .chrome: "Cookies from Chrome"
        case .firefox: "Cookies from Firefox"
        case .edge: "Cookies from Edge"
        case .brave: "Cookies from Brave"
        }
    }
}

struct DownloadResult {
    let fileURL: URL
    let title: String
    let cacheKey: String
}

enum DownloadError: LocalizedError {
    case failed(String)
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .fileNotFound: "The download finished but the video file could not be found."
        }
    }
}

/// Mutable state shared with yt-dlp's output callback.
private final class DownloadState: @unchecked Sendable {
    private let lock = NSLock()
    private var _title: String?
    private var _id: String?
    private var _file: String?
    private var _lastPercent: Double = 0
    private var _part = 0

    func set(title: String) { lock.lock(); _title = title; lock.unlock() }
    func set(id: String) { lock.lock(); _id = id; lock.unlock() }
    func set(file: String) { lock.lock(); _file = file; lock.unlock() }

    /// Records a percentage and returns which stream (0 = video, 1 = audio, ...) is downloading.
    func record(percent: Double) -> Int {
        lock.lock(); defer { lock.unlock() }
        if percent + 40 < _lastPercent { _part += 1 }
        _lastPercent = percent
        return _part
    }

    var snapshot: (title: String?, id: String?, file: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_title, _id, _file)
    }
}

enum Downloader {
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VidRip", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Downloads one video (with audio) into the cache directory using yt-dlp.
    /// `onStatus` receives a description and a 0...1 fraction (nil when unknown).
    static func download(
        url: String,
        quality: VideoQuality,
        cookies: CookieSource,
        onStatus: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> DownloadResult {
        let ytdlp = try ToolBox.shared.require(.ytdlp)
        let ffmpeg = try ToolBox.shared.require(.ffmpeg)
        let directory = cacheDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let suffix = "\(quality.rawValue)p"
        var arguments = [
            "--no-playlist", "--playlist-items", "1",
            "--no-simulate", "--progress", "--newline", "--no-mtime",
            "--progress-template", "download:VRPROG %(progress._percent_str)s",
            "--print", "before_dl:VRTITLE %(title)s",
            "--print", "before_dl:VRID %(id)s",
            "--print", "after_move:VRFILE %(filepath)s",
            // Prefer standard-dynamic-range H.264 + AAC, which every editor (and the
            // preview player) handles natively. Fall back to whatever is best.
            "-f", "bv*[dynamic_range=SDR]+ba/bv*+ba/b",
            "-S", "res:\(quality.rawValue),vcodec:h264,acodec:m4a",
            "--merge-output-format", "mp4",
            "--ffmpeg-location", ffmpeg.path,
            "-P", directory.path,
            "-o", "%(id)s-\(suffix).%(ext)s",
        ]
        if cookies != .none {
            arguments += ["--cookies-from-browser", cookies.rawValue]
        }
        arguments += ["--", url]

        let state = DownloadState()
        onStatus("Contacting YouTube…", nil)

        let result = try await ProcessRunner.run(ytdlp, arguments) { line in
            if let value = line.value(after: "VRTITLE ") {
                state.set(title: value)
                onStatus("Found “\(value)”", nil)
            } else if let value = line.value(after: "VRID ") {
                state.set(id: value)
            } else if let value = line.value(after: "VRFILE ") {
                state.set(file: value)
            } else if let value = line.value(after: "VRPROG ") {
                let digits = value.filter { $0.isNumber || $0 == "." }
                if let percent = Double(digits) {
                    let part = state.record(percent: percent)
                    let what = part == 0 ? "Downloading video" : "Downloading audio"
                    onStatus("\(what)… \(Int(percent))%", min(max(percent / 100, 0), 1))
                }
            } else if line.contains("[Merger]") || line.contains("[VideoConvertor]") || line.contains("[VideoRemuxer]") {
                onStatus("Combining audio and video…", nil)
            }
        }

        guard result.succeeded else {
            throw DownloadError.failed(friendlyMessage(for: result))
        }

        let info = state.snapshot
        let title = info.title ?? "YouTube clip"
        if let file = info.file, FileManager.default.fileExists(atPath: file) {
            let url = URL(fileURLWithPath: file)
            return DownloadResult(fileURL: url, title: title, cacheKey: url.deletingPathExtension().lastPathComponent)
        }
        // Already-downloaded videos may not report a path; look in the cache.
        if let id = info.id {
            let prefix = "\(id)-\(suffix)."
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            if let match = files.first(where: {
                let name = $0.lastPathComponent
                return name.hasPrefix(prefix) && !name.hasSuffix(".part") && !name.hasSuffix(".ytdl") && !name.contains(".temp.")
            }) {
                return DownloadResult(fileURL: match, title: title, cacheKey: "\(id)-\(suffix)")
            }
        }
        throw DownloadError.fileNotFound
    }

    private static func friendlyMessage(for result: ProcessResult) -> String {
        let all = result.lines.joined(separator: "\n")
        if all.contains("Sign in to confirm") || all.contains("not a bot") {
            return "YouTube asked to confirm you're not a bot.\n\nChoose a browser in the cookies menu (one where you're signed in to YouTube) and try again. If it keeps happening, use Tools ▸ Update YouTube Downloader."
        }
        if all.contains("Unsupported URL") || all.contains("is not a valid URL") {
            return "That doesn't look like a video link VidRip can read. Copy the address from the YouTube page and paste it again."
        }
        if all.contains("Private video") {
            return "This video is private."
        }
        if all.contains("confirm your age") || all.contains("age-restricted") {
            return "This video is age-restricted. Choose a browser in the cookies menu (one where you're signed in to YouTube) and try again."
        }
        if all.contains("Operation not permitted") && all.localizedCaseInsensitiveContains("cookies") {
            return "macOS blocked access to the browser's cookies. For Safari, allow VidRip in System Settings ▸ Privacy & Security ▸ Full Disk Access, or pick a different browser."
        }
        return "The download failed:\n\n\(result.errorSummary)\n\nIf YouTube links stopped working, try Tools ▸ Update YouTube Downloader."
    }

    /// Updates the working copy of yt-dlp to the newest release.
    static func updateYtDlp() async throws -> String {
        guard let ytdlp = ToolBox.shared.updatableYtDlp else {
            throw DownloadError.failed("VidRip's built-in copy of yt-dlp was not found, so it can't be updated. If you installed yt-dlp with Homebrew, run: brew upgrade yt-dlp")
        }
        let result = try await ProcessRunner.run(ytdlp, ["-U"])
        let text = result.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(4).joined(separator: "\n")
        guard result.succeeded else { throw DownloadError.failed(text.isEmpty ? result.errorSummary : text) }
        return text.isEmpty ? "yt-dlp is up to date." : text
    }
}

extension String {
    /// If the string starts with `prefix`, returns the remainder.
    func value(after prefix: String) -> String? {
        guard let range = range(of: prefix), range.lowerBound == startIndex else { return nil }
        return String(self[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}
