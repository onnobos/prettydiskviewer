import Foundation
import DiskScanCore

public enum TUIViewTab: Int, CaseIterable {
    case tree = 1
    case bigFiles = 2
    case largeAndOld = 3
    case cleanup = 4
    
    public var title: String {
        switch self {
        case .tree: return "1 Tree"
        case .bigFiles: return "2 Big Files"
        case .largeAndOld: return "3 Large & Old"
        case .cleanup: return "4 Smart Cleanup"
        }
    }
}

public final class TUI {
    private let terminal: Terminal
    private let rootNode: NodeRef
    private var currentNode: NodeRef
    private let stats: ScanStats
    private let tree: ScanTree
    private let selection: SelectionManager
    private let volumeDetails: VolumeDiskDetails?
    
    private var currentTab: TUIViewTab = .tree
    private var selectedIndex: Int = 0
    private var scrollOffset: Int = 0
    private var sortMode: SortMode = .sizeDescending
    private var showHelp: Bool = false
    private var toastMessage: String? = nil
    private var totalFreedBytes: Int64 = 0
    
    private var currentChildren: [NodeRef] = []
    private var cleanupItems: [CleanupItem] = []
    private var largeAndOldItems: [NodeRef] = []
    private var largeAndOldConfig = LargeAndOldConfig()
    
    public init(terminal: Terminal, rootNode: NodeRef, stats: ScanStats, volumeDetails: VolumeDiskDetails? = nil) {
        self.terminal = terminal
        self.rootNode = rootNode
        self.currentNode = rootNode
        self.stats = stats
        self.tree = rootNode.tree
        self.selection = SelectionManager(tree: rootNode.tree)
        self.volumeDetails = volumeDetails ?? VolumeManager.volumeDetails(forPath: rootNode.path)
        refreshCurrentChildren()
        refreshCleanupCatalog()
        refreshLargeAndOld()
    }
    
    private func refreshCurrentChildren() {
        currentChildren = currentNode.sortedChildren(by: sortMode)
        if selectedIndex >= currentChildren.count {
            selectedIndex = max(0, currentChildren.count - 1)
        }
    }
    
    private func refreshCleanupCatalog() {
        cleanupItems = CleanupCatalog.shared.findCleanupItems(tree: tree)
    }
    
    private func refreshLargeAndOld() {
        largeAndOldItems = FileFilters.findLargeAndOldFiles(in: tree, config: largeAndOldConfig)
        if selectedIndex >= largeAndOldItems.count {
            selectedIndex = max(0, largeAndOldItems.count - 1)
        }
    }
    
    public func run() {
        terminal.enableRawMode()
        defer { terminal.disableRawMode() }
        
        while true {
            render()
            let key = terminal.readKey()
            
            if showHelp {
                if key == .escape || key == .char("q") || key == .char("h") || key == .enter || key == .space {
                    showHelp = false
                }
                continue
            }
            
            switch key {
            // Tab switching
            case .char("1"):
                switchTab(to: .tree)
            case .char("2"):
                switchTab(to: .bigFiles)
            case .char("3"):
                switchTab(to: .largeAndOld)
            case .char("4"):
                switchTab(to: .cleanup)
            case .tab:
                let nextRaw = (currentTab.rawValue % TUIViewTab.allCases.count) + 1
                if let nextTab = TUIViewTab(rawValue: nextRaw) {
                    switchTab(to: nextTab)
                }
                
            // Navigation
            case .up:
                if selectedIndex > 0 {
                    selectedIndex -= 1
                    if selectedIndex < scrollOffset {
                        scrollOffset = selectedIndex
                    }
                }
            case .down:
                let count = itemCountForCurrentTab()
                if selectedIndex < count - 1 {
                    selectedIndex += 1
                    let (_, height) = terminal.getTerminalSize()
                    let visibleRows = max(1, height - 14)
                    if selectedIndex >= scrollOffset + visibleRows {
                        scrollOffset = selectedIndex - visibleRows + 1
                    }
                }
            case .right, .enter:
                handleSelectOrEnter()
            case .left, .backspace:
                handleBack()
            case .home:
                selectedIndex = 0
                scrollOffset = 0
            case .end:
                let count = itemCountForCurrentTab()
                selectedIndex = max(0, count - 1)
                let (_, height) = terminal.getTerminalSize()
                let visibleRows = max(1, height - 14)
                scrollOffset = max(0, selectedIndex - visibleRows + 1)
                
            // Selection toggle
            case .space:
                handleToggleMark()
                
            // Mark all safe (for Smart Cleanup)
            case .char("a"):
                if currentTab == .cleanup {
                    markAllSafeCleanup()
                }
                
            // Sort toggle
            case .char("s"):
                if currentTab == .tree {
                    cycleSortMode()
                }
                
            // Reveal in Finder
            case .char("r"):
                handleReveal()
                
            // Trash / Delete
            case .char("d"):
                handleTrash()
                
            // Threshold adjustments for Large & Old tab
            case .char("+"), .char("="):
                if currentTab == .largeAndOld {
                    largeAndOldConfig.minSizeBytes += 50_000_000
                    refreshLargeAndOld()
                    toastMessage = "Threshold: min size \(Format.formatBytes(largeAndOldConfig.minSizeBytes))"
                }
            case .char("-"):
                if currentTab == .largeAndOld {
                    largeAndOldConfig.minSizeBytes = max(10_000_000, largeAndOldConfig.minSizeBytes - 50_000_000)
                    refreshLargeAndOld()
                    toastMessage = "Threshold: min size \(Format.formatBytes(largeAndOldConfig.minSizeBytes))"
                }
            case .char("]"):
                if currentTab == .largeAndOld {
                    largeAndOldConfig.minAgeMonths += 3
                    refreshLargeAndOld()
                    toastMessage = "Threshold: older than \(largeAndOldConfig.minAgeMonths) months"
                }
            case .char("["):
                if currentTab == .largeAndOld {
                    largeAndOldConfig.minAgeMonths = max(1, largeAndOldConfig.minAgeMonths - 3)
                    refreshLargeAndOld()
                    toastMessage = "Threshold: older than \(largeAndOldConfig.minAgeMonths) months"
                }
                
            case .char("h"), .char("?"):
                showHelp = true
            case .char("q"), .ctrlC, .escape:
                return
            default:
                break
            }
        }
    }
    
