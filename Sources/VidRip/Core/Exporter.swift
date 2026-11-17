import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4
    case prores
    case wav

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp4: "MP4 · H.264 + AAC (works everywhere)"
        case .prores: "MOV · Apple ProRes 422 (pro editing, large files)"
        case .wav: "WAV · audio only"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp4: "mp4"
        case .prores: "mov"
        case .wav: "wav"
        }
    }

    var hasVideo: Bool { self != .wav }
}

struct ExportJob {
    let input: URL
    let start: Double
    let end: Double
    /// Crop rectangle in video pixels, or nil for the full frame.
    let crop: CGRect?
    let format: ExportFormat
    let output: URL
    /// Full picture size and frame rate of the source, used to pick a bit rate.
    let videoSize: CGSize
    let frameRate: Double
}

enum ExportError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

/// Cuts the selected range (and optional crop) with ffmpeg, re-encoding so the cut is
/// frame-accurate and the file opens cleanly in Final Cut Pro, Premiere Pro,
/// DaVinci Resolve, iMovie, CapCut and others.
enum Exporter {
    /// Exports the clip and returns the name of the encoder that was used.
    @discardableResult
    static func export(_ job: ExportJob, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let ffmpeg = try ToolBox.shared.require(.ffmpeg)
        let duration = max(job.end - job.start, 0.01)

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VidRip-\(UUID().uuidString).\(job.format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }

        func input(hardwareDecode: Bool) -> [String] {
            var arguments = ["-hide_banner", "-nostdin", "-y"]
            // Decode with the Mac's media engine too (ffmpeg uses software for codecs it can't handle).
            if hardwareDecode { arguments += ["-hwaccel", "videotoolbox"] }
            return arguments + ["-ss", seconds(job.start), "-i", job.input.path, "-t", seconds(duration)]
        }

        var mapping: [String] = []
        switch job.format {
        case .wav:
            mapping += ["-map", "0:a:0", "-vn"]
        case .mp4, .prores:
            mapping += ["-map", "0:v:0?", "-map", "0:a:0?"]
            if let crop = job.crop {
                let rect = crop.evenPixels
                mapping += ["-vf", "crop=\(Int(rect.width)):\(Int(rect.height)):\(Int(rect.minX)):\(Int(rect.minY))"]
            }
            mapping += ["-fps_mode", "cfr"]   // editors prefer constant frame rate
        }

        // Encoders to try in order. The hardware (VideoToolbox) encoders run on the Mac's
        // dedicated media engine and barely touch the CPU; the software encoders are a
        // fallback for Macs or files the hardware can't handle.
        let encoders: [Encoder]
        switch job.format {
        case .mp4:
            let audio = ["-c:a", "aac", "-b:a", "320k", "-ar", "48000", "-movflags", "+faststart"]
            encoders = [
                Encoder(name: "hardware H.264",
                        arguments: ["-c:v", "h264_videotoolbox", "-b:v", h264Bitrate(for: job),
                                    "-profile:v", "high", "-pix_fmt", "yuv420p"] + audio),
                Encoder(name: "software H.264",
                        arguments: ["-c:v", "libx264", "-preset", "fast", "-crf", "17",
                                    "-profile:v", "high", "-pix_fmt", "yuv420p"] + audio),
            ]
        case .prores:
            let audio = ["-c:a", "pcm_s16le", "-ar", "48000"]
            encoders = [
                Encoder(name: "hardware ProRes",
                        arguments: ["-c:v", "prores_videotoolbox", "-profile:v", "standard"] + audio),
                Encoder(name: "software ProRes",
                        arguments: ["-c:v", "prores_ks", "-profile:v", "2", "-vendor", "apl0",
                                    "-pix_fmt", "yuv422p10le"] + audio),
            ]
        case .wav:
            encoders = [Encoder(name: "WAV", arguments: ["-c:a", "pcm_s16le", "-ar", "48000"])]
        }

        var lastFailure = ""
        var usedEncoder: String?
        for encoder in encoders {
            try Task.checkCancellation()
            progress(0)
            let arguments = input(hardwareDecode: encoder.hardware) + mapping + encoder.arguments + ["-progress", "pipe:1", "-nostats", temp.path]
            // Background priority keeps the Mac responsive (and cooler) while exporting.
            let result = try await ProcessRunner.run(ffmpeg, arguments, qualityOfService: .utility) { line in
                if let done = FFmpegProgress.seconds(from: line) {
                    progress(min(max(done / duration, 0), 1))
                }
            }
            if result.succeeded {
                usedEncoder = encoder.name
                break
            }
            lastFailure = result.errorSummary
        }
        guard let usedEncoder else {
            throw ExportError.failed("Export failed:\n\n\(lastFailure)")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: job.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: job.output.path) {
            try fileManager.removeItem(at: job.output)
        }
        try fileManager.moveItem(at: temp, to: job.output)
        progress(1)
        return usedEncoder
    }

    private struct Encoder {
        let name: String
        let arguments: [String]
        var hardware: Bool { name.hasPrefix("hardware") }
    }

    /// A generous bit rate for editing: about 0.25 bits per pixel per frame
    /// (≈16 Mbit/s for 1080p30, ≈60 Mbit/s for 4K30).
    private static func h264Bitrate(for job: ExportJob) -> String {
        let size = job.crop?.evenPixels.size ?? job.videoSize
        let fps = job.frameRate > 1 ? job.frameRate : 30
        let bitsPerSecond = Double(size.width * size.height) * fps * 0.25
        let megabits = min(max(bitsPerSecond / 1_000_000, 6), 120)
        return "\(Int(megabits.rounded()))M"
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// `base.ext`, or `base 2.ext`, `base 3.ext`… if that name is taken.
    static func uniqueURL(in folder: URL, baseName: String, fileExtension: String) -> URL {
        var candidate = folder.appendingPathComponent("\(baseName).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(counter).\(fileExtension)")
            counter += 1
        }
        return candidate
    }

    /// Makes a title safe to use as a file name.
    static func sanitize(_ name: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = name.unicodeScalars.map { banned.contains($0) ? "-" : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        var result = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        if result.count > 90 { result = String(result.prefix(90)).trimmingCharacters(in: .whitespaces) }
        return result.isEmpty ? "Clip" : result
    }
}

extension CGRect {
    /// Rounds to whole, even pixel values (most codecs need even dimensions).
    var evenPixels: CGRect {
        func even(_ v: CGFloat) -> CGFloat { CGFloat(Int(v.rounded(.down)) / 2 * 2) }
        let w = max(even(width), 2)
        let h = max(even(height), 2)
        return CGRect(x: even(minX), y: even(minY), width: w, height: h)
    }
}
