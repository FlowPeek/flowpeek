import Darwin
import FlowPeekCore
import Foundation

/// One pty found under a terminal, and the size it was carrying when it was asked.
struct TerminalPtyReading: Hashable, Sendable {
    /// The slave device, named the way `devname` names it: "/dev/ttys000".
    let device: String
    /// The device's minor number, which is what a pty master and its slave have in common:
    /// `/dev/ttys000` is major 16 minor 0, and the master fd the terminal holds open for that
    /// surface reports the same minor in `vst_rdev`. Measured: Ghostty pid 1510 held one master of
    /// rdev 251658240, minor 0, against a slave of `/dev/ttys000`.
    let minor: Int
    let winsize: TerminalWinsize
}

/// Everything one terminal process's ptys had to say, in one look.
struct TerminalPtySurvey: Sendable {
    /// The minor number of every pty master the terminal itself holds open. Exactly one per live
    /// surface, across every window, tab and split of that process -- so this is the authoritative
    /// count of surfaces, and it needs no child process to exist.
    ///
    /// A single member means no matching is needed: whatever pane is being looked at, that is its
    /// pty. That is the common case and the cheap one.
    let surfaces: Set<Int>

    /// A reading for each surface whose slave could be found and asked, in the order the walk found
    /// them. Every distinct one, never just the first: two surfaces of the same process can be
    /// running different font sizes, so whether the readings agree is a question only the caller --
    /// which knows which pane is on screen -- can answer.
    let readings: [TerminalPtyReading]

    /// When this was taken. A survey handed back after the deadline ran out is the last one taken,
    /// which may be older than the caller's poll; this is how it can tell.
    let taken: Date

    /// Nothing to say, and nothing to draw from. The caller refuses; it never guesses.
    static func nothing(at taken: Date = Date()) -> TerminalPtySurvey {
        TerminalPtySurvey(surfaces: [], readings: [], taken: taken)
    }

    var isEmpty: Bool { readings.isEmpty }
}

/// Finds the ptys underneath a terminal process and asks each one how big it is.
///
/// This is the impure half of the row-height fix. A terminal writes its own grid into the pty --
/// Ghostty's `Exec.zig` copies `grid_size.rows` into `ws_row` and `size.terminal().height` into
/// `ws_ypixel` -- so `TIOCGWINSZ` is a *measurement* of the cell, not an inference from one.
/// Measured live: `/dev/ttys000` answered `ws_row=40 ws_col=140 ws_ypixel=1280 ws_xpixel=2250`,
/// and 1280 / 40 = 32 device pixels = 16.000 points at scale 2, which is exactly the row height
/// that had previously taken three separate buffer readings to solve. It is also the only answer
/// available for a full-screen program: a coding agent's interface and vim both fill the viewport,
/// so the scroll area reports its content as exactly as tall as itself and carries no equation to
/// solve at all.
///
/// **This never reads a byte from the terminal.** The slave is opened `O_RDONLY | O_NONBLOCK |
/// O_NOCTTY`, asked one `ioctl(TIOCGWINSZ)`, and closed in the same scope; there is no `read`,
/// `recv` or mapping of the descriptor anywhere in this file, and nothing here ever returns text.
/// `O_NOCTTY` is there so opening somebody's terminal cannot make it this process's controlling
/// terminal, and `O_NONBLOCK` so an open can never wait on a device nobody is holding open.
/// What is on somebody's terminal is theirs; all this asks for is how many rows fit in the window.
///
/// Three things the walk has to survive, all of them measured rather than guessed:
///
/// - **A process whose info cannot be read.** Ghostty's child is `/usr/bin/login`, which is setuid
///   root, and `proc_pidinfo` fails outright on it. The tty only becomes readable one level lower,
///   on the shell. A walk that stops at a node it cannot read finds nothing at all, so this one
///   recurses past it.
/// - **`proc_listchildpids` returns a count of pids, not a byte count.** Dividing the result by
///   `MemoryLayout<pid_t>.size` yields zero and the probe silently finds nothing, for ever.
///   Measured: one child returned 1, three children returned 3.
/// - **`devname` costs 632 microseconds.** Called once per descendant it is the entire cost of the
///   walk -- 5.47 ms naive, against 87 microseconds once devices are deduplicated on `dev_t` and
///   their names cached for the life of the process.
///
/// Cheap enough for a watch that polls four times a second because it almost never runs: a survey
/// is cached per process and expires on a clock, and the caller invalidates it when the pane or its
/// rectangle changes. Measured through this file against a live Ghostty, whose shell sits under
/// eleven descendants: 0.38-0.45 ms for masters plus the whole pruned walk, 0.001 ms while the
/// survey is cached, against an idle poll of 0.2-1.2 ms and a read budget of 150 ms.
@MainActor
final class TerminalPtyProbe {
    /// How long a survey is believed before it is taken again.
    ///
    /// The walk is cheap but it is not free, and nothing it measures moves on its own: rows change
    /// when the window is resized or the font is changed, both of which the caller sees for itself
    /// and can `forget` on. This is only the backstop for a change it did not see -- a font size
    /// altered inside a full-screen program changes `ws_row` and nothing else -- so a second is
    /// short enough to correct that invisibly and long enough that three polls out of four cost
    /// nothing.
    static let cacheLifetime: TimeInterval = 1

