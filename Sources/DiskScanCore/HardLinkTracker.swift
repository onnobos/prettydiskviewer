import Foundation

public struct InodeKey: Hashable, Sendable {
    public let dev: UInt64
    public let ino: UInt64
    
    public init(dev: UInt64, ino: UInt64) {
        self.dev = dev
        self.ino = ino
    }
}

public final class HardLinkTracker: @unchecked Sendable {
    private final class Shard {
        var set: Set<InodeKey> = []
        let lock = NSLock()
    }
    
    private let shardCount = 64
    private let shards: [Shard]
    
    public init() {
        var s: [Shard] = []
        s.reserveCapacity(64)
        for _ in 0..<64 {
            s.append(Shard())
        }
        self.shards = s
    }
    
    /// Returns true if this inode is seen for the first time; false if it was already recorded
    public func insertIfFirstTime(dev: UInt64, ino: UInt64) -> Bool {
        let index = Int(ino % UInt64(shardCount))
        let shard = shards[index]
        shard.lock.lock()
        defer { shard.lock.unlock() }
        
        let key = InodeKey(dev: dev, ino: ino)
        if shard.set.contains(key) {
            return false
        }
        shard.set.insert(key)
        return true
    }
    
    public func reset() {
        for shard in shards {
            shard.lock.lock()
            shard.set.removeAll(keepingCapacity: false)
            shard.lock.unlock()
        }
    }
}
