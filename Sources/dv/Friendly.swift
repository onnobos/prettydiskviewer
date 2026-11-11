import Foundation
import DiskScanCore

public final class FriendlyInterface {
    private let terminal: Terminal
    
    public init(terminal: Terminal) {
        self.terminal = terminal
    }
    
    /// Presents the Copilot CLI style welcome screen with interactive target selection
    public func selectTargetInteractive() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let volumes = VolumeManager.listVolumes()
        let externalVolumes = volumes.filter { !$0.isInternal && !$0.isReadOnly }
        let mainVolume = volumes.first(where: { $0.mountPoint == "/" })
        
        var options: [(title: String, subtitle: String, path: String?)] = []
        options.append((
            title: "🏠 Home Directory",
            subtitle: home,
            path: home
        ))
        options.append((
            title: "💻 Entire Mac",
            subtitle: "/",
            path: "/"
        ))
        
        for ext in externalVolumes {
            options.append((
                title: "💾 \(ext.name)",
                subtitle: "\(Format.formatBytes(ext.freeBytes)) free",
                path: ext.mountPoint
            ))
        }
        
        options.append((
            title: "📁 Custom Folder Path",
            subtitle: "type or drag path",
            path: nil
        ))
        
        options.append((
            title: "❌ Quit",
            subtitle: "exit",
            path: "__QUIT__"
        ))
        
        terminal.enableRawMode()
        defer { terminal.disableRawMode() }
        
        var selectedIndex = 0
        var mascotFrame = 0
        
