import Foundation

enum TimeFormat {
    /// `MM:SS.mmm`, or `H:MM:SS.mmm` for an hour or longer.
    static func long(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        let totalMillis = Int((value * 1000).rounded())
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d.%03d", h, m, s, millis)
        }
        return String(format: "%02d:%02d.%03d", m, s, millis)
    }

    /// Short ruler label; shows tenths only when ticks are closer than a second.
    static func ruler(_ seconds: Double, step: Double) -> String {
        let totalSeconds = Int(seconds.rounded(.down))
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        var text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if step < 1 {
            let tenths = Int(((seconds - Double(totalSeconds)) * 10).rounded()) % 10
            text += ".\(tenths)"
        }
        return text
    }

    /// For file names, e.g. `01m23s` or `1h02m03s`.
    static func fileStamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        return h > 0 ? String(format: "%dh%02dm%02ds", h, m, s) : String(format: "%02dm%02ds", m, s)
    }

    /// Accepts `SS`, `SS.mmm`, `MM:SS(.mmm)` or `H:MM:SS(.mmm)`.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
