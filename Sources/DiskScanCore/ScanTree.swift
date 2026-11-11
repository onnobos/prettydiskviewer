import Foundation

public enum EntryKind: UInt8, Sendable {
    case unknown = 0
    case file = 1
    case dir = 2
    case symlink = 3
    case other = 4
}

public struct EntryFlags {
    public static let hardlinkDup: UInt8 = 1 << 0
    public static let mountpoint: UInt8  = 1 << 1
    public static let firmlink: UInt8    = 1 << 2
    public static let unreadable: UInt8  = 1 << 3
    public static let dataless: UInt8    = 1 << 4
    public static let trashed: UInt8     = 1 << 5
}

/// Compact 48-byte memory layout for high performance & minimal RAM
public struct Entry: Sendable {
    public var size: Int64          // 8 bytes: allocated bytes on disk (rolled up for dirs)
    public var frees: Int64         // 8 bytes: APFS private size (rolled up for dirs)
    public var mtime: UInt32        // 4 bytes: Unix epoch seconds
    public var parent: UInt32       // 4 bytes: parent entry index
    public var firstChild: UInt32   // 4 bytes: first child index in entries (or UInt32.max)
    public var childCount: UInt32   // 4 bytes: number of direct children
    public var nameOffset: UInt32   // 4 bytes: offset in name buffer
    public var fileCount: UInt32    // 4 bytes: total file count in subtree (1 for file)
    public var dirCount: UInt32     // 4 bytes: total directory count in subtree
    public var nameLen: UInt16      // 2 bytes: length of name in bytes
    public var kind: UInt8          // 1 byte: EntryKind rawValue
    public var flags: UInt8         // 1 byte: EntryFlags bitmask

    public init(size: Int64 = 0,
                frees: Int64 = 0,
                mtime: UInt32 = 0,
                parent: UInt32 = UInt32.max,
                firstChild: UInt32 = UInt32.max,
                childCount: UInt32 = 0,
                nameOffset: UInt32 = 0,
                fileCount: UInt32 = 0,
                dirCount: UInt32 = 0,
                nameLen: UInt16 = 0,
                kind: UInt8 = 0,
                flags: UInt8 = 0) {
        self.size = size
        self.frees = frees
        self.mtime = mtime
        self.parent = parent
        self.firstChild = firstChild
        self.childCount = childCount
        self.nameOffset = nameOffset
        self.fileCount = fileCount
        self.dirCount = dirCount
        self.nameLen = nameLen
        self.kind = kind
        self.flags = flags
    }
}

/// A compact, contiguous arena tree that supports parallel appends and O(N) post-order rollups.
public final class ScanTree: @unchecked Sendable {
    public let rootPath: String
    private var _entries: [Entry]
    private var _names: [UInt8]
    private let lock = NSLock()

    public init(rootPath: String, entryCapacity: Int = 1024, nameCapacity: Int = 16384) {
        self.rootPath = rootPath
        self._entries = []
        self._entries.reserveCapacity(entryCapacity)
        self._names = []
        self._names.reserveCapacity(nameCapacity)
    }

    public init(rootPath: String, entries: [Entry], names: [UInt8]) {
        self.rootPath = rootPath
        self._entries = entries
        self._names = names
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _entries.count
    }

