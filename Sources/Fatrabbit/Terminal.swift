import Foundation
import Synchronization

/// The handful of terminal facilities the block-map display needs, kept in one place so that
/// nothing else in the codebase deals in escape sequences.
///
/// Everything here targets stderr, which is where all of this tool's output goes: stdout stays
/// reserved for machine-readable results, and a display drawn on stdout would fight a redirect.
enum Terminal {
    struct Size {
        let columns: Int
        let rows: Int
    }

    /// The window size now, or nil where stderr is not something that will say — a pipe, a file,
    /// or a terminal that refuses the request.
    static func size() -> Size? {
        var window = winsize()
        guard ioctl(STDERR_FILENO, UInt(TIOCGWINSZ), &window) == 0,
              window.ws_col > 0, window.ws_row > 0 else { return nil }
        return Size(columns: Int(window.ws_col), rows: Int(window.ws_row))
    }

    /// Whether a full-screen colour display is worth attempting at all. Deliberately conservative:
    /// where the answer is no the tool falls back to its line-based output, which is no loss.
    static var isUsable: Bool {
        guard isatty(STDERR_FILENO) != 0 else { return false }
        // https://no-color.org — set by people who mean it, so it turns the whole display off
        // rather than merely draining the colour out of it.
        if variable("NO_COLOR") != nil { return false }
        guard let term = variable("TERM"), !term.isEmpty, term != "dumb" else { return false }
        return true
    }

    /// Whether box-drawing and block characters will render. Where the locale says nothing about
    /// UTF-8, assume it will not: a frame of question marks is worse than a frame of hyphens.
    static var usesUnicode: Bool {
        for name in ["LC_ALL", "LC_CTYPE", "LANG"] {
            guard let value = variable(name), !value.isEmpty else { continue }
            let upper = value.uppercased()
            return upper.contains("UTF-8") || upper.contains("UTF8")
        }
        return false
    }

    private static func variable(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }

    /// One write(2) per frame, matching the unbuffered habit of `Progress`: a half-written frame is
    /// visible as tearing, and anything held in a buffer is lost if the process is killed.
    static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Switches to the alternate screen buffer, so the run gets the whole window and the scrollback
    /// underneath it is left exactly as it was. Autowrap goes off with it: without that, drawing the
    /// last column of the last row scrolls the screen and every subsequent frame is one row out.
    static func enterFullScreen() {
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l\u{1B}[2J\u{1B}[H")
    }

    /// The cursor is shown last, after the buffer switch rather than before it: some terminals — and
    /// tmux — restore cursor visibility along with the alternate screen, which would hide it again
    /// straight after we had asked for it and leave the shell without one.
    static func leaveFullScreen() {
        write("\u{1B}[0m\u{1B}[?7h\u{1B}[?1049l\u{1B}[?25h")
    }

    /// Waits for a single keypress, without needing Return.
    ///
    /// Returns at once where stdin is not a terminal: a run driven from a script must not stop and
    /// wait for someone who is not there. Signals are turned off for the duration, so Ctrl-C arrives
    /// as an ordinary keystroke and dismisses the display rather than killing the process before the
    /// terminal has been handed back.
    static func waitForKey() {
        guard isatty(STDIN_FILENO) != 0 else { return }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return }

        var raw = original
        raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO) | tcflag_t(ISIG))
        // `c_cc` is an array of control characters in C, which Swift imports as a tuple, so its
        // slots are reached by index rather than by name. Indexed through the constants the header
        // defines rather than through the numbers they currently stand for: a literal index is
        // right only for the platform it was read off, and being wrong about one is not a compile
        // error — it sets some other control character and leaves a terminal that misbehaves for
        // reasons nothing here would explain.
        withUnsafeMutableBytes(of: &raw.c_cc) {
            $0[Int(VMIN)] = 1       // one byte is enough
            $0[Int(VTIME)] = 0      // and wait as long as it takes
        }
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return }

        var byte: UInt8 = 0
        _ = read(STDIN_FILENO, &byte, 1)
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
    }

    /// Held only so the source outlives `onResize`; a released source stops delivering.
    private static let resizeSource = Mutex<DispatchSourceSignal?>(nil)

    /// Calls `handler` whenever the window changes size. A dispatch source rather than a signal
    /// handler for the same reason `Interruption` uses one: the work happens on an ordinary queue,
    /// with none of the async-signal-safety constraints a real handler carries.
    static func onResize(_ handler: @escaping @Sendable () -> Void) {
        signal(SIGWINCH, SIG_IGN)
        // Built inside the lock rather than handed in from outside it. On Linux a DispatchSource
        // constructed out here is task-isolated by the time it is stored, and moving it into the
        // mutex is then a `sending` violation; assembling it in place never crosses a region.
        resizeSource.withLock { stored in
            let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
            source.setEventHandler(handler: handler)
            source.resume()
            stored = source
        }
    }
}
