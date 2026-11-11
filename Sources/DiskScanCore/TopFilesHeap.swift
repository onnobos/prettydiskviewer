import Foundation

public final class TopFilesHeap: @unchecked Sendable {
    private let capacity: Int
    private var heap: [BigFileEntry] = []
    private let lock = NSLock()
    
    public init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
        self.heap.reserveCapacity(self.capacity)
    }
    
    public func insert(path: String,
                       name: String,
                       allocatedSize: Int64,
                       apparentSize: Int64,
                       frees: Int64 = 0,
                       mtime: Date = Date()) {
        guard allocatedSize > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        
        let entry = BigFileEntry(
            path: path,
            name: name,
            allocatedSize: allocatedSize,
            apparentSize: apparentSize,
            frees: frees > 0 ? frees : allocatedSize,
            mtime: mtime
        )
        if heap.count < capacity {
            heap.append(entry)
            siftUp(heap.count - 1)
        } else if entry.allocatedSize > heap[0].allocatedSize {
            heap[0] = entry
            siftDown(0)
        }
    }
    
    /// Returns the top entries sorted descending by allocatedSize
    public func topEntries() -> [BigFileEntry] {
        lock.lock()
        defer { lock.unlock() }
        return heap.sorted {
            if $0.allocatedSize != $1.allocatedSize {
                return $0.allocatedSize > $1.allocatedSize
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    
    private func siftUp(_ index: Int) {
        var child = index
        var parent = (child - 1) / 2
        while child > 0 && heap[child].allocatedSize < heap[parent].allocatedSize {
            heap.swapAt(child, parent)
            child = parent
            parent = (child - 1) / 2
        }
    }
    
    private func siftDown(_ index: Int) {
        var parent = index
        let count = heap.count
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var candidate = parent
            
            if left < count && heap[left].allocatedSize < heap[candidate].allocatedSize {
                candidate = left
            }
            if right < count && heap[right].allocatedSize < heap[candidate].allocatedSize {
                candidate = right
            }
            if candidate == parent {
                break
            }
            heap.swapAt(parent, candidate)
            parent = candidate
        }
    }
}
