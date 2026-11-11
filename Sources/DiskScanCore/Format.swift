import Foundation

public enum Format {
    /// Formats bytes in macOS Finder standard (decimal, 1000-based)
    public static func formatBytes(_ bytes: Int64, useBinary: Bool = false) -> String {
        if bytes == 0 { return "0 B" }
        let sign = bytes < 0 ? "-" : ""
        let absBytes = Double(abs(bytes))
        
        let unit: Double = useBinary ? 1024.0 : 1000.0
        let suffixes = useBinary
            ? ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
            : ["B", "KB", "MB", "GB", "TB", "PB"]
        
        var index = 0
        var value = absBytes
        while value >= unit && index < suffixes.count - 1 {
            value /= unit
            index += 1
        }
        
        if index == 0 {
            return "\(sign)\(Int64(value)) \(suffixes[index])"
        } else if value >= 100 {
            return String(format: "%@%.0f %@", sign, value, suffixes[index])
        } else if value >= 10 {
            return String(format: "%@%.1f %@", sign, value, suffixes[index])
        } else {
            return String(format: "%@%.2f %@", sign, value, suffixes[index])
        }
    }
    
    /// Formats a percentage between 0.0 and 1.0 (e.g. 74.2%)
    public static func formatPercent(_ fraction: Double) -> String {
        let clamped = max(0.0, min(1.0, fraction))
        return String(format: "%.1f%%", clamped * 100.0)
    }
    
    /// Generates an ASCII / Unicode progress bar of given width
    public static func makeProgressBar(fraction: Double, width: Int) -> String {
        guard width > 0 else { return "" }
        let clamped = max(0.0, min(1.0, fraction))
        let filledCount = Int(round(clamped * Double(width)))
        let emptyCount = max(0, width - filledCount)
        return String(repeating: "█", count: filledCount) + String(repeating: "░", count: emptyCount)
    }
    
    /// Formats a count with thousands separators (e.g. 1,234,567)
    public static func formatCount(_ count: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
    
    /// Formats duration in human readable string (e.g. "1.24s" or "3m 12s")
    public static func formatDuration(_ seconds: Double) -> String {
        if seconds < 1.0 {
            return String(format: "%.0f ms", seconds * 1000.0)
        } else if seconds < 60.0 {
            return String(format: "%.2f s", seconds)
        } else {
            let mins = Int(seconds) / 60
            let remSecs = seconds - Double(mins * 60)
            return String(format: "%dm %.1fs", mins, remSecs)
        }
    }
}
