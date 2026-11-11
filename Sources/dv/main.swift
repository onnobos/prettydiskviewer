import Foundation
import DiskScanCore

struct CommandLineConfig {
    var targetPath: String? = nil
    var scanEntireDisk: Bool = false
    var listVolumesOnly: Bool = false
    var plainOutput: Bool = false
    var jsonOutput: Bool = false
    var apparentSize: Bool = false
    var crossMounts: Bool = false
    var noFun: Bool = false
    var noCache: Bool = false
    var threads: Int = ProcessInfo.processInfo.activeProcessorCount
    var showHelp: Bool = false
    var maxTopFiles: Int = 100
}

func parseArgs() -> CommandLineConfig {
    var config = CommandLineConfig()
    let args = CommandLine.arguments.dropFirst()
    
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "-h", "--help":
            config.showHelp = true
        case "--disk":
            config.scanEntireDisk = true
        case "--volumes":
            config.listVolumesOnly = true
        case "--plain", "--non-interactive":
            config.plainOutput = true
        case "--json":
            config.plainOutput = true
            config.jsonOutput = true
        case "--no-cache":
            config.noCache = true
        case "--apparent":
            config.apparentSize = true
        case "--cross-mounts":
            config.crossMounts = true
        case "--no-fun":
            config.noFun = true
        case "--threads":
            if let next = iterator.next(), let val = Int(next) {
                config.threads = max(1, val)
            }
        case "--top":
            if let next = iterator.next(), let val = Int(next) {
                config.maxTopFiles = val
            }
        default:
            if !arg.hasPrefix("-") && config.targetPath == nil {
                config.targetPath = arg
            }
        }
    }
    return config
}

func printHelp() {
    print("""
    💾 DISK VIEWER (dv) - Laser-fast, friendly disk usage analyzer for macOS
    
    USAGE:
      dv [options] [path]
    
    EXAMPLES:
      dv                     Open GitHub Copilot-style interactive volume & folder picker
      dv ~                   Scan your home directory
      dv /                   Scan entire Mac (System + Data volumes)
      dv --disk              Scan root disk
      dv --volumes           List all mounted disks and free space
      dv --plain .           Print quick summary to stdout without TUI
      dv --plain --json .    Print machine-readable JSON summary
    
    OPTIONS:
      --disk                 Scan the entire Mac filesystem (/)
      --volumes              List mounted internal and external volumes
      --plain                Print plain-text summary and exit (no interactive TUI)
      --json                 Output machine-readable JSON (with --plain)
      --no-cache             Bypass reading from or writing to the disk cache
      --threads <N>          Worker threads to use (default: \(ProcessInfo.processInfo.activeProcessorCount))
      --apparent             Count apparent file sizes instead of allocated blocks
      --cross-mounts         Cross filesystem boundaries into other mounted drives
      --no-fun               Disable ASCII mascot animations and jokes
      --top <N>              Number of top largest files to index (default: 100)
      -h, --help             Show this help message
    
    CONTROLS DURING SCAN:
      q, Esc, Ctrl-C         Cancel & quit scan immediately
    
    VIEWS IN TUI:
      1: Tree                Interactive directory tree browser
      2: Big Files           Top largest files on scanned target
      3: Large & Old         Files ≥ 100 MB not modified in 12+ months
      4: Smart Cleanup       Caches, DerivedData, Docker VM, and old downloads
    """)
}

final class AtomicFlag: @unchecked Sendable {
    private var val = false
    private let lock = NSLock()
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return val }
        set { lock.lock(); val = newValue; lock.unlock() }
    }
}

