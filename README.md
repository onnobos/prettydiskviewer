# 💾 Disk Viewer (`dv`)

> **Laser-fast, friendly disk usage analyzer and storage cleaner for macOS.**  
> Built in Swift 6 & C with kernel-level `getattrlistbulk`, compact arena memory architecture, and native APFS clone intelligence.

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple&style=flat-square)](https://apple.com)
[![Architecture](https://img.shields.io/badge/architecture-Apple%20Silicon%20%7C%20Intel-purple?style=flat-square)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift&style=flat-square)](https://swift.org)
[![Dependencies](https://img.shields.io/badge/dependencies-0%20external-success?style=flat-square)](#)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](#license)

```text
 ┌────────────────────────────────────────────────────────────────────────┐
 │  Welcome to macOS                                                      │
 │  ██████╗ ██╗███████╗██╗  ██╗               ▄██████▄                    │
 │  ██╔══██╗██║██╔════╝██║ ██╔╝             ▄██████████▄                  │
 │  ██║  ██║██║███████╗█████╔╝             █▀██████████▀█                 │
 │  ██║  ██║██║╚════██║██╔═██╗            █████▀▀██▀▀█████                │
 │  ██████╔╝██║███████║██║  ██╗           ████  ▌██▐  ████                │
 │  ╚═════╝ ╚═╝╚══════╝╚═╝  ╚═╝            █████  ██  █████               │
 │               CLI Version 1.0.0          █▄██████████▄█                │
 │                                           ▀██████████▀                 │
 └────────────────────────────────────────────────────────────────────────┘
```

---

## ⚡ Highlights

* **🚀 Kernel-Level Traversal (`getattrlistbulk`)**: Bypasses standard POSIX `opendir` / `readdir` / `stat` syscall overhead with bulk 256 KB kernel buffers. Traverses **100,000+ files per second** on Apple Silicon—scanning an entire 2.5-million-file Mac in ~15–30 seconds.
* **🧠 Ultra-Low Memory Arena (`ScanTree`)**: Uses a compact 48-byte fixed-size `Entry` struct with a unified contiguous name pool. Consumes **<64 bytes per file entry** (~160 MB RAM for 2.5 million files vs. 1–2 GB in Python/Go/Rust tools).
* **💽 Transparent APFS Accounting**: Solves the classic macOS storage puzzle where Finder reports *"873 GB Used"* but directory trees only show *"306 GB"*. Directly accounts for **APFS Time Machine local snapshots**, purgeable storage, system containers, and volume group firmlinks.
* **🧬 APFS Clone Awareness (`frees`)**: Tracks `ATTR_CMNEXT_PRIVATESIZE` to differentiate apparent file size from Copy-on-Write (CoW) cloned blocks. Shows how much physical disk space deleting a file will *actually* reclaim.
* **🧹 Smart Cleanup Recommendations (Tab 4)**: Automatically identifies Xcode DerivedData, iOS DeviceSupport, package manager caches (npm, yarn, pnpm, CocoaPods, Homebrew, Cargo, Gradle), Docker virtual machine disks, DaVinci Resolve render clips, and APFS local snapshots with one-key execution.
* **🛡️ Safe by Default**: Moves files safely to macOS Trash using `FileManager.trashItem` (with Finder Put-Back support). **Never runs destructive `rm -rf`**.
* **🎨 GitHub Copilot CLI Aesthetic**: Modern terminal design with adaptive contrast (calibrated for **both light and dark terminal themes**), interactive volume/folder picker, live animated progress cards, and multi-selection support.

---

## 📸 Interactive Views

Press `1`–`4` or `Tab` to switch views instantly:

### 1. 📁 Directory Tree (`1: Tree`)
Interactive folder navigator with proportional gradient usage bars, APFS private size (`FREES`), and aligned folder names:
```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ 📂 /                                                                        │
│ ● APFS Volume: Macintosh HD • 873 GB used of 995 GB (88% full) • 118 GB free│
│ ● Scanned User Files: 306 GB (frees 9.88 GB) in 2.53M files • System: 567 GB│
│ [ 1 Tree ]    2 Big Files    3 Large & Old    4 Smart Cleanup               │
└─────────────────────────────────────────────────────────────────────────────┘
     SIZE        FREES       BAR         NAME                              MODIFIED
❯    182 GB      801 MB      [████████]  📁 Users/                         2026-09-24
      69.1 GB    180 KB      [███     ]  📁 Applications/                  2026-09-24
      21.8 GB    3.98 GB     [█       ]  📁 System/                        2026-09-24
      18.0 GB    4.95 GB     [█       ]  📁 Library/                       2026-09-24
       5.56 GB   0 B         [        ]  📁 usr/                           2026-09-24
       4.70 GB   157 MB      [        ]  📁 private/                       2026-09-24
       4.13 GB   0 B         [        ]  📁 opt/                           2026-09-24
```

### 2. 🔥 Largest Files (`2: Big Files`)
A bounded min-heap maintaining the top largest individual files discovered across the entire drive during traversal.

### 3. 🕰️ Large & Old (`3: Large & Old`)
Filters files exceeding configurable size and age thresholds (defaults: $\ge$ 100 MB, $\ge$ 12 months untouched). Dynamically adjust thresholds on the fly using `+` / `-` (size) and `[` / `]` (months).

### 4. 🧹 Smart Cleanup (`4: Smart Cleanup`)
A categorized catalog of safe-to-clean developer artifacts, caches, and system snapshot locks:
* **Xcode**: `DerivedData`, `iOS DeviceSupport`, `Archives`
* **Package Managers**: npm, yarn, pnpm, Homebrew, CocoaPods, Gradle, Pip, Cargo
* **Containers & VMs**: Docker virtual disk (`Docker.raw`), DaVinci Resolve `CacheClip`
* **APFS Snapshots**: Detects Time Machine local snapshots and offers one-click pruning via `tmutil deletelocalsnapshots`

---

## 🚀 Installation

### Prerequisites
* macOS 14.0 or newer
* Xcode 15+ or Command Line Tools (`xcode-select --install`)
* Swift 6.0+

### Build from Source
```bash
# Clone the repository
git clone https://github.com/onnobos/prettydiskviewer.git
cd prettydiskviewer

# Build optimized release binary
swift build -c release

# (Optional) Install to your PATH
cp .build/release/dv /usr/local/bin/dv
# or for user-local install:
cp .build/release/dv ~/.local/bin/dv
```

---

## 💻 Usage

```bash
# Launch interactive volume & folder picker (Copilot CLI style)
dv

# Scan your home folder
dv ~

# Scan the entire Mac (System snapshot + Data volumes)
dv /

# List all mounted internal and external APFS/HFS volumes
dv --volumes

# Fast non-interactive summary (for terminal scripts / pipes)
dv --plain .

# Machine-readable JSON output (ideal for automation & CI)
dv --plain --json ~

# Bypass persistent binary cache
dv --no-cache ~

# Configure worker threads (defaults to active processor count)
dv --threads 8 /
```

---

## ⌨️ Keyboard Shortcuts

| Key | Action |
| :--- | :--- |
| `1` – `4` / `Tab` | Switch tabs: **Tree**, **Big Files**, **Large & Old**, **Smart Cleanup** |
| `↑` / `↓` (or `j` / `k`) | Navigate items up and down |
| `Enter` / `→` | Open folder / Execute highlighted cleanup command |
| `Backspace` / `←` | Go up one directory level |
| `Space` | Toggle mark item for batch operations |
| `a` | Mark all safe items (in Smart Cleanup view) |
| `d` | Move selected or highlighted item(s) safely to macOS Trash |
| `r` | Reveal highlighted item in macOS Finder |
| `s` | Cycle sort order (**Size ↓**, **Name A-Z**, **File Count ↓**) |
| `+` / `-` | Increase / decrease size threshold in **Large & Old** view |
| `[` / `]` | Increase / decrease age threshold (months) in **Large & Old** view |
| `q` / `Esc` / `Ctrl+C` | Quit / Cancel scan |

---

## 💽 Understanding macOS Storage (Why Finder Numbers Differ)

When inspecting storage on macOS Catalina and newer, users often notice a large gap between Finder's *"Macintosh HD Info"* and traditional disk usage tools:

```text
Finder Macintosh HD Info:    Capacity: 994.66 GB  |  Used: 873.34 GB  |  Available: 118.17 GB
Traditional tools (ncdu):    Scanned active files: 306 GB
Difference:                  ~567 GB unaccounted for!
```

### Where is the missing space?
1. **APFS Time Machine Local Snapshots**: macOS silently creates local snapshots before updates or backups. When files are deleted or overwritten, their physical blocks remain locked in the APFS container until snapshots expire or are pruned.
2. **Purgeable Space**: System caches and cloud-synced files that macOS can evict when disk space is constrained.
3. **Protected System Volumes**: `/System/Volumes/Data` contains system revision stores (`/.DocumentRevisions-V100`), Spotlight indices (`/.Spotlight-V100`), and VM swap/sleep images in `/private/var`.

**Disk Viewer (`dv`) is designed specifically for APFS**: it queries volume-level APIs, measures purgeable blocks, discovers local snapshots, and clearly separates active user files from snapshot storage right in the header.

---

## 🏗️ Architecture

```text
┌────────────────────────────────────────────────────────┐
│                        dv CLI                          │
│     (Terminal Raw Mode • TUI • Animations • Theme)     │
└───────────────────────────▲────────────────────────────┘
                            │
┌───────────────────────────┴────────────────────────────┐
│                    DiskScanCore (Swift)                │
│  ┌───────────────────┐       ┌──────────────────────┐  │
│  │     WorkQueue     │◄─────►│       ScanTree       │  │
│  │ (Multi-threaded)  │       │ (48-byte Compact N)  │  │
│  └─────────▲─────────┘       └──────────▲───────────┘  │
│            │                            │              │
│  ┌─────────┴─────────┐       ┌──────────┴───────────┐  │
│  │  CleanupCatalog   │       │      ScanCache       │  │
│  │  (Data Rules)     │       │  (V2 Binary Cache)   │  │
│  └───────────────────┘       └──────────────────────┘  │
└───────────────────────────▲────────────────────────────┘
                            │
┌───────────────────────────┴────────────────────────────┐
│                   CDiskScan (Kernel C)                 │
│         getattrlistbulk() • 256 KB Buffer              │
│       ATTR_CMNEXT_PRIVATESIZE • SF_FIRMLINK            │
└────────────────────────────────────────────────────────┘
```

* **`CDiskScan`**: Low-level C bridge to macOS XNU `getattrlistbulk(2)`. Packs up to 2,000 file attributes into a 256 KB memory buffer in a single syscall, avoiding libc string overhead.
* **`ScanTree`**: Cache-coherent arena tree. Traversal operates in append-only fashion; size roll-up executes in a single linear $O(N)$ reverse post-order pass.
* **`WorkQueue`**: Lock-free atomic work coordinator distributing directory paths across all available CPU cores.
* **`ScanCache`**: Zero-copy binary file format storing the entire tree structure in `~/Library/Caches/dv/` for sub-millisecond warm reloads.

---

## 🧪 Testing

Disk Viewer features a comprehensive test suite covering algorithms, data structures, and edge cases:

```bash
# Run automated tests
swift run dv-tests
```

**Test Coverage Highlights:**
* Compact arena memory layout ($\le 64$ bytes/entry target)
* APFS Clone `frees` private block detection
* Hard link deduplication ($dev + ino$ tracking)
* Reverse post-order size and count roll-up idempotence
* Directory chain stress tests (100+ nested directories)
* Broad directory stress tests (1,000+ files per folder)
* Binary cache serialization and deserialization round-trip
* Selection manager overlap suppression

---

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.
