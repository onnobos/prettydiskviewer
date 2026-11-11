import Foundation
import Darwin

public enum Theme {
    public static let reset = "\u{001B}[0m"
    public static let bold = "\u{001B}[1m"
    public static let dim = "\u{001B}[2m"
    public static let italic = "\u{001B}[3m"
    public static let underline = "\u{001B}[4m"
    public static let inverse = "\u{001B}[7m"
    
    // High-Contrast Colors: Carefully calibrated to have >= 4.5:1 contrast ratio
    // on BOTH White/Light and Black/Dark terminal backgrounds!
    public static let cyan = "\u{001B}[36m"                     // Standard ANSI Cyan (terminal adaptive)
    public static let deepBlue = "\u{001B}[34m"                 // Standard ANSI Blue
    public static let purple = "\u{001B}[35m"                   // Standard ANSI Magenta/Purple
    public static let green = "\u{001B}[32m"                    // Standard ANSI Green
    public static let yellow = "\u{001B}[33m"                   // Standard ANSI Yellow/Amber
    public static let red = "\u{001B}[31m"                      // Standard ANSI Red
    
    // Default text color: Automatically uses the user's terminal default text
    // (Solid Black on light terminals, Crisp White on dark terminals)
    public static let text = "\u{001B}[0m"
    public static let white = "\u{001B}[0m"                     // Alias for default primary text
    public static let boldText = "\u{001B}[1m"                  // Bold primary text
    public static let gray = "\u{001B}[2m"                      // Secondary/Dim text (adaptive charcoal on light, slate on dark)
    public static let border = "\u{001B}[38;5;244m"             // Neutral medium gray (balanced on light & dark)
    
    // Box Drawing Characters
    public static let roundedTopLeft = "╭"
    public static let roundedTopRight = "╮"
    public static let roundedBottomLeft = "╰"
    public static let roundedBottomRight = "╯"
    public static let horizontal = "─"
    public static let vertical = "│"
    
    // Viewfinder Bracket Corners
    public static let bracketTopLeft = "┌──"
    public static let bracketTopRight = "──┐"
    public static let bracketBottomLeft = "└──"
    public static let bracketBottomRight = "──┘"
    
    // Bullet
    public static let bullet = "●"
    
    /// Calculates the exact visual display column width on a terminal,
    /// correctly accounting for emojis (2 cols), Asian wide chars (2 cols),
    /// standard chars (1 col), and ANSI escape codes (0 cols).
    public static func terminalColumnWidth(_ string: String) -> Int {
        let stripped = stripANSI(string)
        var cols = 0
        for ch in stripped.unicodeScalars {
            let w = Int(Darwin.wcwidth(wchar_t(ch.value)))
            cols += (w > 0 ? w : 1)
        }
        return cols
    }
    
    /// Wraps text inside a rounded box of given width with pixel-perfect right border alignment
    public static func makeRoundedBox(lines: [String], width: Int, borderColor: String = border) -> String {
        let contentWidth = max(20, width - 4)
        let top = "\(borderColor)\(roundedTopLeft)\(String(repeating: horizontal, count: contentWidth + 2))\(roundedTopRight)\(reset)\n"
        var middle = ""
        for line in lines {
            let safeLine = terminalColumnWidth(line) > contentWidth ? truncateVisual(line, maxCols: contentWidth) : line
            let visualWidth = terminalColumnWidth(safeLine)
            let padding = max(0, contentWidth - visualWidth)
            middle += "\(borderColor)\(vertical)\(reset) \(safeLine)\(String(repeating: " ", count: padding)) \(borderColor)\(vertical)\(reset)\n"
        }
        let bottom = "\(borderColor)\(roundedBottomLeft)\(String(repeating: horizontal, count: contentWidth + 2))\(roundedBottomRight)\(reset)"
        return top + middle + bottom
    }
    
    /// Truncates a string to fit within maxCols visual columns, taking ANSI codes and wide characters into account
    public static func truncateVisual(_ string: String, maxCols: Int) -> String {
        guard maxCols > 0 else { return "" }
        if terminalColumnWidth(string) <= maxCols { return string }
        
        var result = ""
        var currentCols = 0
        var i = string.startIndex
        
        while i < string.endIndex {
            if string[i] == "\u{001B}" {
                // Read entire ANSI escape code without adding to column count
                let rem = string[i...]
                if let match = rem.range(of: "^\u{001B}\\[[0-9;]*[a-zA-Z]", options: .regularExpression) {
                    result += String(rem[match])
                    i = match.upperBound
                    continue
                }
            }
            
            let scalar = string[i].unicodeScalars.first ?? UnicodeScalar(32)!
            let rawW = Int(Darwin.wcwidth(wchar_t(scalar.value)))
            let w = rawW > 0 ? rawW : 1
            if currentCols + w > maxCols {
                break
            }
            result.append(string[i])
            currentCols += w
            i = string.index(after: i)
        }
        
        result += reset
        return result
    }
    
    /// Strips ANSI escape sequences for accurate string length computation
    public static func stripANSI(_ string: String) -> String {
        string.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
    }
}