    private func switchTab(to tab: TUIViewTab) {
        currentTab = tab
        selectedIndex = 0
        scrollOffset = 0
        toastMessage = "Switched to \(tab.title)"
    }
    
    private func itemCountForCurrentTab() -> Int {
        switch currentTab {
        case .tree: return currentChildren.count
        case .bigFiles: return stats.topFiles.count
        case .largeAndOld: return largeAndOldItems.count
        case .cleanup: return cleanupItems.count
        }
    }
    
    private func handleSelectOrEnter() {
        switch currentTab {
        case .tree:
            guard !currentChildren.isEmpty, selectedIndex < currentChildren.count else { return }
            let node = currentChildren[selectedIndex]
            if node.isDirectory && !node.children.isEmpty {
                currentNode = node
                selectedIndex = 0
                scrollOffset = 0
                refreshCurrentChildren()
            }
        case .cleanup:
            guard selectedIndex < cleanupItems.count else { return }
            let item = cleanupItems[selectedIndex]
            if item.actionKind == .command, let cmd = item.command {
                promptAndRunCommand(item: item, cmd: cmd)
            } else if item.actionKind == .reveal {
                DiskActions.revealInFinder(path: item.path)
                toastMessage = "Revealed \(item.title) in Finder"
            }
        default:
            break
        }
    }
    
    private func handleBack() {
        if currentTab != .tree {
            switchTab(to: .tree)
            return
        }
        
        if currentNode.index != rootNode.index {
            let parentIdx = tree.entry(at: currentNode.index).parent
            if parentIdx < UInt32(tree.count) {
                let oldName = currentNode.name
                currentNode = NodeRef(index: parentIdx, tree: tree)
                refreshCurrentChildren()
                selectedIndex = currentChildren.firstIndex(where: { $0.name == oldName }) ?? 0
                scrollOffset = max(0, selectedIndex - 5)
            }
        }
    }
    
    private func handleToggleMark() {
        switch currentTab {
        case .tree:
            guard selectedIndex < currentChildren.count else { return }
            let node = currentChildren[selectedIndex]
            selection.toggle(node: node)
        case .bigFiles:
            guard selectedIndex < stats.topFiles.count else { return }
            let path = stats.topFiles[selectedIndex].path
            if let node = findNodeInTree(for: path) {
                selection.toggle(node: node)
            }
        case .largeAndOld:
            guard selectedIndex < largeAndOldItems.count else { return }
            selection.toggle(node: largeAndOldItems[selectedIndex])
        case .cleanup:
            guard selectedIndex < cleanupItems.count else { return }
            let item = cleanupItems[selectedIndex]
            if item.actionKind == .trash {
                if let node = findNodeInTree(for: item.path) {
                    selection.toggle(node: node)
                }
            }
        }
    }
    
    private func markAllSafeCleanup() {
        var added = 0
        for item in cleanupItems where item.safety == .safe && item.actionKind == .trash {
            if let node = findNodeInTree(for: item.path) {
                if !selection.isMarked(node: node) {
                    selection.toggle(node: node)
                    added += 1
                }
            }
        }
        toastMessage = "Marked \(added) safe cleanup item\(added == 1 ? "" : "s")"
    }
    
    private func findNodeInTree(for path: String) -> NodeRef? {
        let root = tree.root
        if root.path == path { return root }
        guard path.hasPrefix(root.path) else { return nil }
        
        var rel = String(path.dropFirst(root.path.count))
        if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        let segments = rel.split(separator: "/").map(String.init)
        
        var curr = root
        for seg in segments {
            if let child = curr.children.first(where: { $0.name == seg }) {
                curr = child
            } else {
                return nil
            }
        }
        return curr
    }
    
