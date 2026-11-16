import AppKit
import AVFoundation
import Combine
import Foundation

enum CropAspect: String, CaseIterable, Identifiable {
    case free, wide, vertical, square, portrait, classic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: "Free"
        case .wide: "16:9"
        case .vertical: "9:16"
        case .square: "1:1"
        case .portrait: "4:5"
        case .classic: "4:3"
        }
    }

    /// Width divided by height, or nil for free-form.
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .wide: 16.0 / 9.0
        case .vertical: 9.0 / 16.0
        case .square: 1
        case .portrait: 4.0 / 5.0
        case .classic: 4.0 / 3.0
        }
    }
}

/// State for one open clip: playback, the selection window, the crop window and export.
@MainActor
final class EditorModel: ObservableObject {
    enum ExportState: Equatable {
        case idle
        case running(Double)
        case done(URL)
        case failed(String)
    }

    let clip: Clip
    let player: AVPlayer

    @Published private(set) var isReady = false
    @Published private(set) var loadError: String?
    @Published private(set) var duration: Double = 0
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var frameRate: Double = 30
    @Published private(set) var hasVideo = true
    @Published private(set) var thumbnails: [CGImage] = []

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var loopSelection = true

    // The selection window on the timeline.
    @Published private(set) var inPoint: Double = 0
    @Published private(set) var outPoint: Double = 0

    // The crop window on the video.
    @Published var cropEnabled = false
    @Published var cropRect: CGRect = .zero
    @Published var cropAspect: CropAspect = .free {
        didSet { if cropAspect != oldValue { fitCropToAspect() } }
    }

    // Export settings.
    @Published var exportFormat: ExportFormat = .mp4
    @Published var fileName: String
    @Published var includeRangeInName = true
    @Published var destination: URL
    @Published private(set) var exportState: ExportState = .idle

    private var timeObserver: Any?
    private var statusSubscription: AnyCancellable?
    private var playingSelection = false
    private var exportTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?

    let thumbnailCount = 48

    init(clip: Clip) {
        self.clip = clip
        self.player = AVPlayer(url: clip.fileURL)
        self.player.actionAtItemEnd = .pause
        self.fileName = Exporter.sanitize(clip.title)
        self.destination = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    var minimumSelection: Double { max(0.1, 2 / frameRate) }
    var selectionLength: Double { outPoint - inPoint }
    var isExporting: Bool {
        if case .running = exportState { return true }
        return false
    }

    // MARK: Loading

    func load() async {
        guard !isReady else { return }
        let asset = AVURLAsset(url: clip.fileURL)
        do {
            let length = try await asset.load(.duration).seconds
            duration = length.isFinite ? max(length, 0) : 0
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let shown = CGRect(origin: .zero, size: size).applying(transform)
                videoSize = CGSize(width: abs(shown.width), height: abs(shown.height))
                if fps > 1 { frameRate = Double(fps) }
            } else {
                hasVideo = false
            }
        } catch {
            loadError = error.localizedDescription
        }

        guard duration > 0 else {
            loadError = loadError ?? "This file has no playable media."
            isReady = true
            return
        }

        // Start with the middle half selected so the window is easy to see and grab.
        inPoint = duration * 0.25
        outPoint = duration * 0.75
        if selectionLength < minimumSelection {
            inPoint = 0
            outPoint = duration
        }
        resetCrop()
        installObservers()
        seek(to: inPoint)
        isReady = true

        if hasVideo {
            thumbnailTask = Task { [weak self] in await self?.makeThumbnails(asset) }
        }
    }

    private func makeThumbnails(_ asset: AVURLAsset) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let spacing = duration / Double(thumbnailCount)
        generator.requestedTimeToleranceBefore = CMTime(seconds: spacing / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: spacing / 2, preferredTimescale: 600)

        var images: [CGImage] = []
        for index in 0..<thumbnailCount {
            if Task.isCancelled { return }
            let time = CMTime(seconds: spacing * (Double(index) + 0.5), preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            images.append(image)
            if index % 6 == 5 || index == thumbnailCount - 1 { thumbnails = images }
        }
        thumbnails = images
    }

