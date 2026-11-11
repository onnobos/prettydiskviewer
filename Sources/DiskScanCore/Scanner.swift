import Foundation
import CDiskScan

public struct ScanOptions: Sendable {
    public var crossMounts: Bool
    public var apparentSizeOnly: Bool
    public var maxTopFiles: Int
    public var maxParallelDepth: Int
    public var threads: Int
    
    public init(crossMounts: Bool = false,
                apparentSizeOnly: Bool = false,
                maxTopFiles: Int = 100,
                maxParallelDepth: Int = 3,
                threads: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.crossMounts = crossMounts
        self.apparentSizeOnly = apparentSizeOnly
        self.maxTopFiles = maxTopFiles
        self.maxParallelDepth = maxParallelDepth
        self.threads = max(1, threads)
    }
}

public struct ScanProgress: Sendable {
    public let filesCount: Int64
    public let dirsProcessed: Int64
    public let dirsDiscovered: Int64
    public let dirsRemaining: Int64
    public let volumeTotalFiles: Int64?
    public let bytesScanned: Int64
    public let currentPath: String
    public let elapsed: Double
    public let filesPerSecond: Double
    public let isCancelled: Bool
}

public final class DiskScanner: @unchecked Sendable {
    public let options: ScanOptions
    private let topHeap: TopFilesHeap
    private let hardLinkTracker = HardLinkTracker()
    
    private var tree: ScanTree?
    private let workQueue = WorkQueue()
    
    private let unreadableLock = NSLock()
    private var unreadablePaths: [String] = []
    
    private let skippedLock = NSLock()
    private var skippedMounts: [String] = []
    
    private let fallbackLock = NSLock()
    private var usedFallback = false
    
    private let cancelLock = NSLock()
    private var _isCancelled = false
    public var isCancelled: Bool {
        get {
            cancelLock.lock()
            defer { cancelLock.unlock() }
            return _isCancelled
        }
        set {
            cancelLock.lock()
            _isCancelled = newValue
            cancelLock.unlock()
            if newValue {
                workQueue.cancel()
            }
        }
    }
    