    private func cycleSortMode() {
        switch sortMode {
        case .sizeDescending:
            sortMode = .nameAscending
            toastMessage = "Sorted by Name (A-Z)"
        case .nameAscending:
            sortMode = .filesCountDescending
            toastMessage = "Sorted by File Count"
        case .filesCountDescending:
            sortMode = .sizeDescending
            toastMessage = "Sorted by Size (largest first)"
        }
        refreshCurrentChildren()
    }
    
    private func handleReveal() {
        let path: String
        switch currentTab {
        case .tree:
            guard selectedIndex < currentChildren.count else { return }
            path = currentChildren[selectedIndex].path
        case .bigFiles:
            guard selectedIndex < stats.topFiles.count else { return }
            path = stats.topFiles[selectedIndex].path
        case .largeAndOld:
            guard selectedIndex < largeAndOldItems.count else { return }
            path = largeAndOldItems[selectedIndex].path
        case .cleanup:
            guard selectedIndex < cleanupItems.count else { return }
            path = cleanupItems[selectedIndex].path
        }
        
        if DiskActions.revealInFinder(path: path) {
            toastMessage = "👀 Revealed in Finder: \((path as NSString).lastPathComponent)"
        } else {
            toastMessage = "❌ Could not open in Finder"
        }
    }
    
    private func handleTrash() {
        let itemsToTrash: [(path: String, name: String, size: Int64, frees: Int64, index: UInt32?)]
        
        if !selection.isEmpty {
            itemsToTrash = selection.selectedNodes.map {
                ($0.path, $0.name, $0.size, $0.frees, $0.index)
            }
        } else {
            // Trash currently highlighted item
            switch currentTab {
            case .tree:
                guard selectedIndex < currentChildren.count else { return }
                let node = currentChildren[selectedIndex]
                itemsToTrash = [(node.path, node.name, node.size, node.frees, node.index)]
            case .bigFiles:
                guard selectedIndex < stats.topFiles.count else { return }
                let bf = stats.topFiles[selectedIndex]
                itemsToTrash = [(bf.path, bf.name, bf.allocatedSize, bf.frees, nil)]
            case .largeAndOld:
                guard selectedIndex < largeAndOldItems.count else { return }
                let node = largeAndOldItems[selectedIndex]
                itemsToTrash = [(node.path, node.name, node.size, node.frees, node.index)]
            case .cleanup:
                guard selectedIndex < cleanupItems.count else { return }
                let ci = cleanupItems[selectedIndex]
                if ci.actionKind == .command, let cmd = ci.command {
                    promptAndRunCommand(item: ci, cmd: cmd)
                    return
                }
                itemsToTrash = [(ci.path, ci.title, ci.size, ci.frees, nil)]
            }
        }
        
        guard !itemsToTrash.isEmpty else { return }
        
        renderConfirmTrashModal(items: itemsToTrash)
        let confirmKey = terminal.readKey()
        if confirmKey == .char("y") || confirmKey == .char("Y") {
            let paths = itemsToTrash.map { $0.path }
            let res = DiskActions.batchMoveToTrash(paths: paths, scanRoot: stats.rootPath)
            
            for item in itemsToTrash {
                if let idx = item.index {
                    tree.markTrashed(index: idx)
                }
            }
            
            selection.clear()
            refreshCurrentChildren()
            refreshCleanupCatalog()
            refreshLargeAndOld()
            
            totalFreedBytes += res.totalFreed
            let freedStr = Format.formatBytes(res.totalFreed)
            let (trashTotal, _) = DiskActions.trashUsage()
            let trashStr = Format.formatBytes(trashTotal)
            
            toastMessage = "✨ Moved \(res.succeeded.count) item(s) to Trash (\(freedStr) freed). ⚠️ Trash holds \(trashStr) — empty in Finder to reclaim."
        } else {
            toastMessage = "Cancelled: kept safe"
        }
    }
    
    private func promptAndRunCommand(item: CleanupItem, cmd: String) {
        let (width, height) = terminal.getTerminalSize()
        var out = ""
        let row = max(1, height / 2 - 4)
        out += ANSI.moveTo(row: row, col: 1)
        
        var lines: [String] = []
        lines.append("\(Theme.cyan)\(Theme.bold)🛠️  RUN CLEANUP COMMAND:\(Theme.reset)")
        lines.append("   Command: \(Theme.boldText)\(cmd)\(Theme.reset)")
        lines.append("   Action:  \(item.explanation)")
        lines.append("")
        lines.append("   \(Theme.yellow)Run this command now? [y/N]:\(Theme.reset)")
        
        out += Theme.makeRoundedBox(lines: lines, width: min(width - 4, 76), borderColor: Theme.cyan)
        print(out, terminator: "")
        fflush(stdout)
        
        let k = terminal.readKey()
        if k == .char("y") || k == .char("Y") {
            terminal.disableRawMode()
            print("\n\(Theme.green)Running: \(cmd)...\(Theme.reset)\n")
            let p = Process()
            p.launchPath = "/bin/zsh"
            p.arguments = ["-c", cmd]
            p.launch()
            p.waitUntilExit()
            print("\nPress any key to return to Disk Viewer...")
            terminal.enableRawMode()
            _ = terminal.readKey()
            refreshCleanupCatalog()
            toastMessage = "Finished running: \(cmd)"
        } else {
            toastMessage = "Cancelled command"
        }
    }
    
