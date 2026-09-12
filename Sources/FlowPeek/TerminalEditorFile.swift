import Darwin
import Foundation

/// The file a full-screen editor in a terminal has open.
///
/// The terminal cannot answer for it. An editor paints on the alternate screen, which has no
/// scrollback -- measured on Ghostty, a 200-line file in a 19-row pane answers 19 lines and
/// `AXStringForRange` one character past them returns an error -- so a diagram taller than the
/// window is not in accessibility anywhere, at any price. What is left is the file, and the
/// editor's own process is what names it.
///
/// Nothing here identifies which pane an editor belongs to. One terminal process owns every split
/// and tab, and no attribute says which pty is in front, so everything below produces *candidates*.
/// `EditorViewportAlignment` is what turns a candidate into an answer: a file whose lines are not
/// the rows on screen does not align, and a candidate that does not align is not used. Picking
/// wrongly costs a refusal, never a wrong frame.
///
/// Two ways to the path, because neither alone is enough. Measured over thirteen ways of opening a
/// file, the command line was right 7 times and the swap descriptor 10; together, 12. The one case
/// neither reaches is `:set noswapfile` on a file opened after startup, and that refuses.
@MainActor
final class TerminalEditorFile {
    /// Processes worth asking. `view` is vim in read-only mode and `vi` is vim on macOS.
    private static let editorNames: Set<String> = ["vim", "nvim", "view", "vi", "gvim"]

    /// How deep under the terminal an editor can sit. The shell is two or three levels down through
    /// `login`, and the editor is under that; past this it is somebody else's process tree.
    private static let maximumDepth = 6

    /// How much of a swap file is read. The header is the first block and the path sits inside it;
    /// nothing past it is looked at, and no part of the buffer's contents is read.
    private static let headerBytes = 1_024

    /// Offsets inside vim's swap header, verified against VIM 9.1. The path is stored absolute and
    /// NUL-terminated, and `b0_dirty` is a byte that is non-zero while the buffer has unwritten
    /// changes -- measured flipping 0.10 to 0.13 seconds after a keystroke, and back on `:w`.
    private static let pathOffset = 108
    private static let pathLimit = 1_008
    private static let dirtyOffset = 1_007

    struct Candidate: Equatable {
        let path: String
        /// Whether the editor has changes it has not written. The file on disk is then behind what
        /// the reader is looking at, which the alignment sees for itself -- the edited rows stop
        /// matching and the run shortens -- but it is worth carrying so a caller can decide.
        let hasUnsavedChanges: Bool
    }

    /// How long a walk is believed before it is taken again.
    ///
    /// The walk is three or four `proc_pidinfo` calls per descendant and it is cheap, but it is not
    /// free and nothing it finds moves on its own: an editor does not change which file it has open
    /// four times a second. This is what keeps the cost off a poll that is rescanning because an
    /// outline is up rather than because anything changed.
    private static let cacheLifetime: TimeInterval = 2

    private var cached: (terminal: pid_t, taken: Date, candidates: [Candidate])?

    /// Every file an editor under this terminal has open, nearest first.
    func candidates(under terminal: pid_t) -> [Candidate] {
        let now = Date()
        if let cached, cached.terminal == terminal, now.timeIntervalSince(cached.taken) < Self.cacheLifetime {
            return cached.candidates
        }
        let found = walk(under: terminal)
        cached = (terminal, now, found)
        return found
    }

    private func walk(under terminal: pid_t) -> [Candidate] {
        var found: [Candidate] = []
        var seen = Set<String>()
        for editor in editors(under: terminal) {
            for candidate in files(of: editor) where !seen.contains(candidate.path) {
                seen.insert(candidate.path)
                found.append(candidate)
            }
        }
        return found
    }

    // MARK: - Finding the editor

