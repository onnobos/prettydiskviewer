import Foundation
import Darwin

public final class Terminal: @unchecked Sendable {
    private var originalTermios = termios()
    private var isRaw = false
    public let isTTY: Bool
    public let supportsColor: Bool
    
    public init() {
        self.isTTY = isatty(STDOUT_FILENO) != 0 && isatty(STDIN_FILENO) != 0
        let noColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        let term = ProcessInfo.processInfo.environment["TERM"]
        self.supportsColor = isTTY && !noColor && (term != "dumb")
    }
    
    public func enableRawMode() {
        guard isTTY, !isRaw else { return }
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        // Disable ECHO, ICANON, IEXTEN, ISIG
        raw.c_lflag &= ~(UInt(ECHO | ICANON | IEXTEN | ISIG))
        // Disable IXON, ICRNL
        raw.c_iflag &= ~(UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP))
        // 8-bit chars
        raw.c_cflag |= UInt(CS8)
        // Return each byte immediately
        raw.c_cc.16 = 1 // VMIN
        raw.c_cc.17 = 0 // VTIME
        
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
        
        // Enter alternate screen buffer & hide cursor
        print("\u{001B}[?1049h\u{001B}[?25l", terminator: "")
        fflush(stdout)
    }
    
    public func disableRawMode() {
        guard isRaw else { return }
        // Restore cursor & exit alternate screen buffer
        print("\u{001B}[?25h\u{001B}[?1049l", terminator: "")
        fflush(stdout)
        
        var orig = originalTermios
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig)
        isRaw = false
    }
    
    deinit {
        disableRawMode()
    }
    
    public func getTerminalSize() -> (width: Int, height: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }
    
    public func hasKeyAvailable(timeoutMs: Int32 = 50) -> Bool {
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ret = poll(&fds, 1, timeoutMs)
        return ret > 0 && (fds.revents & Int16(POLLIN)) != 0
    }
    
    public func readKey() -> KeyPress {
        var buf = [UInt8](repeating: 0, count: 32)
        let bytesRead = Darwin.read(STDIN_FILENO, &buf, 32)
        guard bytesRead > 0 else { return .none }
        
        if buf[0] == 27 { // Escape sequence
            if bytesRead == 1 {
                return .escape
            }
            if buf[1] == 91 { // '['
                switch buf[2] {
                case 65: return .up
                case 66: return .down
                case 67: return .right
                case 68: return .left
                case 72: return .home
                case 70: return .end
                default: break
                }
            }
            return .escape
        }
        
        switch buf[0] {
        case 3: return .ctrlC
        case 4: return .ctrlD
        case 10, 13: return .enter
        case 127, 8: return .backspace
        case 9: return .tab
        case 32: return .space
        case 113: return .char("q")
        case 106: return .down       // 'j'
        case 107: return .up         // 'k'
        case 104: return .left       // 'h'
        case 108: return .right      // 'l'
        case let b where b >= 32 && b <= 126:
            return .char(Character(UnicodeScalar(b)))
        default:
            return .none
        }
    }
}

public enum KeyPress: Equatable {
    case up
    case down
    case left
    case right
    case enter
    case backspace
    case escape
    case tab
    case space
    case home
    case end
    case ctrlC
    case ctrlD
    case char(Character)
    case none
}

public enum ANSI {
    public static let reset = "\u{001B}[0m"
    public static let bold = "\u{001B}[1m"
    public static let dim = "\u{001B}[2m"
    public static let italic = "\u{001B}[3m"
    public static let underline = "\u{001B}[4m"
    public static let inverse = "\u{001B}[7m"
    
    public static let red = "\u{001B}[31m"
    public static let green = "\u{001B}[32m"
    public static let yellow = "\u{001B}[33m"
    public static let blue = "\u{001B}[34m"
    public static let magenta = "\u{001B}[35m"
    public static let cyan = "\u{001B}[36m"
    public static let white = "\u{001B}[37m"
    
    public static let brightRed = "\u{001B}[91m"
    public static let brightGreen = "\u{001B}[92m"
    public static let brightYellow = "\u{001B}[93m"
    public static let brightBlue = "\u{001B}[94m"
    public static let brightMagenta = "\u{001B}[95m"
    public static let brightCyan = "\u{001B}[96m"
    public static let brightWhite = "\u{001B}[97m"
    
    public static let bgBlue = "\u{001B}[44m"
    public static let bgDarkGray = "\u{001B}[100m"
    
    public static func clearScreen() -> String { "\u{001B}[2J\u{001B}[H" }
    public static func moveTo(row: Int, col: Int) -> String { "\u{001B}[\(row);\(col)H" }
    public static func clearLine() -> String { "\u{001B}[2K" }
}