    /// How much of the read's budget must remain before the walk is worth starting.
    ///
    /// The figure is the cold cost rather than the warm one: measured through this file, the first
    /// survey of a process costs 2.1-2.5 ms -- almost all of it the one `devname` per device it has
    /// never seen -- against 0.38-0.45 ms once the names are cached and 0.001 ms while the survey
    /// itself is. A terminal that owns no pty at all refuses in 0.016-0.038 ms without walking
    /// anything. All of it is against a 150 ms read budget, so this is a floor for starting, not a
    /// promise about how long it takes.
    static let minimumBudget: TimeInterval = 0.003

    /// How far below the terminal to look. Ghostty's shell sits two levels down (ghostty -> login
    /// -> zsh) and a wrapper or two more is plausible; deeper than this is somebody's build running
    /// under their editor, not a terminal surface.
    private static let depthLimit = 4

    /// How many children one node may have before the walk gives up counting them. A terminal's
    /// shell has a handful; this is only here so a pathological tree cannot allocate without bound.
    private static let childLimit = 4096

    /// The cached survey per terminal process, with the moment it was taken.
    private var surveys: [pid_t: TerminalPtySurvey] = [:]

    /// `dev_t` to device name, kept for the life of the process. The mapping is arithmetic on the
    /// minor number and never changes for a given device, and `devname` is the single most
    /// expensive call in the walk by two orders of magnitude.
    private var deviceNames: [UInt32: String] = [:]

    // MARK: - Asking

    /// Every pty reading found under `pid`, from the cache when it is fresh.
    ///
    /// Refuses -- returns a survey with no readings -- rather than answering partially: no masters
    /// open, no budget left, nothing under the process that could be asked. The caller's rule is
    /// that a frame in the wrong place is worse than no frame, and an empty survey is how that is
    /// said here.
    func survey(of pid: pid_t, before deadline: Date) -> TerminalPtySurvey {
        let now = Date()
        if let cached = surveys[pid], now.timeIntervalSince(cached.taken) < Self.cacheLifetime {
            return cached
        }
        // Out of budget: hand back whatever was last measured, stale date and all, so the caller can
        // judge its age rather than being told there are no ptys when there are.
        guard deadline.timeIntervalSince(now) >= Self.minimumBudget else {
            return surveys[pid] ?? .nothing(at: now)
        }

        let surfaces = masterMinors(of: pid)
        // No master fds is not "this terminal has no surfaces", it is "this is not a terminal whose
        // surfaces are ptys it owns" -- an app whose sessions live in a separate server process
        // looks exactly like this. Either way there is nothing here to match a pane against.
        guard !surfaces.isEmpty else {
            let survey = TerminalPtySurvey.nothing(at: now)
            surveys[pid] = survey
            return survey
        }

        let readings = walk(from: pid, surfaces: surfaces, before: deadline)
        let survey = TerminalPtySurvey(surfaces: surfaces, readings: readings, taken: now)
        // Only a complete walk is remembered. A descent the deadline cut short has found some of
        // the surfaces and not others, and caching that would hold a partial view for the whole
        // cache lifetime -- during which the caller could see one reading, believe it is the only
        // one, and take it for this pane. An incomplete walk is answered once and asked again.
        if readings.count == surfaces.count { surveys[pid] = survey }
        return survey
    }

