import AVFoundation
import Foundation

/// Facts about a media file, as far as macOS's own media framework can read it.
struct MediaInfo {
    var readable = false
    var hasVideo = false
    var hasAudio = false
    var videoOK = false      // macOS can preview this video codec
    var audioOK = false      // macOS can play this audio codec
    var duration: Double = 0
    var height: CGFloat = 0
}

/// Makes sure a file can be previewed in the editor, converting it once if needed
/// (for example 4K YouTube videos, which only come as VP9 or AV1).
enum MediaPrep {
    private static func fourCC(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    private static var playableVideoCodecs: Set<FourCharCode> {
        [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, fourCC("hev1"), fourCC("avc3"),
         kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
         kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
         kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_MPEG4Video]
    }

    private static var playableAudioCodecs: Set<FourCharCode> {
        [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
         kAudioFormatMPEGLayer3, kAudioFormatAppleLossless, kAudioFormatLinearPCM]
    }

    static func inspect(_ url: URL) async -> MediaInfo {
        var info = MediaInfo()
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return info }
        info.readable = true
        info.duration = (try? await asset.load(.duration))?.seconds ?? 0

        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            info.hasVideo = true
            info.height = (try? await track.load(.naturalSize))?.height ?? 0
            if let description = (try? await track.load(.formatDescriptions))?.first {
                info.videoOK = playableVideoCodecs.contains(CMFormatDescriptionGetMediaSubType(description))
            }
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            info.hasAudio = true
            if let description = (try? await track.load(.formatDescriptions))?.first {
                info.audioOK = playableAudioCodecs.contains(CMFormatDescriptionGetMediaSubType(description))
            }
        }
        return info
    }

    static func isEditable(_ info: MediaInfo) -> Bool {
        info.readable && (info.hasVideo || info.hasAudio)
            && (!info.hasVideo || info.videoOK) && (!info.hasAudio || info.audioOK)
    }

    /// Returns a file the editor can preview: the original, or a converted copy in the cache.
    /// `cacheKey` lets a converted copy be reused next time (pass nil for one-off files).
    static func makeEditable(
        _ url: URL,
        cacheKey: String?,
        onStatus: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> URL {
        let info = await inspect(url)
        if isEditable(info) { return url }

        let directory = Downloader.cacheDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("\(cacheKey ?? UUID().uuidString)-edit.mp4")
        if FileManager.default.fileExists(atPath: output.path), isEditable(await inspect(output)) {
            return output
        }

        let ffmpeg = try ToolBox.shared.require(.ffmpeg)
        var probed = info.duration
        if probed <= 0 { probed = await probeDuration(url) }
        let duration = probed
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        // Copy whatever macOS can already play; convert the rest.
        let copyVideo = info.readable && info.hasVideo && info.videoOK
        let copyAudio = info.readable && info.hasAudio && info.audioOK
        let bitrate: String = switch info.height {
        case 2000...: "45M"
        case 1300...: "24M"
        case 1000...: "12M"
        default: "8M"
        }
        let audioArgs = copyAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "256k"]
        let encoders: [[String]] = copyVideo
            ? [["-c:v", "copy"]]
            : [
                // Hardware encoder first (fast), software encoder as a fallback.
                ["-c:v", "h264_videotoolbox", "-b:v", bitrate, "-profile:v", "high", "-pix_fmt", "yuv420p"],
                ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p"],
            ]

        var lastFailure = "Conversion failed."
        for videoArgs in encoders {
            try Task.checkCancellation()
            onStatus("Preparing video for editing…", 0)
            var arguments = ["-hide_banner", "-nostdin", "-y", "-i", url.path,
                             "-map", "0:v:0?", "-map", "0:a:0?"]
            arguments += videoArgs + audioArgs
            arguments += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", temp.path]

            let result = try await ProcessRunner.run(ffmpeg, arguments) { line in
                if let seconds = FFmpegProgress.seconds(from: line), duration > 0 {
                    let fraction = min(max(seconds / duration, 0), 1)
                    onStatus("Preparing video for editing… \(Int(fraction * 100))%", fraction)
                }
            }
            if result.succeeded {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: temp, to: output)
                return output
            }
            lastFailure = result.errorSummary
        }
        throw DownloadError.failed("This video couldn't be prepared for editing:\n\n\(lastFailure)")
    }

    /// Duration via ffmpeg, for files macOS can't open itself.
    private static func probeDuration(_ url: URL) async -> Double {
        guard let ffmpeg = ToolBox.shared.path(for: .ffmpeg),
              let result = try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", url.path]) else { return 0 }
        for line in result.lines {
            guard let value = line.trimmingCharacters(in: .whitespaces).value(after: "Duration: ") else { continue }
            let stamp = value.prefix { $0 != "," }
            if let seconds = TimeFormat.parse(String(stamp)) { return seconds }
        }
        return 0
    }
}

enum FFmpegProgress {
    /// Parses `out_time_us=` / `out_time_ms=` lines from `ffmpeg -progress` (both are microseconds).
    static func seconds(from line: String) -> Double? {
        for key in ["out_time_us=", "out_time_ms="] {
            if let value = line.value(after: key), let micro = Double(value) {
                return micro / 1_000_000
            }
        }
        return nil
    }
}
