import Darwin
import FlowPeekCore
import Foundation

/// The diagrams a coding agent has written, taken from the file it is already writing them to.
///
/// This exists for one measured reason. Codex renders inline, so every row of its output is on the
/// terminal and `gridRead` reaches all of it -- but Codex lays out its own wrap, and that wrap
/// cannot be undone. An exact forward model of it, inverted exactly, recovered 186 of 200 blocks,
/// and **none of the fourteen failures is detectable**: each wrong reading lays back out to the rows
/// that are on screen, character for character, so a guard that re-renders to check agrees with the
/// wrong answer. About seven per cent silent corruption is the floor for anything working from the
/// screen alone. That is what this is for and the only thing it is for.
///
/// What it does NOT do is find diagrams. The screen finds them, frames them and decides which are
/// visible, exactly as before; this only offers the exact text of a block that has already been
/// found, and only when that text is unmistakably the same diagram. A source that matches nothing on
/// screen is never used, and one that matches two things is not used either.
///
/// Nothing about Codex's file format is assumed. Lines that do not carry a fenced Mermaid block are
/// never decoded -- a byte scan rejects them first -- and lines that do are walked for every string
/// they contain rather than for a particular key, so a change to the schema costs nothing. It also
/// means a diagram the reader pasted *in* is found as readily as one the agent wrote, which is
/// right: it is on their screen either way.
@MainActor
final class CodexSessionSources {
    private static let agentNames: Set<String> = ["codex"]
    private static let maximumDepth = 6
    /// How much of a session file is read on first sight. Everything after that is the bytes the
    /// file has grown by, so a long session is read once and then a few kilobytes at a time.
    private static let firstLookBytes = 512 * 1_024
    /// The most sources kept. A session with more diagrams than this in it has scrolled the early
    /// ones far out of any window.
    private static let maximumSources = 64

    private var offsets: [String: UInt64] = [:]
    private var sources: [String: [String]] = [:]

    /// How long the walk to the agent's file is believed before it is taken again. The file itself
    /// is still checked for growth every time; this is only the process walk.
    private static let cacheLifetime: TimeInterval = 2
    private var cachedFiles: (terminal: pid_t, taken: Date, paths: [String])?

    /// Every fenced Mermaid source this terminal's agent has written, newest last.
    func sources(under terminal: pid_t) -> [String] {
        let now = Date()
        let paths: [String]
        if let cachedFiles, cachedFiles.terminal == terminal,
           now.timeIntervalSince(cachedFiles.taken) < Self.cacheLifetime {
            paths = cachedFiles.paths
        } else {
            paths = agents(under: terminal).flatMap { sessionFiles(of: $0) }
            cachedFiles = (terminal, now, paths)
        }
        var all: [String] = []
        for path in paths {
            refresh(path)
            all.append(contentsOf: sources[path] ?? [])
        }
        return all
    }

    // MARK: - Finding the agent and its file

    private func agents(under terminal: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var frontier = [(pid: terminal, depth: 0)]
        while let node = frontier.popLast() {
            guard node.depth < Self.maximumDepth else { continue }
            for child in ProcessTree.children(of: node.pid) {
                if let name = ProcessTree.name(of: child), Self.agentNames.contains(name) {
                    found.append(child)
                }
                frontier.append((child, node.depth + 1))
            }
        }
        return found
    }

    private func sessionFiles(of agent: pid_t) -> [String] {
        ProcessTree.openFiles(of: agent).filter {
            $0.hasSuffix(".jsonl") && ($0 as NSString).lastPathComponent.hasPrefix("rollout-")
        }
    }

    // MARK: - Reading only what is new

    private func refresh(_ path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return }
        // A first look at a file already bigger than the window worth reading starts part-way in,
        // and only that read starts mid-line. Every later one starts where the last one stopped.
        let known = offsets[path]
        let startsMidLine = known == nil && size > UInt64(Self.firstLookBytes)
        var from = known ?? (startsMidLine ? size - UInt64(Self.firstLookBytes) : 0)
        if size < from {
            // Truncated or replaced: start again rather than reading from a stale offset.
            from = 0
            sources[path] = []
        }
        offsets[path] = from
        guard size > from, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: from)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return }
        let take = AppendedLines.take(chunk, startsMidLine: startsMidLine)
        offsets[path] = from + UInt64(take.consumed)
        guard !take.lines.isEmpty else { return }

        var kept = sources[path] ?? []
        for line in take.lines {
            // The prefilter, and it is what makes this affordable: a session file is overwhelmingly
            // tool calls and their results, and none of that is ever decoded.
            guard line.range(of: Data("```mermaid".utf8)) != nil else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: line) else { continue }
            for text in Self.strings(in: object) {
                for block in MermaidFences.blocks(in: text) where !kept.contains(block) {
                    kept.append(block)
                }
            }
        }
        if kept.count > Self.maximumSources { kept.removeFirst(kept.count - Self.maximumSources) }
        sources[path] = kept
    }

    /// Every string anywhere inside a decoded line, so nothing depends on the shape of the document.
    private static func strings(in object: Any) -> [String] {
        switch object {
        case let text as String:
            return text.contains("```mermaid") ? [text] : []
        case let array as [Any]:
            return array.flatMap { strings(in: $0) }
        case let dictionary as [String: Any]:
            return dictionary.values.flatMap { strings(in: $0) }
        default:
            return []
        }
    }
}

/// The two process questions both of the file routes ask, in one place.
enum ProcessTree {
    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 64)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return 0 }
            return proc_listchildpids(pid, base, Int32(pointer.count * MemoryLayout<pid_t>.stride))
        }
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    /// `PROC_PIDT_SHORTBSDINFO` rather than `proc_name`, which measured zero for every process here
    /// including the `login` the walk has to pass through.
    static func name(of pid: pid_t) -> String? {
        var info = proc_bsdshortinfo()
        let size = MemoryLayout<proc_bsdshortinfo>.size
        let got = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, $0, Int32(size))
        }
        guard got == Int32(size) else { return nil }
        let name = withUnsafePointer(to: &info.pbsi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
        }
        return name.isEmpty ? nil : name
    }

    static func openFiles(of pid: pid_t) -> [String] {
        let sizing = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sizing > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(sizing) + MemoryLayout<proc_fdinfo>.stride * 8)
        let written = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return 0 }
            return proc_pidinfo(pid, PROC_PIDLISTFDS, 0, base, Int32(raw.count))
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<proc_fdinfo>.stride
        var paths: [String] = []
        buffer.withUnsafeBytes { raw in
            let descriptors = raw.bindMemory(to: proc_fdinfo.self)
            for index in 0..<min(count, descriptors.count) {
                guard descriptors[index].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
                var info = vnode_fdinfowithpath()
                let size = MemoryLayout<vnode_fdinfowithpath>.size
                let got = withUnsafeMutablePointer(to: &info) {
                    proc_pidfdinfo(pid, descriptors[index].proc_fd, PROC_PIDFDVNODEPATHINFO, $0, Int32(size))
                }
                guard got == Int32(size) else { continue }
                let path = withUnsafePointer(to: &info.pvip.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                if !path.isEmpty { paths.append(path) }
            }
        }
        return paths
    }
}