    // MARK: - Forgetting

    /// Drops the cached survey for one terminal. Called when the pane or its rectangle changes:
    /// a resize, a font change and a window switch all move the numbers this measures, and all of
    /// them are things the caller sees before the clock does.
    func forget(_ pid: pid_t) {
        surveys.removeValue(forKey: pid)
    }

    func forgetEverything() {
        surveys.removeAll()
    }

    /// Drops the surveys of terminals that are no longer running, so a recycled process identifier
    /// cannot inherit another terminal's grid. Keyed by the terminal's own process, never by a
    /// child's: a shell's pid is not in `NSWorkspace.runningApplications` and would never be pruned.
    func forgetDeadProcesses(alive: Set<pid_t>) {
        guard surveys.count > 1 else { return }
        surveys = surveys.filter { alive.contains($0.key) }
    }

    // MARK: - The surface set

    /// The minor number of each pty master the process holds open -- one per live surface.
    ///
    /// This is the count of surfaces and it costs 0.068-0.128 ms, with no child process involved.
    /// It is also what keeps a nested pty out: `tmux` and `script` create ptys of their own under
    /// the shell, and those minors are not in this set, so the walk below discards them.
    private func masterMinors(of pid: pid_t) -> Set<Int> {
        // `PROC_PIDLISTFDS` is the one call here that answers in bytes, unlike `proc_listchildpids`
        // below. Ask for the size first, then take it with a little room in case a descriptor is
        // opened between the two calls.
        let sizing = proc_pidinfo(Int32(pid), PROC_PIDLISTFDS, 0, nil, 0)
        guard sizing > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(sizing) / stride + 16)
        let taken = descriptors.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return proc_pidinfo(Int32(pid), PROC_PIDLISTFDS, 0, base, Int32(buffer.count))
        }
        guard taken > 0 else { return [] }

        var minors: Set<Int> = []
        for descriptor in descriptors.prefix(Int(taken) / stride) {
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            let read = proc_pidfdinfo(Int32(pid), descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size)
            guard read == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { buffer -> String in
                guard let base = buffer.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            // The master half of every pty is the same node, /dev/ptmx; the surface is told apart by
            // the device it was cloned into, which is the minor of `vst_rdev`.
            guard path == "/dev/ptmx" else { continue }
            minors.insert(Int(info.pvip.vip_vi.vi_stat.vst_rdev & 0xff_ffff))
        }
        return minors
    }

    // MARK: - The walk

    /// Descends the process tree under the terminal, collecting one reading per surface.
    ///
    /// Pruned twice over: a subtree is abandoned as soon as it yields a tty -- everything below the
    /// shell shares the shell's terminal and would only be the same device again -- and the whole
    /// walk stops once every master has been accounted for. Unpruned it descends into every MCP
    /// server and language server a coding agent has running, which measured 2.4 to 11.0 ms against
    /// 0.65 to 0.79 ms pruned.
    private func walk(from pid: pid_t, surfaces: Set<Int>, before deadline: Date) -> [TerminalPtyReading] {
        var readings: [TerminalPtyReading] = []
        var seenDevices: Set<UInt32> = []
        var visited: Set<pid_t> = [pid]

        func descend(_ parent: pid_t, depth: Int) {
            guard depth < Self.depthLimit,
                  readings.count < surfaces.count,
                  Date() < deadline else { return }
            for child in children(of: parent) {
                guard readings.count < surfaces.count, Date() < deadline else { return }
                guard visited.insert(child).inserted else { continue }
                switch device(of: child) {
                case .some(let dev):
                    // A tty found here speaks for everything below it, so this subtree is done --
                    // whether or not the device turns out to be one of the terminal's own.
                    guard seenDevices.insert(dev).inserted else { continue }
                    guard surfaces.contains(Int(dev & 0xff_ffff)) else { continue }
                    if let reading = read(dev) { readings.append(reading) }
                case .none:
                    // No readable tty. That is either a process between the terminal and its shell
                    // or one whose info is refused outright -- `proc_pidinfo` fails on /usr/bin/login
                    // at every pid it was tried on, and login is exactly the node Ghostty's shell
                    // hangs below. Recursing past it is the whole reason this is a recursion.
                    descend(child, depth: depth + 1)
                }
            }
        }

        descend(pid, depth: 0)
        return readings
    }

    /// The children of one process.
    ///
    /// `proc_listchildpids` returns a **count of pids**, not a byte count -- measured 1 for one
    /// child and 3 for three. Treating it as bytes is the trap that makes this whole probe find
    /// nothing and say so silently, so the count is taken as pids and then clamped to what was
    /// actually allocated; a system that ever answered in bytes would overshoot into the zeroed
    /// tail, which the filter below throws away either way.
    private func children(of pid: pid_t) -> [pid_t] {
        var capacity = 32
        while capacity <= Self.childLimit {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return 0 }
                return proc_listchildpids(pid, base, Int32(buffer.count * MemoryLayout<pid_t>.stride))
            }
            guard count > 0 else { return [] }
            if Int(count) >= capacity {
                // The buffer may have been filled exactly, in which case there are probably more.
                capacity *= 2
                continue
            }
            return pids.prefix(Int(count)).filter { $0 > 0 && $0 != pid }
        }
        return []
    }

    /// The controlling terminal of one process, or nil when it has none and when its info cannot be
    /// read at all. Those two are deliberately the same answer: both mean "keep going down".
    private func device(of pid: pid_t) -> UInt32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let dev = info.e_tdev
        guard dev != UInt32(bitPattern: Int32(-1)), dev != 0 else { return nil }
        return dev
    }

    /// Opens one slave, asks its size, and closes it.
    ///
    /// The open is `O_RDONLY | O_NONBLOCK | O_NOCTTY` and the descriptor is closed in this scope on
    /// every path. Exactly one `ioctl` is issued and **no byte is ever read from the descriptor**:
    /// the size of somebody's terminal is all this wants, and its contents are none of its
    /// business. `O_NOCTTY` also keeps the open from ever claiming the device as this process's own
    /// controlling terminal, and `O_NONBLOCK` keeps it from waiting on one.
    private func read(_ dev: UInt32) -> TerminalPtyReading? {
        guard let name = deviceName(dev) else { return nil }
        let fd = open(name, O_RDONLY | O_NONBLOCK | O_NOCTTY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0 else { return nil }
        let winsize = TerminalWinsize(
            rows: Int(size.ws_row),
            columns: Int(size.ws_col),
            heightInPixels: Int(size.ws_ypixel),
            widthInPixels: Int(size.ws_xpixel)
        )
        // A terminal that never sets a pixel size answers zeroes, and zero rows is a pty
        // nobody has sized. `grid` refuses those too; this only saves carrying them around.
        guard winsize.rows > 0, winsize.columns > 0,
              winsize.heightInPixels > 0, winsize.widthInPixels > 0 else { return nil }
        return TerminalPtyReading(device: name, minor: Int(dev & 0xff_ffff), winsize: winsize)
    }

    /// The path of a character device, cached for the life of the process.
    ///
    /// `devname` is the right way to name it and `/dev/ttys%03d` is not: the numbering runs past
    /// 999 -- a live `/dev/ttys057` was measured on this machine and higher minors are ordinary on
    /// a long-running session -- and the format then produces a path that does not exist. It also
    /// costs 632 microseconds a call, which is why it is asked once per device rather than once per
    /// process.
    private func deviceName(_ dev: UInt32) -> String? {
        if let cached = deviceNames[dev] { return cached }
        guard let raw = devname(dev_t(dev), S_IFCHR) else { return nil }
        let name = String(cString: raw)
        // `devname` answers "#16/57" for a device it cannot name, which is not a path.
        guard !name.isEmpty, !name.hasPrefix("#") else { return nil }
        // A minor is not a device. Measured on this Mac: /dev/ttys002 and
        // /dev/tty.Bluetooth-Incoming-Port are both minor 2, and the master side cannot supply a
        // major to tell them apart -- a pty master is major 15 and its slave major 16. So the
        // slave is required to look like one. Opening somebody's Bluetooth serial port to ask how
        // many rows it has is not a thing this should ever do.
        guard name.hasPrefix("ttys") else { return nil }
        let path = "/dev/" + name
        deviceNames[dev] = path
        return path
    }
}