    private func renderConfirmTrashModal(items: [(path: String, name: String, size: Int64, frees: Int64, index: UInt32?)]) {
        let (width, height) = terminal.getTerminalSize()
        var out = ""
        let row = max(1, height / 2 - 5)
        out += ANSI.moveTo(row: row, col: 1)
        
        var modalLines: [String] = []
        modalLines.append("\(Theme.red)\(Theme.bold)⚠️  CONFIRM MOVE TO TRASH (\(items.count) item\(items.count == 1 ? "" : "s")):\(Theme.reset)")
        modalLines.append("")
        
        let maxDisplay = min(5, items.count)
        for i in 0..<maxDisplay {
            let item = items[i]
            let freesStr = Format.formatBytes(item.frees)
            modalLines.append("   • \(Theme.boldText)\(item.name)\(Theme.reset) (\(Theme.yellow)frees \(freesStr)\(Theme.reset))")
        }
        if items.count > maxDisplay {
            modalLines.append("   ... and \(items.count - maxDisplay) more item(s)")
        }
        
        let totalFrees = items.reduce(0) { $0 + $1.frees }
        modalLines.append("")
        modalLines.append("   \(Theme.green)Total disk space freed: \(Format.formatBytes(totalFrees)) (APFS private blocks)\(Theme.reset)")
        modalLines.append("   \(Theme.gray)Items are moved to Trash, not permanently erased.\(Theme.reset)")
        modalLines.append("   \(Theme.boldText)Move to Trash? [y/N]:\(Theme.reset)")
        
        out += Theme.makeRoundedBox(lines: modalLines, width: min(width - 4, 76), borderColor: Theme.yellow)
        print(out, terminator: "")
        fflush(stdout)
    }
    
