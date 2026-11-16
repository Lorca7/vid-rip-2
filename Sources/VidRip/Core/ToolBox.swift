import Foundation
import Darwin

/// The command-line tools VidRip ships inside its app bundle.
enum Tool: String, CaseIterable {
    case ytdlp = "yt-dlp"
    case ffmpeg = "ffmpeg"
    case deno = "deno"   // JavaScript runtime yt-dlp needs to read YouTube's player

    var displayName: String {
        switch self {
        case .ytdlp: "yt-dlp"
        case .ffmpeg: "ffmpeg"
        case .deno: "Deno"
        }
    }
}

enum ToolError: LocalizedError {
    case missing(Tool)

    var errorDescription: String? {
        switch self {
        case .missing(let tool):
            "\(tool.displayName) could not be found. Reinstall VidRip, or install it with Homebrew (brew install \(tool.rawValue))."
        }
    }
}

/// Finds the bundled tools and keeps a working copy of them in
/// ~/Library/Application Support/VidRip/bin.
///
/// Running from a copy (rather than from inside the .app) lets yt-dlp update itself
/// (YouTube changes often), and lets us clear the download quarantine flag that macOS
/// puts on files from the internet.
final class ToolBox: @unchecked Sendable {
    static let shared = ToolBox()

    let supportBin: URL
    let bundledBin: URL?
    private let fileManager = FileManager.default

    private init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VidRip", isDirectory: true)
        supportBin = support.appendingPathComponent("bin", isDirectory: true)

        if let resources = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true),
           FileManager.default.fileExists(atPath: resources.path) {
            bundledBin = resources
        } else {
            bundledBin = nil
        }
    }

    /// Copies bundled tools into Application Support the first time a given app build runs.
    func prepare() {
        try? fileManager.createDirectory(at: supportBin, withIntermediateDirectories: true)
        guard let bundledBin else { return }

        let info = Bundle.main.infoDictionary
        let stampValue = "\(info?["CFBundleShortVersionString"] as? String ?? "0")-\(info?["CFBundleVersion"] as? String ?? "0")"
        let stampURL = supportBin.appendingPathComponent(".bundle-version")
        let previous = try? String(contentsOf: stampURL, encoding: .utf8)
        let isNewBuild = previous != stampValue

        for tool in Tool.allCases {
            let source = bundledBin.appendingPathComponent(tool.rawValue)
            let destination = supportBin.appendingPathComponent(tool.rawValue)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            if isNewBuild || !fileManager.isExecutableFile(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
                try? fileManager.copyItem(at: source, to: destination)
            }
            makeRunnable(destination)
        }
        try? stampValue.write(to: stampURL, atomically: true, encoding: .utf8)
    }

    private func makeRunnable(_ url: URL) {
        removexattr(url.path, "com.apple.quarantine", 0)
        chmod(url.path, 0o755)
    }

    /// Where to look for a tool, most preferred first.
    private func candidates(for tool: Tool) -> [URL] {
        var list = [supportBin.appendingPathComponent(tool.rawValue)]
        if let bundledBin { list.append(bundledBin.appendingPathComponent(tool.rawValue)) }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            list.append(URL(fileURLWithPath: dir).appendingPathComponent(tool.rawValue))
        }
        return list
    }

    func path(for tool: Tool) -> URL? {
        candidates(for: tool).first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    func require(_ tool: Tool) throws -> URL {
        guard let url = path(for: tool) else { throw ToolError.missing(tool) }
        return url
    }

    /// The working copy of yt-dlp, which can update itself.
    var updatableYtDlp: URL? {
        let url = supportBin.appendingPathComponent(Tool.ytdlp.rawValue)
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Environment for child processes: our tools come first on PATH so yt-dlp finds
    /// ffmpeg and Deno without extra configuration.
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        var paths = [supportBin.path]
        if let bundledBin { paths.append(bundledBin.path) }
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = paths.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }
}