    public var nameArenaSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return _names.count
    }

    public var entriesRaw: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    public var namesRaw: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return _names
    }

    public func entry(at index: UInt32) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        return _entries[Int(index)]
    }

    public func updateEntry(at index: UInt32, transform: (inout Entry) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        transform(&_entries[Int(index)])
    }

    /// Thread-safe allocation of a batch of entries and name space
    public func appendBatch(entries batch: [Entry], namesBuffer: [UInt8]) -> (entryBase: UInt32, nameBase: UInt32) {
        lock.lock()
        defer { lock.unlock() }

        let entryBase = UInt32(_entries.count)
        let nameBase = UInt32(_names.count)

        _names.append(contentsOf: namesBuffer)

        var adjustedBatch = batch
        for i in 0..<adjustedBatch.count {
            adjustedBatch[i].nameOffset += nameBase
        }
        _entries.append(contentsOf: adjustedBatch)

        return (entryBase, nameBase)
    }

    /// Set root node (index 0)
    public func setRoot(name: String, size: Int64, frees: Int64, mtime: UInt32, kind: EntryKind = .dir) {
        lock.lock()
        defer { lock.unlock() }

        let utf8 = Array(name.utf8)
        let nameOffset = UInt32(_names.count)
        _names.append(contentsOf: utf8)

        let rootEntry = Entry(
            size: size,
            frees: frees,
            mtime: mtime,
            parent: 0,
            firstChild: UInt32.max,
            childCount: 0,
            nameOffset: nameOffset,
            fileCount: 0,
            dirCount: 0,
            nameLen: UInt16(utf8.count),
            kind: kind.rawValue,
            flags: 0
        )

        if _entries.isEmpty {
            _entries.append(rootEntry)
        } else {
            _entries[0] = rootEntry
        }
    }

    /// Linear O(N) reverse post-order size and count roll-up pass.
    /// Because parents are always created before children, `parent(i) < i` for all i > 0.
    /// Thus iterating in reverse guarantees visiting all descendants before their ancestors!
    public func rollupSizes() {
        lock.lock()
        defer { lock.unlock() }

        guard _entries.count > 1 else { return }

        // First pass: clear directory size/frees/fileCount/dirCount so roll-up is idempotent
        for i in 0..<_entries.count {
            if _entries[i].kind == EntryKind.dir.rawValue {
                _entries[i].size = 0
                _entries[i].frees = 0
                _entries[i].fileCount = 0
                _entries[i].dirCount = 0
            } else {
                _entries[i].fileCount = 1
                _entries[i].dirCount = 0
            }
        }

        // Second pass: reverse post-order rollup
        for i in stride(from: _entries.count - 1, through: 1, by: -1) {
            let p = Int(_entries[i].parent)
            guard p < i && p >= 0 && p < _entries.count else { continue }

            let isHardlinkDup = (_entries[i].flags & EntryFlags.hardlinkDup) != 0
            let isTrashed = (_entries[i].flags & EntryFlags.trashed) != 0

            if !isHardlinkDup && !isTrashed {
                _entries[p].size += _entries[i].size
                _entries[p].frees += _entries[i].frees

                if _entries[i].kind == EntryKind.dir.rawValue {
                    _entries[p].fileCount += _entries[i].fileCount
                    _entries[p].dirCount += _entries[i].dirCount + 1
                } else {
                    _entries[p].fileCount += _entries[i].fileCount
                }
            }
        }
    }

    public func name(for index: UInt32) -> String {
        lock.lock()
        defer { lock.unlock() }

        guard Int(index) < _entries.count else { return "" }
        let entry = _entries[Int(index)]
        let start = Int(entry.nameOffset)
        let end = start + Int(entry.nameLen)
        guard start >= 0 && end <= _names.count else { return "" }
        return String(decoding: _names[start..<end], as: UTF8.self)
    }

    /// Rebuilds full path by walking parent pointers up to root (index 0).
    public func path(for index: UInt32) -> String {
        lock.lock()
        defer { lock.unlock() }

        guard Int(index) < _entries.count else { return rootPath }
        if index == 0 { return rootPath }

        var chain: [UInt32] = []
        var curr = index
        while curr > 0 && curr < UInt32(_entries.count) {
            chain.append(curr)
            let p = _entries[Int(curr)].parent
            if p == curr || p == UInt32.max { break }
            curr = p
        }

        var result = rootPath
        if result.hasSuffix("/") {
            result.removeLast()
        }

        for nodeIdx in chain.reversed() {
            let entry = _entries[Int(nodeIdx)]
            let start = Int(entry.nameOffset)
            let end = start + Int(entry.nameLen)
            if start >= 0 && end <= _names.count {
                let segment = String(decoding: _names[start..<end], as: UTF8.self)
                result += "/" + segment
            }
        }

        return result
    }

    public func children(of index: UInt32) -> [NodeRef] {
        lock.lock()
        defer { lock.unlock() }

        guard Int(index) < _entries.count else { return [] }
        let entry = _entries[Int(index)]
        guard entry.firstChild != UInt32.max && entry.childCount > 0 else { return [] }

        let start = Int(entry.firstChild)
        let count = Int(entry.childCount)
        guard start >= 0 && start + count <= _entries.count else { return [] }

        return (start..<(start + count)).map { NodeRef(index: UInt32($0), tree: self) }
    }

    public func markTrashed(index: UInt32) {
        lock.lock()
        defer { lock.unlock() }

        guard Int(index) < _entries.count else { return }
        _entries[Int(index)].flags |= EntryFlags.trashed

        // Roll up removal of size/frees from ancestors
        let trashedSize = _entries[Int(index)].size
        let trashedFrees = _entries[Int(index)].frees
        let isDir = _entries[Int(index)].kind == EntryKind.dir.rawValue
        let trashedFiles = _entries[Int(index)].fileCount

        var curr = _entries[Int(index)].parent
        while curr < UInt32(_entries.count) {
            _entries[Int(curr)].size = max(0, _entries[Int(curr)].size - trashedSize)
            _entries[Int(curr)].frees = max(0, _entries[Int(curr)].frees - trashedFrees)
            _entries[Int(curr)].fileCount = max(0, _entries[Int(curr)].fileCount - trashedFiles)
            if isDir {
                _entries[Int(curr)].dirCount = max(0, _entries[Int(curr)].dirCount - 1)
            }
            if curr == 0 { break }
            curr = _entries[Int(curr)].parent
        }
    }

    public var root: NodeRef {
        NodeRef(index: 0, tree: self)
    }

    /// Approximate memory used in bytes for entries and names
    public var memoryFootprintBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return (_entries.capacity * MemoryLayout<Entry>.stride) + _names.capacity
    }

    public var bytesPerEntry: Double {
        lock.lock()
        defer { lock.unlock() }
        guard !_entries.isEmpty else { return 0 }
        let total = (_entries.count * MemoryLayout<Entry>.stride) + _names.count
        return Double(total) / Double(_entries.count)
    }
}