    private func render() {
        let (termWidth, height) = terminal.getTerminalSize()
        let width = max(60, termWidth - 2)
        var out = ANSI.clearScreen()
        
        // 1. Viewfinder Framing Top Box
        let gapTop = max(10, width - 6)
        out += "\(Theme.border)\(Theme.bracketTopLeft)\(String(repeating: Theme.horizontal, count: gapTop))\(Theme.bracketTopRight)\(Theme.reset)\n"
        
        // Target and Totals
        let pathDisplay: String
        switch currentTab {
        case .tree: pathDisplay = "📂 \(currentNode.path)"
        case .bigFiles: pathDisplay = "🔥 Top \(stats.topFiles.count) Largest Files on \(rootNode.name)"
        case .largeAndOld: pathDisplay = "🕰️ Large & Old Files (≥ \(Format.formatBytes(largeAndOldConfig.minSizeBytes)), ≥ \(largeAndOldConfig.minAgeMonths) mo)"
        case .cleanup: pathDisplay = "🧹 Smart Cleanup Suggestions"
        }
        
        let truncatedPath = Theme.truncateVisual(pathDisplay, maxCols: width - 6)
        out += "  \(Theme.border)│\(Theme.reset) \(Theme.boldText)\(truncatedPath)\(Theme.reset)\n"
        
        let rootSize = Format.formatBytes(rootNode.size)
        let rootFrees = Format.formatBytes(rootNode.frees)
        let rootFiles = Format.formatCount(Int64(rootNode.fileCount))
        
        if let v = volumeDetails, (currentNode.path == "/" || currentNode.path == v.mountPoint) {
            let usedStr = Format.formatBytes(v.usedBytes)
            let totalStr = Format.formatBytes(v.totalBytes)
            let freeStr = Format.formatBytes(v.freeBytes)
            let purgeStr = v.purgeableBytes > 0 ? " (\(Format.formatBytes(v.purgeableBytes)) purgeable)" : ""
            let pct = Format.formatPercent(Double(v.usedBytes) / Double(max(1, v.totalBytes)))
            
            let line1 = "\(Theme.cyan)\(Theme.bullet)\(Theme.reset) \(Theme.boldText)APFS Volume:\(Theme.reset) \(v.name) • \(Theme.boldText)\(usedStr)\(Theme.reset) used of \(totalStr) (\(pct) full) • \(Theme.gray)\(freeStr) free\(purgeStr)\(Theme.reset)"
            out += "  \(Theme.border)│\(Theme.reset) " + Theme.truncateVisual(line1, maxCols: width - 6) + "\n"
            
            let systemGap = max(0, v.usedBytes - rootNode.size)
            let systemGapStr = Format.formatBytes(systemGap)
            let snapCount = v.localSnapshots.count
            let snapDesc = snapCount > 0 ? " • 📸 \(snapCount) local snapshot\(snapCount == 1 ? "" : "s")" : ""
            
            var line2 = "\(Theme.cyan)\(Theme.bullet)\(Theme.reset) \(Theme.gray)Scanned User Files: \(Theme.boldText)\(rootSize)\(Theme.reset) \(Theme.gray)(frees \(rootFrees)) in \(rootFiles) files\(Theme.reset)  \(Theme.yellow)System & Snapshots: ~\(systemGapStr)\(snapDesc)\(Theme.reset)"
            if !selection.isEmpty {
                line2 += "  \(Theme.green)[\(selection.summary)]\(Theme.reset)"
            }
            if totalFreedBytes > 0 {
                line2 += "  \(Theme.cyan)✨ Freed: \(Format.formatBytes(totalFreedBytes))\(Theme.reset)"
            }
            out += "  \(Theme.border)│\(Theme.reset) " + Theme.truncateVisual(line2, maxCols: width - 6) + "\n"
        } else {
            var summaryLine = "\(Theme.cyan)\(Theme.bullet)\(Theme.reset) \(Theme.gray)Total: \(Theme.boldText)\(rootSize)\(Theme.reset) \(Theme.gray)(frees \(rootFrees)) across \(rootFiles) files\(Theme.reset)"
            if !selection.isEmpty {
                summaryLine += "  \(Theme.green)[\(selection.summary)]\(Theme.reset)"
            }
            if totalFreedBytes > 0 {
                summaryLine += "  \(Theme.cyan)✨ Freed: \(Format.formatBytes(totalFreedBytes))\(Theme.reset)"
            }
            out += "  \(Theme.border)│\(Theme.reset) " + Theme.truncateVisual(summaryLine, maxCols: width - 6) + "\n"
        }
        
        // Tab Bar
        var tabBar = ""
        for tab in TUIViewTab.allCases {
            let isActive = tab == currentTab
            if isActive {
                tabBar += "\(Theme.green)\(Theme.bold)[ \(tab.title) ]\(Theme.reset)  "
            } else {
                tabBar += "\(Theme.gray)  \(tab.title)  \(Theme.reset)  "
            }
        }
        out += "  \(Theme.border)│\(Theme.reset) " + Theme.truncateVisual(tabBar, maxCols: width - 6) + "\n"
        
        // Viewfinder Framing Bottom Corners
        out += "\(Theme.border)\(Theme.bracketBottomLeft)\(String(repeating: Theme.horizontal, count: gapTop))\(Theme.bracketBottomRight)\(Theme.reset)\n"
        
        // Column Header
        let availableNameCols = max(20, width - 56)
        let nameHeader = "NAME".padding(toLength: availableNameCols, withPad: " ", startingAt: 0)
        
        let colHeader: String
        switch currentTab {
        case .tree:
            colHeader = "     \(Theme.gray)SIZE        FREES       BAR         \(nameHeader)  MODIFIED\(Theme.reset)"
        case .bigFiles:
            let nameColWidth = max(20, (width - 45) / 2)
            let pathColWidth = max(20, width - 45 - nameColWidth)
            let nH = "NAME".padding(toLength: nameColWidth, withPad: " ", startingAt: 0)
            let pH = "PATH".padding(toLength: pathColWidth, withPad: " ", startingAt: 0)
            colHeader = "     \(Theme.gray)SIZE        FREES       \(nH)  MODIFIED    \(pH)\(Theme.reset)"
        case .largeAndOld:
            let nameColWidth = max(20, (width - 45) / 2)
            let pathColWidth = max(20, width - 45 - nameColWidth)
            let nH = "NAME".padding(toLength: nameColWidth, withPad: " ", startingAt: 0)
            let pH = "PATH".padding(toLength: pathColWidth, withPad: " ", startingAt: 0)
            colHeader = "     \(Theme.gray)SIZE        FREES       \(nH)  MODIFIED    \(pH)\(Theme.reset)"
        case .cleanup:
            let itemColWidth = max(30, width - 65)
            let iH = "ITEM".padding(toLength: itemColWidth, withPad: " ", startingAt: 0)
            colHeader = "     \(Theme.gray)SAFETY      SIZE        FREES       \(iH)  ACTION\(Theme.reset)"
        }
        out += colHeader + "\n"
        
        // Visible list
        let visibleRows = max(1, height - 15)
        switch currentTab {
        case .tree:
            renderTreeList(width: width, visibleRows: visibleRows, out: &out)
        case .bigFiles:
            renderBigFilesList(width: width, visibleRows: visibleRows, out: &out)
        case .largeAndOld:
            renderLargeAndOldList(width: width, visibleRows: visibleRows, out: &out)
        case .cleanup:
            renderCleanupList(width: width, visibleRows: visibleRows, out: &out)
        }
        
        // Bottom Input Prompt Box
        out += ANSI.moveTo(row: height - 3, col: 1)
        let bottomPrompt: String
        if let toast = toastMessage {
            bottomPrompt = "\(Theme.green)> \(Theme.boldText)█ \(toast)\(Theme.reset)"
            toastMessage = nil
        } else {
            switch currentTab {
            case .tree:
                bottomPrompt = "\(Theme.cyan)> \(Theme.boldText)█ \(Theme.gray)1-4 Tabs • Space Mark • d Trash • s Sort • r Reveal • q Exit\(Theme.reset)"
            case .cleanup:
                bottomPrompt = "\(Theme.cyan)> \(Theme.boldText)█ \(Theme.gray)a Mark Safe • Space Mark • d Trash/Run • r Reveal • q Exit\(Theme.reset)"
            case .largeAndOld:
                bottomPrompt = "\(Theme.cyan)> \(Theme.boldText)█ \(Theme.gray)+/- Size • [/] Age • Space Mark • d Trash • r Reveal\(Theme.reset)"
            case .bigFiles:
                bottomPrompt = "\(Theme.cyan)> \(Theme.boldText)█ \(Theme.gray)Space Mark • d Trash • r Reveal • 1-4 Tabs • q Exit\(Theme.reset)"
            }
        }
        
        out += Theme.makeRoundedBox(lines: [bottomPrompt], width: width, borderColor: Theme.border) + "\n"
        
        if showHelp {
            renderHelpOverlay(width: width, height: height, out: &out)
        }
        
        print(out, terminator: "")
        fflush(stdout)
    }
    
