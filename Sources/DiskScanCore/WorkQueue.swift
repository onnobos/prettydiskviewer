import Foundation

public struct WorkItem: Sendable {
    public let nodeIndex: UInt32
    public let path: String

    public init(nodeIndex: UInt32, path: String) {
        self.nodeIndex = nodeIndex
        self.path = path
    }
}

public final class WorkQueue: @unchecked Sendable {
    private var queue: [WorkItem] = []
    private let condition = NSCondition()
    private var isTerminated = false
    private var isCancelled = false
    private var pendingCount: Int = 0

    // Stats
    private let statsLock = NSLock()
    private var _foldersDiscovered: Int = 0
    private var _foldersProcessed: Int = 0
    private var _filesProcessed: Int = 0
    private var _bytesProcessed: Int64 = 0
    private var _currentPath: String = ""

    public init() {}

    public func enqueue(_ item: WorkItem) {
        condition.lock()
        defer {
            condition.signal()
            condition.unlock()
        }

        guard !isTerminated && !isCancelled else { return }
        queue.append(item)
        pendingCount += 1
        
        statsLock.lock()
        _foldersDiscovered += 1
        statsLock.unlock()
    }

    public func enqueueBatch(_ items: [WorkItem]) {
        guard !items.isEmpty else { return }
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }

        guard !isTerminated && !isCancelled else { return }
        queue.append(contentsOf: items)
        pendingCount += items.count
        
        statsLock.lock()
        _foldersDiscovered += items.count
        statsLock.unlock()
    }

    public func pop() -> WorkItem? {
        condition.lock()
        defer { condition.unlock() }

        while queue.isEmpty && !isTerminated && !isCancelled {
            if pendingCount == 0 {
                isTerminated = true
                condition.broadcast()
                return nil
            }
            condition.wait()
        }

        if isCancelled || isTerminated || queue.isEmpty {
            return nil
        }

        return queue.removeFirst()
    }

    public func finishItem(path: String, fileCount: Int, bytes: Int64) {
        condition.lock()
        defer {
            condition.unlock()
        }

        pendingCount -= 1
        
        statsLock.lock()
        _foldersProcessed += 1
        _filesProcessed += fileCount
        _bytesProcessed += bytes
        _currentPath = path
        statsLock.unlock()

        if pendingCount == 0 && queue.isEmpty {
            isTerminated = true
            condition.broadcast()
        }
    }

    public func cancel() {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        isCancelled = true
        isTerminated = true
        queue.removeAll()
    }

    public var isDone: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isTerminated || isCancelled || (pendingCount == 0 && queue.isEmpty)
    }

    public var stats: (discovered: Int, processed: Int, files: Int, bytes: Int64, currentPath: String) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (_foldersDiscovered, _foldersProcessed, _filesProcessed, _bytesProcessed, _currentPath)
    }
}