/// A lightweight reference view over a node in the ScanTree.
public struct NodeRef: Sendable, Identifiable {
    public let index: UInt32
    public let tree: ScanTree

    public init(index: UInt32, tree: ScanTree) {
        self.index = index
        self.tree = tree
    }

    public var id: UInt32 { index }

    private var raw: Entry {
        tree.entry(at: index)
    }

    public var name: String {
        tree.name(for: index)
    }

    public var size: Int64 {
        raw.size
    }

    public var allocatedSize: Int64 {
        raw.size
    }

    public var apparentSize: Int64 {
        raw.size
    }

    public var frees: Int64 {
        raw.frees
    }

    public var mtime: Date {
        Date(timeIntervalSince1970: TimeInterval(raw.mtime))
    }

    public var kind: EntryKind {
        EntryKind(rawValue: raw.kind) ?? .unknown
    }

    public var itemKind: ItemKind {
        switch kind {
        case .file: return .file
        case .dir: return .directory
        case .symlink: return .symlink
        default: return .other
        }
    }

    public var isDirectory: Bool {
        kind == .dir
    }

    public var fileCount: Int {
        Int(raw.fileCount)
    }

    public var dirCount: Int {
        Int(raw.dirCount)
    }

    public var childCount: Int {
        Int(raw.childCount)
    }

    public var isTrashed: Bool {
        (raw.flags & EntryFlags.trashed) != 0
    }

    public var isHardlinkDup: Bool {
        (raw.flags & EntryFlags.hardlinkDup) != 0
    }

    public var isMountpoint: Bool {
        (raw.flags & EntryFlags.mountpoint) != 0
    }

    public var isFirmlink: Bool {
        (raw.flags & EntryFlags.firmlink) != 0
    }

    public var isUnreadable: Bool {
        (raw.flags & EntryFlags.unreadable) != 0
    }

    public var isDataless: Bool {
        (raw.flags & EntryFlags.dataless) != 0
    }

    public var path: String {
        tree.path(for: index)
    }

    public var children: [NodeRef] {
        tree.children(of: index)
    }

    public func sortedChildren(by mode: SortMode) -> [NodeRef] {
        let list = children
        switch mode {
        case .sizeDescending:
            return list.sorted { (a: NodeRef, b: NodeRef) -> Bool in
                if a.size != b.size {
                    return a.size > b.size
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .nameAscending:
            return list.sorted { (a: NodeRef, b: NodeRef) -> Bool in
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .filesCountDescending:
            return list.sorted { (a: NodeRef, b: NodeRef) -> Bool in
                if a.fileCount != b.fileCount {
                    return a.fileCount > b.fileCount
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    @discardableResult
    public func removeChild(named name: String) -> NodeRef? {
        if let child = children.first(where: { $0.name == name }) {
            tree.markTrashed(index: child.index)
            return child
        }
        return nil
    }

    public var cleanupHint: CleanupHint? {
        FriendlyHints.hintFor(name: name, path: path)
    }
}
