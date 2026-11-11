import Foundation
import DiskScanCore

public enum Animations {
    public static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    
    public static func currentSpinner(elapsed: Double) -> String {
        let idx = Int(elapsed * 12.0) % spinnerFrames.count
        return spinnerFrames[idx]
    }
    
    /// Pixel art mascot in GitHub Copilot aesthetic (purple outer, cyan face, neon green eyes/accents)
    public static func renderPixelMascot(frame: Int = 0) -> [String] {
        let p = Theme.purple
        let c = Theme.cyan
        let g = Theme.green
        let r = Theme.reset
        
        switch frame % 4 {
        case 1: // Chomping mouth open
            return [
                "    \(p)▄██████▄\(r)    ",
                "  \(p)▄██\(c)██████\(p)██▄\(r)  ",
                " \(p)█▀\(c)██████████\(p)▀█\(r) ",
                "\(p)██\(c)███\(r)▀▀\(c)██\(r)▀▀\(c)███\(p)██\(r)",
                "\(p)██\(c)██\(r)  \(g)▌\(c)██\(g)▐\(r)  \(c)██\(p)██\(r)",
                "\(p)██\(c)███\(r)  ██  \(c)███\(p)██\(r)",
                " \(p)█▄\(p)██████████\(p)▄█\(r) ",
                "  \(p)▀██████████▀\(r)  "
            ]
        case 2: // Eyes blinking / smiling
            return [
                "    \(p)▄██████▄\(r)    ",
                "  \(p)▄██\(c)██████\(p)██▄\(r)  ",
                " \(p)█▀\(c)██████████\(p)▀█\(r) ",
                "\(p)██\(c)███\(g)▀▀\(c)██\(g)▀▀\(c)███\(p)██\(r)",
                "\(p)██\(c)████\(g)▌\(c)██\(g)▐\(c)████\(p)██\(r)",
                "\(p)██\(c)████\(c)▀▀\(c)████\(p)██\(r)",
                " \(p)█▄\(p)██████████\(p)▄█\(r) ",
                "  \(p)▀██████████▀\(r)  "
            ]
        case 3: // Happy wink
            return [
                "    \(p)▄██████▄\(r)    ",
                "  \(p)▄██\(c)██████\(p)██▄\(r)  ",
                " \(p)█▀\(c)██████████\(p)▀█\(r) ",
                "\(p)██\(c)███\(g)▀▀\(c)██\(r)──\(c)███\(p)██\(r)",
                "\(p)██\(c)████\(g)▌\(c)██\(g)▐\(c)████\(p)██\(r)",
                "\(p)██\(c)████\(g)▌\(c)██\(g)▐\(c)████\(p)██\(r)",
                " \(p)█▄\(p)██████████\(p)▄█\(r) ",
                "  \(p)▀██████████▀\(r)  "
            ]
        default: // Normal face
            return [
                "    \(p)▄██████▄\(r)    ",
                "  \(p)▄██\(c)██████\(p)██▄\(r)  ",
                " \(p)█▀\(c)██████████\(p)▀█\(r) ",
                "\(p)██\(c)███\(r)▀▀\(c)██\(r)▀▀\(c)███\(p)██\(r)",
                "\(p)██\(c)████\(g)▌\(c)██\(g)▐\(c)████\(p)██\(r)",
                "\(p)██\(c)████\(g)▌\(c)██\(g)▐\(c)████\(p)██\(r)",
                " \(p)█▄\(p)██████████\(p)▄█\(r) ",
                "  \(p)▀██████████▀\(r)  "
            ]
        }
    }
    
    /// 3D block typography for "DISK" matching GitHub Copilot CLI isometric font
    public static func disk3DLogo() -> [String] {
        let c = Theme.cyan
        let b = Theme.deepBlue
        let r = Theme.reset
        let bold = Theme.bold
        return [
            "\(bold)\(c)██████╗ ██╗███████╗██╗  ██╗\(r)",
            "\(bold)\(c)██╔══██╗██║██╔════╝██║ ██╔╝\(r)",
            "\(bold)\(c)██║  ██║██║███████╗█████╔╝ \(r)",
            "\(bold)\(c)██║  ██║██║╚════██║██╔═██╗ \(r)",
            "\(bold)\(c)██████╔╝██║███████║██║  ██╗\(r)",
            "\(bold)\(b)╚═════╝ ╚═╝╚══════╝╚═╝  ╚═╝\(r)",
            "             \(Theme.gray)CLI Version 1.0.0\(r)"
        ]
    }
    
    public static let funnyStatusLines = [
        "Sniffing out ancient downloads from 2021...",
        "Judging your 47 copies of node_modules...",
        "Searching behind the couch cushions for lost gigabytes...",
        "Checking if Xcode left 40 GB of DerivedData lying around...",
        "Munching through cache files (crunch crunch)...",
        "Asking the APFS filesystem where all the space went...",
        "Calculating how many cat videos this folder is worth...",
        "Hunting down hidden ISOs and forgotten DMGs...",
        "Polishing the APFS B-tree leaves...",
        "Negotiating with macOS System Data...",
        "Finding that 8 GB video you forgot you downloaded..."
    ]
    
    public static func currentJoke(elapsed: Double) -> String {
        let index = Int(elapsed / 1.8) % funnyStatusLines.count
        return funnyStatusLines[index]
    }
    
    public static func colorForFraction(_ fraction: Double) -> String {
        if fraction >= 0.90 {
            return Theme.green
        } else if fraction >= 0.50 {
            return Theme.cyan
        } else if fraction >= 0.20 {
            return Theme.yellow
        } else {
            return Theme.cyan
        }
    }
    
    /// Generates a modern gradient progress bar (e.g. [████████░░░░])
    public static func makeGradientBar(fraction: Double, width: Int) -> String {
        let clamped = max(0.0, min(1.0, fraction))
        let filledCount = Int(round(clamped * Double(width)))
        let emptyCount = max(0, width - filledCount)
        let color = colorForFraction(clamped)
        return "\(color)\(String(repeating: "█", count: filledCount))\(Theme.gray)\(String(repeating: "░", count: emptyCount))\(Theme.reset)"
    }
    
    /// Generates a smooth scanning activity pulse bar for folders when total size is unknown
    public static func makeActivityBar(elapsed: Double, width: Int) -> String {
        guard width > 6 else { return "\(Theme.cyan)████\(Theme.reset)" }
        let pulseWidth = max(3, width / 4)
        let maxTravel = width - pulseWidth
        let cycle = Int(elapsed * 14.0) % (maxTravel * 2)
        let pos = cycle < maxTravel ? cycle : (2 * maxTravel - cycle)
        let leading = max(0, pos)
        let trailing = max(0, width - pulseWidth - leading)
        return "\(Theme.gray)\(String(repeating: "░", count: leading))\(Theme.cyan)\(Theme.bold)\(String(repeating: "█", count: pulseWidth))\(Theme.reset)\(Theme.gray)\(String(repeating: "░", count: trailing))\(Theme.reset)"
    }
}