    private func installObservers() {
        let interval = CMTime(value: 1, timescale: 60)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time.seconds)
            }
        }
        statusSubscription = player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    self?.isPlaying = status != .paused
                }
            }
    }

    func teardown() {
        exportTask?.cancel()
        thumbnailTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusSubscription = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Playback

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if playingSelection && isPlaying && seconds >= outPoint {
            if loopSelection {
                seek(to: inPoint)
            } else {
                player.pause()
                playingSelection = false
                seek(to: outPoint)
            }
        }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            return
        }
        playingSelection = false
        if currentTime >= duration - 0.05 { seek(to: 0) }
        player.play()
    }

    /// Plays from the start of the selection to its end (looping if Loop is on).
    func playSelection() {
        playingSelection = true
        seek(to: inPoint)
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), duration)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        player.pause()
        seek(to: currentTime + Double(frames) / frameRate)
    }

    func step(seconds: Double) {
        player.pause()
        seek(to: currentTime + seconds)
    }

    // MARK: Selection window

    /// Moves and/or resizes the selection, keeping it inside the video and at least
    /// `minimumSelection` long.
    func setSelection(start: Double, end: Double) {
        let minLength = min(minimumSelection, duration)
        var newStart = min(max(start, 0), duration)
        var newEnd = min(max(end, 0), duration)
        if newEnd - newStart < minLength {
            if newStart + minLength <= duration {
                newEnd = newStart + minLength
            } else {
                newEnd = duration
                newStart = duration - minLength
            }
        }
        inPoint = newStart
        outPoint = newEnd
    }

    @discardableResult
    func setIn(_ seconds: Double) -> Double {
        let value = min(max(seconds, 0), duration)
        if value > outPoint - minimumSelection {
            // Keep the current length if the new start would pass the end.
            let length = max(selectionLength, minimumSelection)
            setSelection(start: value, end: value + length)
        } else {
            setSelection(start: value, end: outPoint)
        }
        return inPoint
    }

    @discardableResult
    func setOut(_ seconds: Double) -> Double {
        let value = min(max(seconds, 0), duration)
        if value < inPoint + minimumSelection {
            let length = max(selectionLength, minimumSelection)
            setSelection(start: value - length, end: value)
        } else {
            setSelection(start: inPoint, end: value)
        }
        return outPoint
    }

    func markIn() { setIn(currentTime) }
    func markOut() { setOut(currentTime) }

    func selectAll() {
        setSelection(start: 0, end: duration)
    }

    // MARK: Crop window

    var cropBounds: CGRect { CGRect(origin: .zero, size: videoSize) }

    func resetCrop() {
        if let ratio = cropAspect.ratio {
            cropRect = largestRect(ratio: ratio, centeredAt: CGPoint(x: videoSize.width / 2, y: videoSize.height / 2))
        } else {
            cropRect = cropBounds
        }
    }

    private func fitCropToAspect() {
        guard let ratio = cropAspect.ratio else { return }
        let center = cropRect.isEmpty ? CGPoint(x: videoSize.width / 2, y: videoSize.height / 2)
                                      : CGPoint(x: cropRect.midX, y: cropRect.midY)
        cropRect = largestRect(ratio: ratio, centeredAt: center)
    }

    /// Largest rectangle with the given aspect ratio that fits in the video, as close to `center` as possible.
    private func largestRect(ratio: CGFloat, centeredAt center: CGPoint) -> CGRect {
        let bounds = cropBounds
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        var width = bounds.width
        var height = width / ratio
        if height > bounds.height {
            height = bounds.height
            width = height * ratio
        }
        let x = min(max(center.x - width / 2, 0), bounds.width - width)
        let y = min(max(center.y - height / 2, 0), bounds.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Export

    var suggestedFileName: String {
        let base = Exporter.sanitize(fileName)
        guard includeRangeInName else { return base }
        return "\(base) [\(TimeFormat.fileStamp(inPoint))-\(TimeFormat.fileStamp(outPoint))]"
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = "Save Here"
        panel.message = "Choose where exported clips are saved"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
        }
    }

    func export() {
        guard !isExporting, duration > 0 else { return }
        if !hasVideo && exportFormat.hasVideo {
            exportFormat = .wav
        }
        let format = exportFormat
        let output = Exporter.uniqueURL(in: destination, baseName: suggestedFileName, fileExtension: format.fileExtension)
        let crop: CGRect? = (cropEnabled && hasVideo && format.hasVideo && cropRect.size != videoSize) ? cropRect : nil
        let job = ExportJob(input: clip.fileURL, start: inPoint, end: outPoint, crop: crop, format: format, output: output)

        exportState = .running(0)
        exportTask = Task {
            do {
                try await Exporter.export(job) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.isExporting else { return }
                        self.exportState = .running(fraction)
                    }
                }
                exportState = .done(output)
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = .failed(error.localizedDescription)
            }
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func revealExport() {
        if case .done(let url) = exportState {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