func main() {
    let config = parseArgs()
    let terminal = Terminal()
    
    if config.showHelp {
        printHelp()
        return
    }
    
    // Global signal handler for graceful exit
    signal(SIGINT) { _ in
        print("\u{001B}[?25h\u{001B}[?1049l\n\n🛑 Aborted by user (SIGINT). Goodbye! 👋\n")
        exit(0)
    }
    
    if config.listVolumesOnly {
        print("\n=== MOUNTED VOLUMES ===")
        let volumes = VolumeManager.listVolumes()
        for v in volumes {
            let kind = v.isInternal ? "Internal" : "External"
            let usedStr = Format.formatBytes(v.usedBytes)
            let freeStr = Format.formatBytes(v.freeBytes)
            let totalStr = Format.formatBytes(v.totalBytes)
            print("  \(v.name) (\(kind), \(v.fileSystemType))")
            print("    Mount: \(v.mountPoint)")
            print("    Space: \(usedStr) used, \(freeStr) free of \(totalStr) total\n")
        }
        return
    }
    
    var chosenPath: String? = config.targetPath
    if config.scanEntireDisk {
        chosenPath = "/"
    }
    
    // If no path was passed on command line, use friendly interactive picker if running in TTY
    if chosenPath == nil {
        if terminal.isTTY && !config.plainOutput {
            let friendly = FriendlyInterface(terminal: terminal)
            chosenPath = friendly.selectTargetInteractive()
            if chosenPath == nil {
                print("Goodbye! 👋")
                return
            }
        } else {
            // Default to home folder if not interactive
            chosenPath = FileManager.default.homeDirectoryForCurrentUser.path
        }
    }
    
    guard let target = chosenPath else {
        print("No target path selected.")
        return
    }
    
    let resolvedTarget = (target as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: resolvedTarget).resolvingSymlinksInPath()
    let standardPath = url.path
    
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: standardPath, isDirectory: &isDir) else {
        print("\(Theme.red)❌ Error: Path does not exist: \(standardPath)\(Theme.reset)")
        exit(1)
    }
    
    // Check cache
    var loadedCachedTree: ScanTree? = nil
    if !config.noCache && !config.plainOutput && terminal.isTTY {
        let (hasCache, ageSeconds, _) = ScanCache.shared.cacheInfo(for: standardPath)
        if hasCache, let age = ageSeconds, age < (7 * 86400) {
            let ageDesc = Format.formatDuration(age)
            print("\n  \(Theme.cyan)⚡ Cached scan from \(ageDesc) ago found for \(standardPath).\(Theme.reset)")
            print("  \(Theme.boldText)[Enter]\(Theme.reset) Open cached scan instantly  •  \(Theme.boldText)[r]\(Theme.reset) Rescan from disk: ", terminator: "")
            fflush(stdout)
            
            terminal.enableRawMode()
            let choice = terminal.readKey()
            terminal.disableRawMode()
            print("")
            
            if choice == .enter || choice == .space {
                if let cachedTree = ScanCache.shared.load(rootPath: standardPath) {
                    loadedCachedTree = cachedTree
                }
            }
        }
    }
    
    let rootNode: NodeRef
    var stats = ScanStats()
    
    if let cached = loadedCachedTree {
        rootNode = cached.root
        stats.rootPath = standardPath
        stats.totalAllocatedBytes = rootNode.size
        stats.totalFreesBytes = rootNode.frees
        stats.totalFilesScanned = Int64(rootNode.fileCount)
        stats.totalDirsScanned = Int64(rootNode.dirCount)
        stats.elapsedSeconds = 0.005
    } else {
        let options = ScanOptions(
            crossMounts: config.crossMounts,
            apparentSizeOnly: config.apparentSize,
            maxTopFiles: config.maxTopFiles,
            threads: config.threads
        )
        
        let scanner = DiskScanner(options: options)
        let isAnimated = terminal.isTTY && !config.plainOutput && !config.noFun
        
        if isAnimated {
            terminal.enableRawMode()
        } else {
            print("🔍 Scanning \(standardPath)... (press Ctrl-C to quit)")
        }
        
        // Background keyboard listener with poll() timeout to prevent swallowing the first TUI keypress
        let scanFinished = AtomicFlag()
        let keyListenerQueue = DispatchQueue(label: "dv.keylistener", qos: .userInteractive)
        if isAnimated {
            keyListenerQueue.async {
                while !scanFinished.value && !scanner.isCancelled {
                    if terminal.hasKeyAvailable(timeoutMs: 50) {
                        let key = terminal.readKey()
                        if key == .char("q") || key == .escape || key == .ctrlC {
                            scanner.cancel()
                            break
                        }
                    }
                }
            }
        }
        
        // Check if target is an entire disk or volume
        let volumeDetails = VolumeManager.volumeDetails(forPath: standardPath)
        let isVolumeRoot = (standardPath == "/" || VolumeManager.listVolumes().contains { $0.mountPoint == standardPath })
        let targetDiskUsedBytes: Int64? = isVolumeRoot ? volumeDetails?.usedBytes : nil
        let targetDiskTotalBytes: Int64? = isVolumeRoot ? volumeDetails?.totalBytes : nil

        let (scannedRoot, scanStats) = scanner.scan(path: standardPath) { progress in
            guard isAnimated else { return }
            
            let (termWidth, _) = terminal.getTerminalSize()
            let width = max(60, min(termWidth - 4, 100))
            let contentWidth = width - 4
            
            func truncateMiddle(_ text: String, maxCols: Int) -> String {
                if Theme.terminalColumnWidth(text) <= maxCols { return text }
                let keep = max(4, (maxCols - 3) / 2)
                let prefix = String(text.prefix(keep))
                let suffix = String(text.suffix(keep))
                return "\(prefix)...\(suffix)"
            }
            
            let spinner = Animations.currentSpinner(elapsed: progress.elapsed)
            let joke = Animations.currentJoke(elapsed: progress.elapsed)
            
            let filesStr = Format.formatCount(progress.filesCount)
            let bytesStr = Format.formatBytes(progress.bytesScanned)
            let timeStr = Format.formatDuration(progress.elapsed)
            let speedStr = Format.formatCount(Int64(progress.filesPerSecond))
            
            let dirsProcessedStr = Format.formatCount(progress.dirsProcessed)
            let dirsRemainingStr = Format.formatCount(progress.dirsRemaining)
            
            var display = ANSI.moveTo(row: 1, col: 1)
            
            // Viewfinder Framing Top Corners
            let gapTop = max(10, width - 6)
            display += "\(Theme.border)\(Theme.bracketTopLeft)\(String(repeating: Theme.horizontal, count: gapTop))\(Theme.bracketTopRight)\(Theme.reset)\n"
            display += "  \(Theme.green)\(Theme.bullet)\(Theme.reset) \(Theme.boldText)SCANNING IN PROGRESS [\(spinner)]\(Theme.reset)  \(Theme.gray)active for \(timeStr)\(Theme.reset)\n"
            
            // Progress Card Lines
            var cardLines: [String] = []
            cardLines.append("\(Theme.gray)📂 Target:\(Theme.reset) \(Theme.boldText)\(standardPath)\(Theme.reset)")
            cardLines.append("")
            
            if let totalUsed = targetDiskUsedBytes, let totalCap = targetDiskTotalBytes, totalUsed > 0 {
                let volName = volumeDetails?.name ?? "APFS"
                let totalUsedStr = Format.formatBytes(totalUsed)
                let totalCapStr = Format.formatBytes(totalCap)
                let diskPct = Format.formatPercent(Double(totalUsed) / Double(max(1, totalCap)))
                
                cardLines.append("\(Theme.gray)📊 APFS Volume (\(volName)):\(Theme.reset)")
                cardLines.append("   \(Theme.boldText)\(totalUsedStr)\(Theme.reset) used of \(Theme.gray)\(totalCapStr)\(Theme.reset) (\(diskPct) full)")
                
                let barWidth = max(12, contentWidth - 16)
                let bar = Animations.makeActivityBar(elapsed: progress.elapsed, width: barWidth)
                cardLines.append("   [\(bar)] \(Theme.cyan)\(bytesStr) active files scanned\(Theme.reset)")
                cardLines.append("")
            } else {
                // Subfolder Activity Pulse
                let barWidth = max(12, contentWidth - 16)
                let bar = Animations.makeActivityBar(elapsed: progress.elapsed, width: barWidth)
                cardLines.append("\(Theme.gray)📊 Activity:\(Theme.reset)")
                cardLines.append("   [\(bar)] \(Theme.cyan)\(bytesStr) munched\(Theme.reset)")
                cardLines.append("")
            }
            
            cardLines.append("\(Theme.gray)📄 Files Scanned:\(Theme.reset) \(Theme.boldText)\(filesStr) files\(Theme.reset)  \(Theme.gray)[\(speedStr) files/sec]\(Theme.reset)")
            cardLines.append("\(Theme.gray)📁 Folders:\(Theme.reset)       \(Theme.boldText)\(dirsProcessedStr) visited\(Theme.reset)  \(Theme.gray)(\(dirsRemainingStr) in queue)\(Theme.reset)")
            cardLines.append("")
            
            let pathSnippet = truncateMiddle(progress.currentPath, maxCols: max(15, contentWidth - 14))
            cardLines.append("\(Theme.gray)🔍 Reading:\(Theme.reset) \(Theme.gray)\(pathSnippet)\(Theme.reset)")
            
            let jokeSnippet = truncateMiddle(joke, maxCols: max(15, contentWidth - 6))
            cardLines.append("\(Theme.yellow)💬 \"\(jokeSnippet)\"\(Theme.reset)")
            
            display += Theme.makeRoundedBox(lines: cardLines, width: width, borderColor: Theme.border) + "\n"
            
            // Viewfinder Framing Bottom Corners
            let gapBottom = max(10, width - 6)
            display += "\(Theme.border)\(Theme.bracketBottomLeft)\(String(repeating: Theme.horizontal, count: gapBottom))\(Theme.bracketBottomRight)\(Theme.reset)\n"
            
            // Input Prompt Box
            let inputLine = "\(Theme.red)> \(Theme.boldText)█ [q] or [Ctrl+c] Cancel & Quit Scan\(Theme.reset)"
            display += Theme.makeRoundedBox(lines: [inputLine], width: width, borderColor: Theme.border) + "\n"
            
            print(display, terminator: "")
            fflush(stdout)
        }
        
        scanFinished.value = true
        Thread.sleep(forTimeInterval: 0.06) // Allow keylistener thread to cleanly terminate
        
        // If user cancelled during scan
        if scanStats.isCancelled {
            if isAnimated {
                terminal.disableRawMode()
            }
            print("\n\(Theme.yellow)\(Theme.bold)🛑 Scan cancelled by user after \(Format.formatDuration(scanStats.elapsedSeconds)).\(Theme.reset)")
            print("   Scanned \(Format.formatCount(scanStats.totalFilesScanned)) files across \(Format.formatCount(scanStats.totalDirsScanned)) folders (\(Format.formatBytes(scanStats.totalAllocatedBytes))).")
            print("   Exited safely. Goodbye! 👋\n")
            return
        }
        
        rootNode = scannedRoot
        stats = scanStats
        
        // Save to cache asynchronously if completed normally
        if !config.noCache && !scanStats.isCancelled {
            _ = ScanCache.shared.save(tree: scannedRoot.tree)
        }
    }
    
    if !terminal.isTTY || config.plainOutput {
        terminal.disableRawMode()
        let volDetails = VolumeManager.volumeDetails(forPath: standardPath)
        TUI.printPlainSummary(rootNode: rootNode, stats: stats, json: config.jsonOutput, volumeDetails: volDetails)
        return
    }
    
    // In interactive mode, launch TUI
    let volDetails = VolumeManager.volumeDetails(forPath: standardPath)
    let tui = TUI(terminal: terminal, rootNode: rootNode, stats: stats, volumeDetails: volDetails)
    tui.run()
    
    terminal.disableRawMode()
    print("\nGoodbye! Have a spacious Mac day! 🍏✨\n")
}

main()