    private func editors(under terminal: pid_t) -> [pid_t] {
        var editors: [pid_t] = []
        var frontier = [(pid: terminal, depth: 0)]
        while let node = frontier.popLast() {
            guard node.depth < Self.maximumDepth else { continue }
            for child in ProcessTree.children(of: node.pid) {
                if let name = ProcessTree.name(of: child), Self.editorNames.contains(name) {
                    editors.append(child)
                }
                // Recurse past a node whatever it is: `login` is setuid and answers nothing, and a
                // walk that stops there finds no editor at all.
                frontier.append((child, node.depth + 1))
            }
        }
        return editors
    }

    // MARK: - Finding the file

    private func files(of editor: pid_t) -> [Candidate] {
        // The swap descriptor first: it names the buffer the editor is actually showing, which the
        // command line stops being right about the moment anybody types `:e`.
        var found = swapCandidates(of: editor)
        // And the command line after it, which is what is left when there is no swap file at all --
        // `-R`, `-n`, `set noswapfile`. Every argument that names a file that exists is kept,
        // because choosing between them is the alignment's job rather than this one's.
        for path in argumentPaths(of: editor) where !found.contains(where: { $0.path == path }) {
            found.append(Candidate(path: path, hasUnsavedChanges: false))
        }
        return found
    }

    private func swapCandidates(of editor: pid_t) -> [Candidate] {
        var candidates: [Candidate] = []
        for path in ProcessTree.openFiles(of: editor) where isSwap(path) {
            guard let header = FileHandle(forReadingAtPath: path).flatMap({ handle -> Data? in
                defer { try? handle.close() }
                return try? handle.read(upToCount: Self.headerBytes)
            }), header.count > Self.dirtyOffset else { continue }
            // `b0_magic` is the first bytes of a vim swap file. Anything else with a `.swp` name is
            // not one, and its bytes are not read.
            guard header.count > Self.pathOffset, header[header.startIndex] == UInt8(ascii: "b"),
                  header[header.startIndex + 1] == UInt8(ascii: "0") else { continue }
            let slice = header[(header.startIndex + Self.pathOffset)..<(header.startIndex + Self.pathLimit)]
            guard let end = slice.firstIndex(of: 0),
                  let name = String(data: header[(header.startIndex + Self.pathOffset)..<end], encoding: .utf8),
                  name.hasPrefix("/"), FileManager.default.fileExists(atPath: name) else { continue }
            candidates.append(
                Candidate(
                    path: name,
                    hasUnsavedChanges: header[header.startIndex + Self.dirtyOffset] != 0
                )
            )
        }
        return candidates
    }

    private func isSwap(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("."), name.count > 4 else { return false }
        let suffix = name.suffix(4)
        return suffix.hasPrefix(".sw")
    }

    /// Every argument naming a file that exists, resolved against the process's own directory.
    private func argumentPaths(of pid: pid_t) -> [String] {
        guard let arguments = Self.arguments(of: pid) else { return [] }
        let directory = Self.workingDirectory(of: pid)
        var paths: [String] = []
        for argument in arguments.dropFirst() where !argument.hasPrefix("-") {
            let resolved = argument.hasPrefix("/")
                ? argument
                : (directory.map { ($0 as NSString).appendingPathComponent(argument) } ?? argument)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            paths.append((resolved as NSString).standardizingPath)
        }
        return paths
    }

    private static func arguments(of pid: pid_t) -> [String]? {
        var maximum: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var sizing: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&sizing, 2, &maximum, &size, nil, 0) == 0, maximum > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(maximum))
        var request: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        size = Int(maximum)
        guard sysctl(&request, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }
        var count: Int32 = 0
        memcpy(&count, buffer, MemoryLayout<Int32>.size)
        var index = MemoryLayout<Int32>.size
        // The executable path, then a run of NULs, then the arguments themselves.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        var current: [CChar] = []
        while index < size, arguments.count < Int(count) {
            if buffer[index] == 0 {
                arguments.append(String(cString: current + [0]))
                current = []
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        return arguments
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let got = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard got == Int32(size) else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }
}
