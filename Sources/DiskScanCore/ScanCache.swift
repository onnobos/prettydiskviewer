import Foundation
import CryptoKit

public final class ScanCache: @unchecked Sendable {
    public static let shared = ScanCache()
    
    private let cacheDir: URL
    private let magic: UInt32 = 0x44565343 // "DVSC"
    private let version: UInt32 = 2
    
    public init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/tmp")
        self.cacheDir = base.appendingPathComponent("dv")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
    
    private func cacheURL(for rootPath: String) -> URL {
        let standard = (rootPath as NSString).standardizingPath
        let hash = SHA256.hash(data: Data(standard.utf8))
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(hashString).dvscan")
    }
    
    public func cacheInfo(for rootPath: String) -> (exists: Bool, ageSeconds: Double?, fileURL: URL) {
        let url = cacheURL(for: rootPath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return (false, nil, url)
        }
        let age = Date().timeIntervalSince(modDate)
        return (true, age, url)
    }
    
    public func save(tree: ScanTree) -> Bool {
        let url = cacheURL(for: tree.rootPath)
        let tmpUrl = url.appendingPathExtension("tmp")
        
        let entries = tree.entriesRaw
        let names = tree.namesRaw
        
        var header = [UInt8](repeating: 0, count: 64)
        
        // Write magic and version
        var m = magic.bigEndian
        withUnsafeBytes(of: &m) { header.replaceSubrange(0..<4, with: $0) }
        var v = version.bigEndian
        withUnsafeBytes(of: &v) { header.replaceSubrange(4..<8, with: $0) }
        
        // Timestamp
        var ts = UInt64(Date().timeIntervalSince1970).bigEndian
        withUnsafeBytes(of: &ts) { header.replaceSubrange(8..<16, with: $0) }
        
        // Entry count
        var ec = UInt32(entries.count).bigEndian
        withUnsafeBytes(of: &ec) { header.replaceSubrange(16..<20, with: $0) }
        
        // Name bytes count
        var nc = UInt32(names.count).bigEndian
        withUnsafeBytes(of: &nc) { header.replaceSubrange(20..<24, with: $0) }
        
        var data = Data(header)
        
        entries.withUnsafeBytes { ptr in
            data.append(contentsOf: ptr)
        }
        
        names.withUnsafeBytes { ptr in
            data.append(contentsOf: ptr)
        }
        
        do {
            try data.write(to: tmpUrl, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmpUrl, to: url)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmpUrl)
            return false
        }
    }
    
    public func load(rootPath: String) -> ScanTree? {
        let url = cacheURL(for: rootPath)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        
        guard data.count >= 64 else { return nil }
        
        let m = data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        let v = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        guard m == magic && v == version else { return nil }
        
        let entryCount = Int(data.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
        let nameCount = Int(data.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
        
        let entryStride = MemoryLayout<Entry>.stride
        let entriesByteLen = entryCount * entryStride
        let expectedTotal = 64 + entriesByteLen + nameCount
        guard data.count >= expectedTotal else { return nil }
        
        var entries = [Entry](repeating: Entry(), count: entryCount)
        entries.withUnsafeMutableBytes { ptr in
            data.copyBytes(to: ptr, from: 64..<(64 + entriesByteLen))
        }
        
        var names = [UInt8](repeating: 0, count: nameCount)
        names.withUnsafeMutableBytes { ptr in
            data.copyBytes(to: ptr, from: (64 + entriesByteLen)..<expectedTotal)
        }
        
        let standard = (rootPath as NSString).standardizingPath
        return ScanTree(rootPath: standard, entries: entries, names: names)
    }
}
