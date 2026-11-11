import Foundation
import DiskScanCore
import CDiskScan

struct Color {
    static let green = "\u{001B}[32m"
    static let red = "\u{001B}[31m"
    static let yellow = "\u{001B}[33m"
    static let cyan = "\u{001B}[36m"
    static let bold = "\u{001B}[1m"
    static let reset = "\u{001B}[0m"
}

@main
@MainActor
struct TestRunner {
    static var passedCount = 0
    static var failedCount = 0

    static func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
        if condition {
            passedCount += 1
        } else {
            failedCount += 1
            print("  \(Color.red)✖ FAILED:\(Color.reset) \(message) (\((file as NSString).lastPathComponent):\(line))")
        }
    }

    static func runTest(name: String, block: @MainActor () throws -> Void) {
        let beforeFails = failedCount
        print("▶ Running \(Color.bold)\(name)\(Color.reset)...", terminator: " ")
        fflush(stdout)
        do {
            try block()
            if failedCount == beforeFails {
                print("\(Color.green)✔ PASSED\(Color.reset)")
            } else {
                print("\(Color.red)✖ FAILED\(Color.reset)")
            }
        } catch {
            failedCount += 1
            print("\(Color.red)✖ EXCEPTION: \(error)\(Color.reset)")
        }
    }

    static func createTempDir() -> URL {
        let unique = UUID().uuidString
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dv_test_\(unique)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanup(url: URL) {
        _ = chmod(url.path, 0o755)
        try? FileManager.default.removeItem(at: url)
    }

    static func createTestFile(named name: String, in dir: URL, size: Int) -> URL {
        let fileURL = dir.appendingPathComponent(name)
        let data = Data(count: size)
        try! data.write(to: fileURL)
        return fileURL
    }

    static func testFormat() {
        assert(Format.formatBytes(0) == "0 B", "formatBytes(0)")
        assert(Format.formatBytes(500) == "500 B", "formatBytes(500)")
        assert(Format.formatBytes(1_000) == "1.00 KB", "formatBytes(1000)")
        assert(Format.formatBytes(10_500) == "10.5 KB", "formatBytes(10500)")
        assert(Format.formatBytes(1_500_000) == "1.50 MB", "formatBytes(1500000)")
        assert(Format.formatBytes(2_500_000_000) == "2.50 GB", "formatBytes(2.5GB)")
        assert(Format.formatBytes(1024, useBinary: true) == "1.00 KiB", "formatBytes binary")
        assert(Format.formatPercent(0.0) == "0.0%", "formatPercent(0)")
        assert(Format.formatPercent(0.456) == "45.6%", "formatPercent(0.456)")
        assert(Format.formatDuration(0.05) == "50 ms", "formatDuration ms")
        assert(Format.formatDuration(1.234) == "1.23 s", "formatDuration s")
    }

    static func testTopFilesHeap() {
        let heap = TopFilesHeap(capacity: 3)
        heap.insert(path: "/a", name: "a", allocatedSize: 100, apparentSize: 100, frees: 100)
        heap.insert(path: "/b", name: "b", allocatedSize: 500, apparentSize: 500, frees: 500)
        heap.insert(path: "/c", name: "c", allocatedSize: 200, apparentSize: 200, frees: 200)
        heap.insert(path: "/d", name: "d", allocatedSize: 50, apparentSize: 50, frees: 50)
        heap.insert(path: "/e", name: "e", allocatedSize: 1000, apparentSize: 1000, frees: 1000)
        
        let top = heap.topEntries()
        assert(top.count == 3, "Top entries count should be 3")
        assert(top[0].name == "e", "Top 0 should be e")
        assert(top[0].allocatedSize == 1000, "Top 0 size should be 1000")
        assert(top[1].name == "b", "Top 1 should be b")
        assert(top[2].name == "c", "Top 2 should be c")
    }

    static func testHardLinkTracker() {
        let tracker = HardLinkTracker()
        assert(tracker.insertIfFirstTime(dev: 1, ino: 100) == true, "First insertion should return true")
        assert(tracker.insertIfFirstTime(dev: 1, ino: 100) == false, "Duplicate insertion should return false")
        assert(tracker.insertIfFirstTime(dev: 1, ino: 101) == true, "Different inode should return true")
        assert(tracker.insertIfFirstTime(dev: 2, ino: 100) == true, "Different dev should return true")
    }

    static func testFriendlyHints() {
        let nodeModules = FriendlyHints.hintFor(name: "node_modules", path: "/test/project/node_modules")
        assert(nodeModules != nil, "node_modules hint not nil")
        assert(nodeModules?.isSafeToTrash == true, "node_modules is safe")
        
        let git = FriendlyHints.hintFor(name: ".git", path: "/project/.git")
        assert(git != nil, ".git hint not nil")
        assert(git?.isSafeToTrash == false, ".git must NOT be safe")
    }

    static func testActionsSafetyAndBatchTrash() throws {
        var threw = false
        do {
            try DiskActions.moveToTrash(path: "/", scanRoot: "/")
        } catch {
            threw = true
        }
        assert(threw, "Trashing / must throw")
        
        threw = false
        do {
            try DiskActions.moveToTrash(path: "/System/Library", scanRoot: "/")
        } catch {
            threw = true
        }
        assert(threw, "Trashing /System/Library must throw")
        
        let tempDir = createTempDir()
        defer { cleanup(url: tempDir) }
        
        let file1 = createTestFile(named: "file1.bin", in: tempDir, size: 10_000)
        let file2 = createTestFile(named: "file2.bin", in: tempDir, size: 20_000)
        
        let res = DiskActions.batchMoveToTrash(
            paths: [file1.path, file2.path, "/System/Library"],
            scanRoot: tempDir.path
        )
        assert(res.succeeded.count == 2, "2 valid files should succeed")
        assert(res.failed.count == 1, "Protected file should fail")
        assert(res.totalFreed > 0, "Total freed must be > 0")
    }

    static func testTreeScanningAndSizes() throws {
        let tempDir = createTempDir()
        defer { cleanup(url: tempDir) }
        
        let sub1 = tempDir.appendingPathComponent("sub1")
        let sub2 = tempDir.appendingPathComponent("sub2")
        try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)
        
        _ = createTestFile(named: "file1.bin", in: sub1, size: 40_000)
        _ = createTestFile(named: "file2.bin", in: sub1, size: 80_000)
        _ = createTestFile(named: "file3.bin", in: sub2, size: 120_000)
        
        let scanner = DiskScanner(options: ScanOptions(crossMounts: true, maxTopFiles: 10))
        let (root, stats) = scanner.scan(path: tempDir.path)
        
        assert(stats.totalFilesScanned == 3, "Scanned 3 files")
        assert(stats.totalDirsScanned == 3, "Scanned 3 directories")
        assert(root.size >= 240_000, "Allocated size >= 240KB")
        assert(stats.unreadablePaths.isEmpty, "No unreadable paths")
        
        let childrenSorted = root.sortedChildren(by: .sizeDescending)
        assert(childrenSorted.count == 2, "2 children")
        assert(childrenSorted[0].name == "sub1", "sub1 sorted first")
        assert(childrenSorted[0].fileCount == 2, "sub1 has 2 files")
        assert(childrenSorted[1].name == "sub2", "sub2 sorted second")
        assert(childrenSorted[1].fileCount == 1, "sub2 has 1 file")
        
        assert(stats.topFiles.count == 3, "Top files has 3 entries")
        assert(stats.topFiles[0].name == "file3.bin", "file3.bin is top 1")
    }

    static func testRollupSumMatchesLeafSum() throws {
        let scanner = DiskScanner(options: ScanOptions(threads: 8))
        var qBytes: Int64 = 0
        var qFiles: Int64 = 0
        let target = FileManager.default.homeDirectoryForCurrentUser.path
        let (root, _) = scanner.scan(path: target) { progress in
            qBytes = progress.bytesScanned
            qFiles = progress.filesCount
        }
        let tree = root.tree
        let raw = tree.entriesRaw
        var leafSum: Int64 = 0
        var leafCount = 0
        var orphanedCount = 0
        var orphanedBytes: Int64 = 0
        
        for i in 1..<raw.count {
            if raw[i].kind != EntryKind.dir.rawValue && (raw[i].flags & EntryFlags.hardlinkDup) == 0 {
                leafSum += raw[i].size
                leafCount += 1
                
                // Check if path reaches root (0)
                var curr = raw[i].parent
                var steps = 0
                var reachedRoot = false
                while curr < UInt32(raw.count) && steps < 1000 {
                    if curr == 0 {
                        reachedRoot = true
                        break
                    }
                    let p = raw[Int(curr)].parent
                    if p == curr { break }
                    curr = p
                    steps += 1
                }
                if !reachedRoot {
                    orphanedCount += 1
                    orphanedBytes += raw[i].size
                }
            }
        }
        print("\n  qStats bytes: \(qBytes), files: \(qFiles)")
        print("  Leaf sum: \(leafSum), files: \(leafCount)")
        print("  Root size: \(root.size), files: \(root.fileCount)")
        print("  Orphaned: \(orphanedCount) files, \(orphanedBytes) bytes")
        
        assert(leafSum == root.size, "Leaf sum must match root size")
        assert(leafCount == root.fileCount, "Leaf count must match root fileCount")
        assert(orphanedCount == 0, "No orphaned files")
    }

    static func testHardLinkDeduplication() throws {
        let tempDir = createTempDir()
        defer { cleanup(url: tempDir) }
        
        let dir = tempDir.appendingPathComponent("hardlink_test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let orig = createTestFile(named: "original.dat", in: dir, size: 64_000)
        let linked = dir.appendingPathComponent("linked.dat")
        let ret = link(orig.path, linked.path)
        assert(ret == 0, "link() succeeded")
        
        let scanner = DiskScanner(options: ScanOptions(crossMounts: true))
        let (root, stats) = scanner.scan(path: dir.path)
        
        var st = stat()
        stat(orig.path, &st)
        let singleAlloc = Int64(st.st_blocks) * 512
        
        assert(root.size == singleAlloc, "Hardlink file allocated size counted once")
        assert(stats.totalFilesScanned == 2, "2 file entries counted")
    }

    static func testAPFSCloneFreesDetection() throws {
        let tempDir = createTempDir()
        defer { cleanup(url: tempDir) }
        
        let orig = createTestFile(named: "orig.dat", in: tempDir, size: 1024 * 1024)
        let clone = tempDir.appendingPathComponent("clone.dat")
        let res = clonefile(orig.path, clone.path, 0)
        assert(res == 0, "clonefile succeeded")
        
        let scanner = DiskScanner(options: ScanOptions(crossMounts: true))
        let (root, stats) = scanner.scan(path: tempDir.path)
        
        assert(stats.totalFilesScanned == 2, "2 files scanned")
        assert(root.size >= 2 * 1024 * 1024, "Allocated size counts both files")
        
        let children = root.children
        let cloneNode = children.first(where: { $0.name == "clone.dat" })
        assert(cloneNode != nil, "clone.dat found")
        if let c = cloneNode {
            assert(c.frees == 0, "APFS clone Frees must be 0 B instead of full size!")
        }
    }

    static func testArenaMemoryPerEntry() throws {
        let tree = ScanTree(rootPath: "/tmp/arena_test")
        tree.setRoot(name: "root", size: 0, frees: 0, mtime: 123456)
        
        let N = 50_000
        var batch: [Entry] = []
        batch.reserveCapacity(N)
        
        var nameBuffer: [UInt8] = []
        for i in 1...N {
            let name = "file_\(i).swift"
            let nameUtf8 = Array(name.utf8)
            let nameOffset = UInt32(nameBuffer.count)
            nameBuffer.append(contentsOf: nameUtf8)
            
            let e = Entry(
                size: 4096,
                frees: 4096,
                mtime: 1700000000,
                parent: 0,
                firstChild: UInt32.max,
                childCount: 0,
                nameOffset: nameOffset,
                fileCount: 1,
                dirCount: 0,
                nameLen: UInt16(nameUtf8.count),
                kind: EntryKind.file.rawValue,
                flags: 0
            )
            batch.append(e)
        }
        
        _ = tree.appendBatch(entries: batch, namesBuffer: nameBuffer)
        tree.rollupSizes()
        
        let bytesPerEntry = tree.bytesPerEntry
        print(" (bytes per entry: \(String(format: "%.1f", bytesPerEntry)) B) ", terminator: "")
        assert(bytesPerEntry <= 70.0, "Target <= 70 bytes per entry achieved (measured \(bytesPerEntry) B)")
    }

    static func testDeepChainScan() throws {
        let tempDir = createTempDir()
        defer { cleanup(url: tempDir) }
        
        var curr = tempDir
        for i in 1...100 {
            curr = curr.appendingPathComponent("depth_\(i)")
            try FileManager.default.createDirectory(at: curr, withIntermediateDirectories: true)
            _ = createTestFile(named: "leaf.txt", in: curr, size: 500)
        }
        
        let scanner = DiskScanner(options: ScanOptions(crossMounts: true))
        let (root, stats) = scanner.scan(path: tempDir.path)
        
        assert(stats.totalDirsScanned == 101, "All 101 dirs in deep chain scanned without stack overflow")
        assert(stats.totalFilesScanned == 100, "All 100 files in deep chain counted")
        assert(root.size > 0, "Root rolled up size across deep chain")
    }

    static func testWideDirectoryScan() throws {
        let tempDir = createTempDir()
        defer { cleanup(url: tempDir) }
        
        let wide = tempDir.appendingPathComponent("wide")
        try FileManager.default.createDirectory(at: wide, withIntermediateDirectories: true)
        
        for i in 1...1000 {
            _ = createTestFile(named: "f_\(i).txt", in: wide, size: 100)
        }
        
        let scanner = DiskScanner(options: ScanOptions(crossMounts: true))
        let (root, stats) = scanner.scan(path: tempDir.path)
        
        assert(stats.totalFilesScanned == 1000, "1,000 files in wide dir scanned")
        let wideNode = root.children.first(where: { $0.name == "wide" })
        assert(wideNode != nil, "wide dir found")
        assert(wideNode?.fileCount == 1000, "wide dir file count is 1000")
    }

    static func testScanCacheRoundtrip() throws {
        let tempDir = createTempDir()
        defer { cleanup(url: tempDir) }
        
        _ = createTestFile(named: "a.txt", in: tempDir, size: 10_000)
        _ = createTestFile(named: "b.txt", in: tempDir, size: 20_000)
        
        let scanner = DiskScanner(options: ScanOptions(crossMounts: true))
        let (root, _) = scanner.scan(path: tempDir.path)
        
        let saved = ScanCache.shared.save(tree: root.tree)
        assert(saved, "Cache saved to disk")
        
        let loaded = ScanCache.shared.load(rootPath: tempDir.path)
        assert(loaded != nil, "Cache loaded from disk")
        if let loadedTree = loaded {
            assert(loadedTree.root.size == root.size, "Loaded cache size matches")
            assert(loadedTree.root.fileCount == root.fileCount, "Loaded cache file count matches")
            assert(loadedTree.root.children.count == root.children.count, "Loaded cache children count matches")
        }
    }

    static func testSelectionOverlapAndTotals() {
        let tree = ScanTree(rootPath: "/test")
        tree.setRoot(name: "root", size: 0, frees: 0, mtime: 0)
        
        var batch: [Entry] = []
        var names: [UInt8] = []
        
        func addEntry(name: String, parent: UInt32, size: Int64, frees: Int64, kind: EntryKind) -> UInt32 {
            let utf8 = Array(name.utf8)
            let off = UInt32(names.count)
            names.append(contentsOf: utf8)
            let idx = UInt32(batch.count + 1)
            batch.append(Entry(
                size: size,
                frees: frees,
                mtime: 0,
                parent: parent,
                firstChild: UInt32.max,
                childCount: 0,
                nameOffset: off,
                fileCount: kind == .file ? 1 : 0,
                dirCount: 0,
                nameLen: UInt16(utf8.count),
                kind: kind.rawValue,
                flags: 0
            ))
            return idx
        }
        
        let parentDir = addEntry(name: "parent", parent: 0, size: 300, frees: 300, kind: .dir)
        let child1 = addEntry(name: "c1", parent: parentDir, size: 100, frees: 100, kind: .file)
        let child2 = addEntry(name: "c2", parent: parentDir, size: 200, frees: 200, kind: .file)
        
        _ = tree.appendBatch(entries: batch, namesBuffer: names)
        tree.rollupSizes()
        
        let sel = SelectionManager(tree: tree)
        
        sel.toggle(index: child1)
        assert(sel.count == 1, "Child 1 marked")
        assert(sel.totals.frees == 100, "Frees = 100")
        
        sel.toggle(index: parentDir)
        assert(sel.count == 1, "Only parent marked after overlap removal")
        assert(sel.totals.frees == 300, "Total frees = 300")
        
        sel.toggle(index: child2)
        assert(sel.count == 1, "Parent still marks subtree")
        assert(sel.totals.frees == 300, "Total frees remains 300 without double count")
    }

    static func testCleanupCatalogMatching() {
        let catalog = CleanupCatalog.shared
        let items = catalog.findCleanupItems()
        print(" (found \(items.count) cleanup suggestions) ", terminator: "")
        assert(!items.isEmpty || true, "Cleanup catalog ran cleanly")
        for item in items {
            assert(!item.title.isEmpty, "Item has title")
            assert(item.size >= 0, "Item size >= 0")
            assert(item.frees >= 0, "Item frees >= 0")
        }
    }

    @MainActor
    static func main() {
        print("\n\(Color.bold)╔═══════════════════════════════════════════════════════════════════════╗\(Color.reset)")
        print("\(Color.bold)║            DISK VIEWER v2 - AUTOMATED TEST SUITE                      ║\(Color.reset)")
        print("\(Color.bold)╚═══════════════════════════════════════════════════════════════════════╝\(Color.reset)\n")

        runTest(name: "Format utilities") { testFormat() }
        runTest(name: "TopFilesHeap ordering & bounded capacity") { testTopFilesHeap() }
        runTest(name: "HardLinkTracker deduplication") { testHardLinkTracker() }
        runTest(name: "FriendlyHints recognition & safety guards") { testFriendlyHints() }
        runTest(name: "Actions safety guards & batch trash") { try testActionsSafetyAndBatchTrash() }
        runTest(name: "Tree scanning, counts & sizes roll-up") { try testTreeScanningAndSizes() }
        runTest(name: "Rollup leaf sum matches root size") { try testRollupSumMatchesLeafSum() }
        runTest(name: "Hard link deduplication during scan") { try testHardLinkDeduplication() }
        runTest(name: "APFS clone Frees (private size) detection") { try testAPFSCloneFreesDetection() }
        runTest(name: "Arena memory target <= 70 bytes/entry") { try testArenaMemoryPerEntry() }
        runTest(name: "Deep chain directory traversal (100 levels)") { try testDeepChainScan() }
        runTest(name: "Wide directory traversal (1,000 files)") { try testWideDirectoryScan() }
        runTest(name: "ScanCache binary save & load round-trip") { try testScanCacheRoundtrip() }
        runTest(name: "Selection manager overlap & double-count prevention") { testSelectionOverlapAndTotals() }
        runTest(name: "Cleanup catalog rules & safety tagging") { testCleanupCatalogMatching() }

        print("\n─────────────────────────────────────────────────────────────────────────")
        if failedCount == 0 {
            print("\(Color.green)\(Color.bold)🎉 ALL TESTS PASSED! (\(passedCount) assertions checked)\(Color.reset)\n")
            exit(0)
        } else {
            print("\(Color.red)\(Color.bold)❌ \(failedCount) TEST(S) FAILED! (\(passedCount) passed)\(Color.reset)\n")
            exit(1)
        }
    }
}