    private func renderTreeList(width: Int, visibleRows: Int, out: inout String) {
        if currentChildren.isEmpty {
            out += "  \(Theme.gray)(Folder is empty)\(Theme.reset)\n"
            return
        }
        
        let endIndex = min(currentChildren.count, scrollOffset + visibleRows)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let availableNameCols = max(20, width - 56)
        
        for i in scrollOffset..<endIndex {
            let node = currentChildren[i]
            let isSelected = i == selectedIndex
            let isMarked = selection.isMarked(node: node)
            
            let cursor = isSelected ? "\(Theme.green)\(Theme.bold)❯\(Theme.reset)" : " "
            let markBox = isMarked ? "\(Theme.green)[✓]\(Theme.reset)" : "   "
            let icon = node.itemKind.icon
            
            let fraction = currentNode.size > 0 ? Double(node.size) / Double(currentNode.size) : 0.0
            let bar = Animations.makeGradientBar(fraction: fraction, width: 8)
            let sizeStr = Format.formatBytes(node.size).padding(toLength: 10, withPad: " ", startingAt: 0)
            let freesStr = Format.formatBytes(node.frees).padding(toLength: 10, withPad: " ", startingAt: 0)
            let modStr = dateFormatter.string(from: node.mtime)
            
            var namePart = "\(icon) \(node.name)"
            if node.isDirectory { namePart += "/" }
            
            let visualW = Theme.terminalColumnWidth(namePart)
            let truncatedName = visualW > availableNameCols ? Theme.truncateVisual(namePart, maxCols: availableNameCols) : namePart
            let pad = max(0, availableNameCols - Theme.terminalColumnWidth(truncatedName))
            let namePadded = "\(truncatedName)\(String(repeating: " ", count: pad))"
            
            let line = " \(cursor)\(markBox) \(Theme.boldText)\(sizeStr)\(Theme.reset) \(freesStr) [\(bar)]  \(namePadded)  \(Theme.gray)\(modStr)\(Theme.reset)"
            out += line + "\n"
        }
    }
    
    private func renderBigFilesList(width: Int, visibleRows: Int, out: inout String) {
        let count = stats.topFiles.count
        if count == 0 {
            out += "  \(Theme.gray)(No files found)\(Theme.reset)\n"
            return
        }
        
        let endIndex = min(count, scrollOffset + visibleRows)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let nameColWidth = max(20, (width - 45) / 2)
        let pathColWidth = max(20, width - 45 - nameColWidth)
        
        for i in scrollOffset..<endIndex {
            let entry = stats.topFiles[i]
            let isSelected = i == selectedIndex
            let isMarked = findNodeInTree(for: entry.path).map { selection.isMarked(node: $0) } ?? false
            
            let cursor = isSelected ? "\(Theme.green)\(Theme.bold)❯\(Theme.reset)" : " "
            let markBox = isMarked ? "\(Theme.green)[✓]\(Theme.reset)" : "   "
            
            let sizeStr = Format.formatBytes(entry.allocatedSize).padding(toLength: 10, withPad: " ", startingAt: 0)
            let freesStr = Format.formatBytes(entry.frees).padding(toLength: 10, withPad: " ", startingAt: 0)
            let modStr = dateFormatter.string(from: entry.mtime)
            
            let rawName = "📄 \(entry.name)"
            let nameSnippet = Theme.terminalColumnWidth(rawName) > nameColWidth ? Theme.truncateVisual(rawName, maxCols: nameColWidth) : rawName
            let padN = max(0, nameColWidth - Theme.terminalColumnWidth(nameSnippet))
            let namePadded = "\(nameSnippet)\(String(repeating: " ", count: padN))"
            
            let pathSnippet = Theme.truncateVisual(entry.path, maxCols: pathColWidth)
            
            let line = " \(cursor)\(markBox) \(Theme.boldText)\(sizeStr)\(Theme.reset) \(freesStr) \(namePadded)  \(Theme.gray)\(modStr)\(Theme.reset)  \(Theme.dim)\(pathSnippet)\(Theme.reset)"
            out += line + "\n"
        }
    }
    