        while true {
            renderHeroScreen(
                options: options,
                selectedIndex: selectedIndex,
                mainVolume: mainVolume,
                mascotFrame: mascotFrame
            )
            mascotFrame += 1
            
            let key = terminal.readKey()
            switch key {
            case .up:
                selectedIndex = (selectedIndex - 1 + options.count) % options.count
            case .down:
                selectedIndex = (selectedIndex + 1) % options.count
            case .char(let c):
                if let num = Int(String(c)), num >= 1 && num <= options.count {
                    selectedIndex = num - 1
                    return handleSelection(options[selectedIndex])
                }
                if c == "q" {
                    return nil
                }
            case .enter, .space:
                return handleSelection(options[selectedIndex])
            case .escape, .ctrlC:
                return nil
            default:
                break
            }
        }
    }
    
    private func handleSelection(_ option: (title: String, subtitle: String, path: String?)) -> String? {
        if let path = option.path {
            if path == "__QUIT__" { return nil }
            return path
        }
        
        // Custom path input: temporarily disable raw mode so user can type/paste
        terminal.disableRawMode()
        print("\n\(Theme.cyan)\(Theme.bold)Enter or drag-and-drop a folder path:\(Theme.reset) ", terminator: "")
        fflush(stdout)
        
        guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            return nil
        }
        
        var cleanPath = line
        if cleanPath.hasPrefix("'") && cleanPath.hasSuffix("'") {
            cleanPath = String(cleanPath.dropFirst().dropLast())
        } else if cleanPath.hasPrefix("\"") && cleanPath.hasSuffix("\"") {
            cleanPath = String(cleanPath.dropFirst().dropLast())
        }
        cleanPath = (cleanPath as NSString).expandingTildeInPath
        cleanPath = (cleanPath as NSString).standardizingPath
        
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cleanPath, isDirectory: &isDir) && isDir.boolValue {
            return cleanPath
        } else {
            print("\(Theme.red)\(Theme.bold)Error: Path does not exist or is not a directory: \(cleanPath)\(Theme.reset)")
            Thread.sleep(forTimeInterval: 1.5)
            return nil
        }
    }
    
    private func renderHeroScreen(options: [(title: String, subtitle: String, path: String?)],
                                  selectedIndex: Int,
                                  mainVolume: VolumeInfo?,
                                  mascotFrame: Int) {
        let (termWidth, _) = terminal.getTerminalSize()
        let width = max(55, min(termWidth - 2, 72))
        
        var out = ANSI.clearScreen()
        
        // 1. Viewfinder Framing Top Corners
        let gapTop = max(10, width - 6)
        out += "\(Theme.border)\(Theme.bracketTopLeft)\(Theme.reset)" + String(repeating: " ", count: gapTop) + "\(Theme.border)\(Theme.bracketTopRight)\(Theme.reset)\n"
        out += "   \(Theme.gray)Welcome to macOS\(Theme.reset)\n"
        
        // 2. 3D Logo + Pixel Mascot side by side
        let logoLines = Animations.disk3DLogo()
        let mascotLines = Animations.renderPixelMascot(frame: mascotFrame)
        let maxLines = max(logoLines.count, mascotLines.count)
        
        for i in 0..<maxLines {
            let left = i < logoLines.count ? logoLines[i] : ""
            let right = i < mascotLines.count ? mascotLines[i] : ""
            let leftWidth = Theme.terminalColumnWidth(left)
            let rightWidth = Theme.terminalColumnWidth(right)
            
            let middlePad = max(2, width - 4 - leftWidth - rightWidth)
            let line = "   \(left)" + String(repeating: " ", count: middlePad) + "\(right)"
            out += "\(line)\n"
        }
        
        // Viewfinder Framing Bottom Corners
        let gapBottom = max(10, width - 6)
        out += "\(Theme.border)\(Theme.bracketBottomLeft)\(Theme.reset)" + String(repeating: " ", count: gapBottom) + "\(Theme.border)\(Theme.bracketBottomRight)\(Theme.reset)\n\n"
        
        // 3. Metadata Header (high-contrast on BOTH light and dark backgrounds)
        let username = NSUserName()
        out += "\(Theme.boldText)Version 1.0.0\(Theme.reset) \(Theme.gray)• Commit 36b03a6fa\(Theme.reset)\n"
        out += "\(Theme.text)Disk Viewer analyzes your Mac storage with laser speed.\(Theme.reset)\n"
        out += "\(Theme.text)Find giant folders & files to clean your disk without mistakes.\(Theme.reset)\n\n"
        
        if let vol = mainVolume {
            let usedStr = Format.formatBytes(vol.usedBytes)
            let totalStr = Format.formatBytes(vol.totalBytes)
            out += "\(Theme.cyan)\(Theme.bullet)\(Theme.reset) \(Theme.boldText)Connected to APFS Volume:\(Theme.reset) \(Theme.text)\(vol.name) (\(usedStr) / \(totalStr))\(Theme.reset)\n"
        }
        out += "\(Theme.cyan)\(Theme.bullet)\(Theme.reset) \(Theme.boldText)Logged in as user:\(Theme.reset) \(Theme.text)\(username)\(Theme.reset)\n\n"
        
        // 4. Current Path Banner
        let currentDir = FileManager.default.currentDirectoryPath
        let displayDir = currentDir.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        out += "\(Theme.boldText)\(displayDir)\(Theme.reset) \(Theme.gray)[\(mainVolume?.name ?? "APFS")]\(Theme.reset)\n"
        
        // 5. Rounded Interactive Selector Box (pixel-perfect width alignment)
        var boxLines: [String] = []
        for (i, opt) in options.enumerated() {
            let isSelected = i == selectedIndex
            if isSelected {
                boxLines.append("\(Theme.green)\(Theme.bold)> █ [\(i + 1)] \(opt.title)\(Theme.reset) \(Theme.gray)(\(opt.subtitle))\(Theme.reset)")
            } else {
                boxLines.append("    [\(i + 1)] \(opt.title) \(Theme.gray)(\(opt.subtitle))\(Theme.reset)")
            }
        }
        
        out += Theme.makeRoundedBox(lines: boxLines, width: width, borderColor: Theme.border) + "\n"
        
        // 6. Shortcuts Footer
        out += "\(Theme.gray)Enter Select  •  ↑/↓ Navigate  •  1-\(options.count) Quick Select  •  Ctrl+c Exit\(Theme.reset)\n"
        
        print(out, terminator: "")
        fflush(stdout)
    }
}