    public func cancel() {
        isCancelled = true
    }
    
    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
        self.topHeap = TopFilesHeap(capacity: options.maxTopFiles)
    }
    
    public func scan(path: String,
                     progress: ((ScanProgress) -> Void)? = nil) -> (root: NodeRef, stats: ScanStats) {
        let startTime = CFAbsoluteTimeGetCurrent()
        hardLinkTracker.reset()
        isCancelled = false
        unreadablePaths = []
        skippedMounts = []
        usedFallback = false
        
        let standardRoot = (path as NSString).standardizingPath
        let volumeTotalFiles = VolumeManager.volumeTotalFiles(forPath: standardRoot)
        
        var rootDev: UInt64 = 0
        var rootFileId: UInt64 = 0
        var rootAlloc: Int64 = 0
        var rootApparent: Int64 = 0
        var rootPriv: Int64 = 0
        var rootMtime: UInt32 = 0
        var rootLinks: UInt32 = 0
        var rootType: CEntryType = C_ENTRY_DIR
        
        _ = c_diskscan_stat_path(
            standardRoot,
            &rootDev,
            &rootFileId,
            &rootAlloc,
            &rootApparent,
            &rootPriv,
            &rootMtime,
            &rootLinks,
            &rootType,
            true
        )
        
        let rootName = (standardRoot == "/" ? "/" : (standardRoot as NSString).lastPathComponent)
        let rootKind: EntryKind = rootType == C_ENTRY_DIR ? .dir : .file
        
        let newTree = ScanTree(rootPath: standardRoot)
        self.tree = newTree
        newTree.setRoot(name: rootName, size: rootAlloc, frees: rootPriv, mtime: rootMtime, kind: rootKind)
        
        // Progress timer only created when a callback is provided
        var progressTimer: DispatchSourceTimer? = nil
        if let progressHandler = progress {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
            timer.schedule(deadline: .now(), repeating: .milliseconds(80))
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                let snap = self.currentProgressSnapshot(startTime: startTime, volumeTotalFiles: volumeTotalFiles)
                progressHandler(snap)
            }
            timer.resume()
            progressTimer = timer
        }
        
        if rootKind == .dir {
            // Seed work queue with root directory
            workQueue.enqueue(WorkItem(nodeIndex: 0, path: standardRoot))
            
            // Spawn worker pool
            let threadCount = options.threads
            let device = rootDev
            let group = DispatchGroup()
            
            for _ in 0..<threadCount {
                group.enter()
                DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                    defer { group.leave() }
                    self?.runWorker(tree: newTree, rootDev: device)
                }
            }
            
            group.wait()
            
            // Roll up directory sizes and counts in a single O(N) reverse pass
            newTree.rollupSizes()
        } else {
            // Single file target
            topHeap.insert(
                path: standardRoot,
                name: rootName,
                allocatedSize: rootAlloc,
                apparentSize: rootApparent,
                frees: rootPriv,
                mtime: Date(timeIntervalSince1970: TimeInterval(rootMtime))
            )
        }
        
        if let timer = progressTimer {
            timer.cancel()
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        // Final progress update
        if let progressHandler = progress {
            let finalSnap = currentProgressSnapshot(startTime: startTime, volumeTotalFiles: volumeTotalFiles)
            progressHandler(finalSnap)
        }
        
        let qStats = workQueue.stats
        var stats = ScanStats()
        stats.rootPath = standardRoot
        stats.totalFilesScanned = Int64(rootKind == .dir ? qStats.files : 1)
        stats.totalDirsScanned = Int64(rootKind == .dir ? qStats.processed : 1)
        stats.dirsDiscovered = Int64(rootKind == .dir ? qStats.discovered : 1)
        stats.totalAllocatedBytes = newTree.root.size
        stats.totalApparentBytes = newTree.root.apparentSize
        stats.totalFreesBytes = newTree.root.frees
        stats.unreadablePaths = unreadablePaths
        stats.skippedMountPoints = skippedMounts
        stats.elapsedSeconds = elapsed
        stats.usedFallback = usedFallback
        stats.isCancelled = isCancelled
        stats.volumeTotalFiles = volumeTotalFiles
        stats.topFiles = topHeap.topEntries()
        
        return (newTree.root, stats)
    }
    
    private func currentProgressSnapshot(startTime: CFAbsoluteTime, volumeTotalFiles: Int64?) -> ScanProgress {
        let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - startTime)
        let qStats = workQueue.stats
        let files = Int64(qStats.files)
        let rate = Double(files) / elapsed
        let remaining = max(0, Int64(qStats.discovered - qStats.processed))
        
        return ScanProgress(
            filesCount: files,
            dirsProcessed: Int64(qStats.processed),
            dirsDiscovered: Int64(qStats.discovered),
            dirsRemaining: remaining,
            volumeTotalFiles: volumeTotalFiles,
            bytesScanned: qStats.bytes,
            currentPath: qStats.currentPath,
            elapsed: elapsed,
            filesPerSecond: rate,
            isCancelled: isCancelled
        )
    }
    
    private func runWorker(tree: ScanTree, rootDev: UInt64) {
        while let item = workQueue.pop() {
            if isCancelled { break }
            processDirectory(tree: tree, item: item, rootDev: rootDev)
        }
    }
    
    private func processDirectory(tree: ScanTree, item: WorkItem, rootDev: UInt64) {
        var listing = CDirListing()
        let ret = c_diskscan_read_dir(item.path, &listing)
        if ret != 0 {
            unreadableLock.lock()
            unreadablePaths.append(item.path)
            unreadableLock.unlock()
            tree.updateEntry(at: item.nodeIndex) { $0.flags |= EntryFlags.unreadable }
            c_diskscan_free_listing(&listing)
            workQueue.finishItem(path: item.path, fileCount: 0, bytes: 0)
            return
        }
        
        if isCancelled {
            c_diskscan_free_listing(&listing)
            workQueue.finishItem(path: item.path, fileCount: 0, bytes: 0)
            return
        }
        
        if listing.used_fallback {
            fallbackLock.lock()
            usedFallback = true
            fallbackLock.unlock()
        }
        
        let count = listing.count
        guard count > 0 else {
            c_diskscan_free_listing(&listing)
            workQueue.finishItem(path: item.path, fileCount: 0, bytes: 0)
            return
        }
        
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        
        struct PendingChild {
            let relativeIndex: Int
            let path: String
        }
        var pendingSubdirs: [PendingChild] = []
        
        var localFilesCount: Int = 0
        var localAllocBytes: Int64 = 0
        
        let parentPath = item.path
        let dirDev = listing.dir_dev
        
        for i in 0..<count {
            if isCancelled { break }
            
            let cEntry = listing.entries[i]
            let namePtr = listing.name_pool + Int(cEntry.name_offset)
            let nameStr = String(cString: namePtr)
            
            let childPath = parentPath == "/" ? "/\(nameStr)" : "\(parentPath)/\(nameStr)"
            
            if cEntry.entry_type == UInt8(C_ENTRY_DIR.rawValue) {
                // Mount and firmlink filtering
                if !options.crossMounts {
                    if childPath == "/System/Volumes" {
                        skippedLock.lock()
                        skippedMounts.append(childPath)
                        skippedLock.unlock()
                        continue
                    }
                    if childPath == "/Volumes" && parentPath == "/" {
                        skippedLock.lock()
                        skippedMounts.append(childPath)
                        skippedLock.unlock()
                        continue
                    }
                    if c_diskscan_entry_is_mountpoint(&listing.entries[i]) {
                        skippedLock.lock()
                        skippedMounts.append(childPath)
                        skippedLock.unlock()
                        continue
                    }
                }
                
                var flags: UInt8 = 0
                if c_diskscan_entry_is_firmlink(&listing.entries[i]) {
                    flags |= EntryFlags.firmlink
                }
                if c_diskscan_entry_is_mountpoint(&listing.entries[i]) {
                    flags |= EntryFlags.mountpoint
                }
                
                let relIdx = entries.count
                let entry = Entry(
                    size: 0,
                    frees: 0,
                    mtime: cEntry.mtime,
                    parent: item.nodeIndex,
                    firstChild: UInt32.max,
                    childCount: 0,
                    nameOffset: cEntry.name_offset,
                    fileCount: 0,
                    dirCount: 0,
                    nameLen: cEntry.name_len,
                    kind: EntryKind.dir.rawValue,
                    flags: flags
                )
                entries.append(entry)
                pendingSubdirs.append(PendingChild(relativeIndex: relIdx, path: childPath))
            } else {
                var alloc = cEntry.alloc_size
                var priv = cEntry.private_size
                var flags: UInt8 = 0
                
                if cEntry.link_count > 1 {
                    let isFirst = hardLinkTracker.insertIfFirstTime(dev: dirDev, ino: cEntry.file_id)
                    if !isFirst {
                        alloc = 0
                        priv = 0
                        flags |= EntryFlags.hardlinkDup
                    }
                }
                
                if c_diskscan_entry_is_dataless(&listing.entries[i]) {
                    flags |= EntryFlags.dataless
                    alloc = 0
                    priv = 0
                }
                
                let kind: EntryKind
                switch cEntry.entry_type {
                case UInt8(C_ENTRY_FILE.rawValue): kind = .file
                case UInt8(C_ENTRY_SYMLINK.rawValue): kind = .symlink
                default: kind = .other
                }
                
                let entry = Entry(
                    size: alloc,
                    frees: priv,
                    mtime: cEntry.mtime,
                    parent: item.nodeIndex,
                    firstChild: UInt32.max,
                    childCount: 0,
                    nameOffset: cEntry.name_offset,
                    fileCount: 1,
                    dirCount: 0,
                    nameLen: cEntry.name_len,
                    kind: kind.rawValue,
                    flags: flags
                )
                entries.append(entry)
                
                localFilesCount += 1
                localAllocBytes += alloc
                
                if kind == .file && alloc > 0 {
                    topHeap.insert(
                        path: childPath,
                        name: nameStr,
                        allocatedSize: alloc,
                        apparentSize: cEntry.apparent_size,
                        frees: priv,
                        mtime: Date(timeIntervalSince1970: TimeInterval(cEntry.mtime))
                    )
                }
            }
        }
        
        var nameBytes: [UInt8] = []
        if listing.name_pool_len > 0 && listing.name_pool != nil {
            nameBytes = Array(UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(listing.name_pool)),
                                                  count: listing.name_pool_len))
        }
        
        c_diskscan_free_listing(&listing)
        
        if !entries.isEmpty && !isCancelled {
            let (entryBase, _) = tree.appendBatch(entries: entries, namesBuffer: nameBytes)
            tree.updateEntry(at: item.nodeIndex) {
                $0.firstChild = entryBase
                $0.childCount = UInt32(entries.count)
            }
            
            // Queue pending subdirectories
            if !pendingSubdirs.isEmpty {
                let workItems = pendingSubdirs.map {
                    WorkItem(nodeIndex: entryBase + UInt32($0.relativeIndex), path: $0.path)
                }
                workQueue.enqueueBatch(workItems)
            }
        }
        
        workQueue.finishItem(path: item.path, fileCount: localFilesCount, bytes: localAllocBytes)
    }
}