    private func renderLargeAndOldList(width: Int, visibleRows: Int, out: inout String) {
        if largeAndOldItems.isEmpty {
            out += "  \(Theme.gray)(No files match the large & old filter: ≥ \(Format.formatBytes(largeAndOldConfig.minSizeBytes)), ≥ \(largeAndOldConfig.minAgeMonths) months)\(Theme.reset)\n"
            return
        }
        
        let endIndex = min(largeAndOldItems.count, scrollOffset + visibleRows)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let nameColWidth = max(20, (width - 45) / 2)
        let pathColWidth = max(20, width - 45 - nameColWidth)
        
        for i in scrollOffset..<endIndex {
            let node = largeAndOldItems[i]
            let isSelected = i == selectedIndex
            let isMarked = selection.isMarked(node: node)
            
            let cursor = isSelected ? "\(Theme.green)\(Theme.bold)❯\(Theme.reset)" : " "
            let markBox = isMarked ? "\(Theme.green)[✓]\(Theme.reset)" : "   "
            
            let sizeStr = Format.formatBytes(node.size).padding(toLength: 10, withPad: " ", startingAt: 0)
            let freesStr = Format.formatBytes(node.frees).padding(toLength: 10, withPad: " ", startingAt: 0)
            let modStr = dateFormatter.string(from: node.mtime)
            
            let rawName = "📄 \(node.name)"
            let nameSnippet = Theme.terminalColumnWidth(rawName) > nameColWidth ? Theme.truncateVisual(rawName, maxCols: nameColWidth) : rawName
            let padN = max(0, nameColWidth - Theme.terminalColumnWidth(nameSnippet))
            let namePadded = "\(nameSnippet)\(String(repeating: " ", count: padN))"
            
            let pathSnippet = Theme.truncateVisual(node.path, maxCols: pathColWidth)
            
            let line = " \(cursor)\(markBox) \(Theme.boldText)\(sizeStr)\(Theme.reset) \(freesStr) \(namePadded)  \(Theme.gray)\(modStr)\(Theme.reset)  \(Theme.dim)\(pathSnippet)\(Theme.reset)"
            out += line + "\n"
        }
    }
    
    private func renderCleanupList(width: Int, visibleRows: Int, out: inout String) {
        if cleanupItems.isEmpty {
            out += "  \(Theme.gray)(No cleanup recommendations for this system)\(Theme.reset)\n"
            return
        }
        
        let endIndex = min(cleanupItems.count, scrollOffset + visibleRows)
        let itemColWidth = max(30, width - 65)
        
        for i in scrollOffset..<endIndex {
            let item = cleanupItems[i]
            let isSelected = i == selectedIndex
            let isMarked = findNodeInTree(for: item.path).map { selection.isMarked(node: $0) } ?? false
            
            let cursor = isSelected ? "\(Theme.green)\(Theme.bold)❯\(Theme.reset)" : " "
            let markBox = isMarked ? "\(Theme.green)[✓]\(Theme.reset)" : "   "
            let badge = item.safety.badge.padding(toLength: 10, withPad: " ", startingAt: 0)
            let sizeStr = Format.formatBytes(item.size).padding(toLength: 10, withPad: " ", startingAt: 0)
            let freesStr = Format.formatBytes(item.frees).padding(toLength: 10, withPad: " ", startingAt: 0)
            
            let itemSnippet = Theme.terminalColumnWidth(item.title) > itemColWidth ? Theme.truncateVisual(item.title, maxCols: itemColWidth) : item.title
            let padI = max(0, itemColWidth - Theme.terminalColumnWidth(itemSnippet))
            let itemPadded = "\(itemSnippet)\(String(repeating: " ", count: padI))"
            
            let actionDesc: String
            switch item.actionKind {
            case .trash: actionDesc = "\(Theme.yellow)d: Trash\(Theme.reset)"
            case .command: actionDesc = "\(Theme.cyan)Enter: \(item.command ?? "")\(Theme.reset)"
            case .reveal: actionDesc = "\(Theme.gray)r: Reveal in Finder\(Theme.reset)"
            case .info: actionDesc = "\(Theme.dim)Empty in Finder\(Theme.reset)"
            }
            
            let line = " \(cursor)\(markBox) \(badge) \(Theme.boldText)\(sizeStr)\(Theme.reset) \(freesStr) \(itemPadded)  \(actionDesc)"
            out += line + "\n"
        }
    }
    
