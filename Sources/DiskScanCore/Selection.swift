import Foundation

public final class SelectionManager: @unchecked Sendable {
    private let tree: ScanTree
    private var markedIndices: Set<UInt32> = []
    private let lock = NSLock()
    
    public init(tree: ScanTree) {
        self.tree = tree
    }
    
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return markedIndices.count
    }
    
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return markedIndices.isEmpty
    }
    
    public func isMarked(index: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return markedIndices.contains(index)
    }
    
    public func isMarked(node: NodeRef) -> Bool {
        isMarked(index: node.index)
    }
    
    /// Toggles mark on a node.
    /// If marking a parent, all descendants currently marked are removed to avoid double counting.
    /// If marking a node whose ancestor is already marked, the ancestor's mark is retained and child is not added.
    public func toggle(index: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        
        if markedIndices.contains(index) {
            markedIndices.remove(index)
            return
        }
        
        // Check if any ancestor is already marked
        var curr = tree.entry(at: index).parent
        while curr < UInt32(tree.count) && curr != 0 {
            if markedIndices.contains(curr) {
                // Ancestor already marked; no need to mark child
                return
            }
            let p = tree.entry(at: curr).parent
            if p == curr { break }
            curr = p
        }
        if curr == 0 && markedIndices.contains(0) {
            return
        }
        
        // Remove any descendants of index that were previously marked
        var toRemove: [UInt32] = []
        for m in markedIndices {
            var p = tree.entry(at: m).parent
            while p < UInt32(tree.count) {
                if p == index {
                    toRemove.append(m)
                    break
                }
                if p == 0 { break }
                let nextP = tree.entry(at: p).parent
                if nextP == p { break }
                p = nextP
            }
        }
        for r in toRemove {
            markedIndices.remove(r)
        }
        
        markedIndices.insert(index)
    }
    
    public func toggle(node: NodeRef) {
        toggle(index: node.index)
    }
    
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        markedIndices.removeAll()
    }
    
    public func markAll(nodes: [NodeRef]) {
        for n in nodes {
            if !isMarked(node: n) {
                toggle(node: n)
            }
        }
    }
    
    public var totals: (size: Int64, frees: Int64) {
        lock.lock()
        defer { lock.unlock() }
        
        var totalSize: Int64 = 0
        var totalFrees: Int64 = 0
        for idx in markedIndices {
            let entry = tree.entry(at: idx)
            totalSize += entry.size
            totalFrees += entry.frees
        }
        return (totalSize, totalFrees)
    }
    
    public var selectedNodes: [NodeRef] {
        lock.lock()
        defer { lock.unlock() }
        return markedIndices.sorted().map { NodeRef(index: $0, tree: tree) }
    }
    
    public var summary: String {
        let t = totals
        let c = count
        if c == 0 {
            return "No items marked"
        }
        return "Marked: \(c) item\(c == 1 ? "" : "s") · frees \(Format.formatBytes(t.frees))"
    }
}
