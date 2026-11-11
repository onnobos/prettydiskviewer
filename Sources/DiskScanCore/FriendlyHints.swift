import Foundation

public struct CleanupHint: Sendable, Equatable {
    public let tag: String
    public let message: String
    public let isSafeToTrash: Bool
    
    public init(tag: String, message: String, isSafeToTrash: Bool) {
        self.tag = tag
        self.message = message
        self.isSafeToTrash = isSafeToTrash
    }
}

public enum FriendlyHints {
    /// Inspects a name and full path to find friendly cleanup advice
    public static func hintFor(name: String, path: String) -> CleanupHint? {
        let lowerName = name.lowercased()
        let lowerPath = path.lowercased()
        
        if lowerName == "node_modules" {
            return CleanupHint(
                tag: "node_modules",
                message: "Dependency folder: safe to delete, run 'npm install' to re-create anytime",
                isSafeToTrash: true
            )
        }
        
        if lowerName == "deriveddata" || lowerPath.contains("/xcode/deriveddata") {
            return CleanupHint(
                tag: "DerivedData",
                message: "Xcode build cache: 100% safe to delete, Xcode will rebuild on next compile",
                isSafeToTrash: true
            )
        }
        
        if lowerName == "caches" || lowerPath.contains("/library/caches") {
            return CleanupHint(
                tag: "Cache",
                message: "App caches: safe to clear, apps will recreate whatever they need",
                isSafeToTrash: true
            )
        }
        
        if lowerName == ".trash" || lowerPath.hasSuffix("/.trash") {
            return CleanupHint(
                tag: "Trash",
                message: "macOS Trash: empty your Trash to permanently free this space",
                isSafeToTrash: false
            )
        }
        
        if lowerName.hasSuffix(".dmg") || lowerName.hasSuffix(".pkg") {
            return CleanupHint(
                tag: "Installer",
                message: "Installer archive: if already installed, you can trash this",
                isSafeToTrash: true
            )
        }
        
        if lowerPath.contains("docker") && (lowerName == "docker.raw" || lowerName == "data.qcow2") {
            return CleanupHint(
                tag: "Docker",
                message: "Docker disk image: clean unused images with 'docker system prune -a'",
                isSafeToTrash: false
            )
        }
        
        if lowerName == "devicesupport" || lowerPath.contains("/ios devicesupport") {
            return CleanupHint(
                tag: "iOS Symbols",
                message: "Old iOS debug symbols: Xcode can redownload these if needed",
                isSafeToTrash: true
            )
        }
        
        if lowerName == ".git" {
            return CleanupHint(
                tag: "Git Repo",
                message: "Git history: do NOT delete, or you'll lose git version tracking",
                isSafeToTrash: false
            )
        }
        
        return nil
    }
}