    private func renderHelpOverlay(width: Int, height: Int, out: inout String) {
        var lines: [String] = []
        lines.append("\(Theme.cyan)\(Theme.bold)DISK VIEWER KEYBOARD SHORTCUTS:\(Theme.reset)")
        lines.append("")
        lines.append("  \(Theme.green)1 - 4\(Theme.reset)         Switch views: Tree, Big Files, Large & Old, Smart Cleanup")
        lines.append("  \(Theme.green)Tab\(Theme.reset)           Cycle to next view tab")
        lines.append("  \(Theme.green)↑ / ↓\(Theme.reset)         Navigate items (or j / k)")
        lines.append("  \(Theme.green)Enter / →\(Theme.reset)     Open folder / execute cleanup command")
        lines.append("  \(Theme.green)Backspace / ←\(Theme.reset) Up one directory")
        lines.append("  \(Theme.green)Space\(Theme.reset)         Toggle mark/select item for batch trash")
        lines.append("  \(Theme.green)a\(Theme.reset)             Mark all Safe items in Smart Cleanup")
        lines.append("  \(Theme.green)d\(Theme.reset)             Move marked item(s) to Trash safely")
        lines.append("  \(Theme.green)r\(Theme.reset)             Reveal highlighted item in Finder")
        lines.append("  \(Theme.green)s\(Theme.reset)             Cycle sort: Size ↓, Name A-Z, Files count")
        lines.append("  \(Theme.green)+ / -\(Theme.reset)         Adjust min size threshold (Large & Old tab)")
        lines.append("  \(Theme.green)[ / ]\(Theme.reset)         Adjust age months threshold (Large & Old tab)")
        lines.append("  \(Theme.green)q / Esc\(Theme.reset)       Quit")
        lines.append("")
        lines.append("\(Theme.gray)Press any key to close help...\(Theme.reset)")
        
        let box = Theme.makeRoundedBox(lines: lines, width: min(width - 4, 76), borderColor: Theme.cyan)
        let row = max(1, height / 2 - 8)
        out += ANSI.moveTo(row: row, col: 1) + box
    }
    
    public static func printPlainSummary(rootNode: NodeRef, stats: ScanStats, json: Bool = false, volumeDetails: VolumeDiskDetails? = nil) {
        let vDetails = volumeDetails ?? VolumeManager.volumeDetails(forPath: rootNode.path)
        if json {
            var topList: [[String: Any]] = []
            for bf in stats.topFiles {
                topList.append([
                    "name": bf.name,
                    "path": bf.path,
                    "allocatedSize": bf.allocatedSize,
                    "frees": bf.frees,
                    "mtime": bf.mtime.timeIntervalSince1970
                ])
            }
            
            var dict: [String: Any] = [
                "rootPath": stats.rootPath,
                "scannedAllocatedBytes": stats.totalAllocatedBytes,
                "scannedFreesBytes": stats.totalFreesBytes,
                "totalFiles": stats.totalFilesScanned,
                "totalFolders": stats.totalDirsScanned,
                "elapsedSeconds": stats.elapsedSeconds,
                "topFiles": topList
            ]
            if let v = vDetails {
                dict["volume"] = [
                    "name": v.name,
                    "totalBytes": v.totalBytes,
                    "usedBytes": v.usedBytes,
                    "freeBytes": v.freeBytes,
                    "purgeableBytes": v.purgeableBytes,
                    "localSnapshots": v.localSnapshots
                ]
            }
            
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
               let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }
            return
        }
        
        print("📁 Target: \(stats.rootPath)")
        if let v = vDetails, (rootNode.path == "/" || rootNode.path == v.mountPoint) {
            let usedStr = Format.formatBytes(v.usedBytes)
            let totalStr = Format.formatBytes(v.totalBytes)
            let freeStr = Format.formatBytes(v.freeBytes)
            let purgeStr = v.purgeableBytes > 0 ? " (\(Format.formatBytes(v.purgeableBytes)) purgeable)" : ""
            let pct = Format.formatPercent(Double(v.usedBytes) / Double(max(1, v.totalBytes)))
            print("💽 APFS Volume (\(v.name)): \(usedStr) used of \(totalStr) (\(pct) full) • \(freeStr) free\(purgeStr)")
            let systemGap = max(0, v.usedBytes - stats.totalAllocatedBytes)
            print("   ↳ Active Scanned Files: \(Format.formatBytes(stats.totalAllocatedBytes)) (\(Format.formatCount(stats.totalFilesScanned)) files)")
            print("   ↳ System Data & APFS Snapshots: ~\(Format.formatBytes(systemGap)) (\(v.localSnapshots.count) local snapshots)")
        } else {
            print("📊 Total Size: \(Format.formatBytes(stats.totalAllocatedBytes)) (frees: \(Format.formatBytes(stats.totalFreesBytes)))")
            print("📄 Files: \(Format.formatCount(stats.totalFilesScanned)) across \(Format.formatCount(stats.totalDirsScanned)) folders")
        }
        print("⏱️ Scan Time: \(Format.formatDuration(stats.elapsedSeconds))")
        print("")
        print("Top items:")
        let sorted = rootNode.sortedChildren(by: .sizeDescending)
        for child in sorted.prefix(20) {
            let icon = child.itemKind.icon
            let sz = Format.formatBytes(child.size)
            let fr = Format.formatBytes(child.frees)
            print("  \(sz.padding(toLength: 10, withPad: " ", startingAt: 0)) (frees \(fr)) \(icon) \(child.name)")
        }
    }
}
