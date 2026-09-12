import AppKit
import Foundation

// Finds the horizontal bands of a given colour in a screenshot, in points, relative to the
// capture's origin. Used to locate the marker rows a test window printed, so the frame FlowPeek
// drew can be checked against where the diagram actually is rather than against an assumption.
struct Band { let top: Double; let bottom: Double }

func bands(in image: NSBitmapImageRep, matching target: (UInt8, UInt8, UInt8), scale: Double) -> [Band] {
    guard let data = image.bitmapData else { return [] }
    let bytesPerRow = image.bytesPerRow
    let samples = image.samplesPerPixel
    var rowsHit: [Int] = []
    for y in 0..<image.pixelsHigh {
        var hits = 0
        var x = 0
        while x < image.pixelsWide {
            let o = y * bytesPerRow + x * samples
            let r = data[o], g = data[o + 1], b = data[o + 2]
            if abs(Int(r) - Int(target.0)) < 70, abs(Int(g) - Int(target.1)) < 70,
               abs(Int(b) - Int(target.2)) < 70 { hits += 1 }
            x += 2
        }
        // A marker row is a wide band, not a stray pixel.
        if hits > image.pixelsWide / 20 { rowsHit.append(y) }
    }
    // A band is one row of the terminal, and a glyph or the outline's own hairline can leave a gap
    // of a pixel or two inside it. Runs closer together than that are the same band: splitting one
    // put the measured row pitch out by seven points in a capture where the outline crossed it.
    var found: [Band] = []
    var run: [Int] = []
    func close() {
        guard run.count > 2 else { run = []; return }
        found.append(Band(top: Double(run[0]) / scale, bottom: Double(run.last! + 1) / scale))
        run = []
    }
    for y in rowsHit {
        if let last = run.last, y - last <= 10 { run.append(y) } else { close(); run = [y] }
    }
    close()
    return found
}

let path = CommandLine.arguments[1]
let scale = Double(CommandLine.arguments[2]) ?? 2
guard let data = FileManager.default.contents(atPath: path),
      let loaded = NSBitmapImageRep(data: data),
      let rep = loaded.converting(to: .sRGB, renderingIntent: .default) else {
    print("cannot read"); exit(1)
}
if let probe = CommandLine.arguments.first(where: { $0.hasPrefix("--probe=") })?.dropFirst(8) {
    let parts = probe.split(separator: ",").compactMap { Int($0) }
    if parts.count == 3, let d = rep.bitmapData {
        for y in parts[1]...parts[2] {
            let o = y * rep.bytesPerRow + parts[0] * rep.samplesPerPixel
            print("y=\(y) rgb=\(d[o]),\(d[o+1]),\(d[o+2])")
        }
    }
    exit(0)
}
if CommandLine.arguments.contains("--sample") {
    if let d = rep.bitmapData {
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 40)) {
            let o = y * rep.bytesPerRow + (rep.pixelsWide / 2) * rep.samplesPerPixel
            print("y=\(y) rgb=\(d[o]),\(d[o+1]),\(d[o+2]) samples=\(rep.samplesPerPixel)")
        }
    }
}
// The hint tint, so the chip and the frame's own stroke can be located too. Passed in because the
// reader picks it; the sweep passes whatever the build under test is set to.
let tint: (UInt8, UInt8, UInt8) = {
    guard let hex = CommandLine.arguments.first(where: { $0.hasPrefix("--tint=") })?.dropFirst(7),
          hex.count == 6, let value = UInt32(hex, radix: 16) else { return (0, 0x9E, 0x73) }
    return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
}()

/// Where the chip is: the tallest block of tinted pixels, which is the filled pill.
///
/// Height rather than width is what tells it from the frame, and getting that wrong was worth a
/// wrong answer: the outline's own hairline runs the full width of the terminal, so picking the
/// longest run of tint picked the frame's edge and reported the chip a whole diagram away from
/// where it is. The pill is twenty points tall; a hairline is one or two.
func chip(in image: NSBitmapImageRep, matching target: (UInt8, UInt8, UInt8), scale: Double) -> (Double, Double, Double, Double)? {
    guard let data = image.bitmapData else { return nil }
    let bytes = image.bytesPerRow, samples = image.samplesPerPixel
    var spans: [Int: (Int, Int)] = [:]
    for y in 0..<image.pixelsHigh {
        var from = -1, to = -1, runStart = -1, longest = 0
        for x in 0..<image.pixelsWide {
            let o = y * bytes + x * samples
            let hit = abs(Int(data[o]) - Int(target.0)) < 60 && abs(Int(data[o + 1]) - Int(target.1)) < 60
                && abs(Int(data[o + 2]) - Int(target.2)) < 60
            if hit {
                if runStart < 0 { runStart = x }
                if x - runStart + 1 > longest { longest = x - runStart + 1; from = runStart; to = x }
            } else { runStart = -1 }
        }
        // Wide enough to be the pill, and not so wide it is the frame's own hairline running the
        // width of the terminal. Both bounds are load-bearing: without the upper one the finder
        // reported the frame's edge as the chip and put it a whole diagram away from where it is.
        // Any run wide enough not to be a glyph edge, and narrower than half the window so the
        // frame's own hairline is excluded. The pill's rows vary a lot -- its icon and its key cap
        // break the tint into pieces -- so the bar is low and the height filter below does the work.
        if longest > 16, longest < image.pixelsWide / 2 { spans[y] = (from, to) }
    }
    // Group the rows that have a wide run into vertical blocks, and take the tallest.
    var blocks: [(top: Int, bottom: Int, left: Int, right: Int)] = []
    for y in spans.keys.sorted() {
        let span = spans[y]!
        // Vertical adjacency alone. The pill has white text through the middle of it, so the
        // longest run in each of its rows starts at a different x -- grouping on that split the
        // chip into slivers and reported it five points tall instead of twenty.
        if var last = blocks.last, y - last.bottom <= 2 {
            last.bottom = y
            last.left = min(last.left, span.0)
            last.right = max(last.right, span.1)
            blocks[blocks.count - 1] = last
        } else {
            blocks.append((y, y, span.0, span.1))
        }
    }
    // A pill, not a hairline: at least eight pixels of height.
    // Twenty points of pill against one or two of hairline; sixteen pixels is comfortably between.
    guard let pill = blocks.filter({ $0.bottom - $0.top >= 16 }).max(by: { ($0.bottom - $0.top) < ($1.bottom - $1.top) })
    else { return nil }
    return (Double(pill.left) / scale, Double(pill.top) / scale, Double(pill.right + 1) / scale, Double(pill.bottom + 1) / scale)
}

let magenta = bands(in: rep, matching: (255, 0, 255), scale: scale)
let cyan = bands(in: rep, matching: (0, 255, 255), scale: scale)
let yellow = bands(in: rep, matching: (255, 255, 0), scale: scale)
print("magenta \(magenta.map { "\($0.top)-\($0.bottom)" }.joined(separator: ","))")
print("cyan \(cyan.map { "\($0.top)-\($0.bottom)" }.joined(separator: ","))")
print("yellow \(yellow.map { "\($0.top)-\($0.bottom)" }.joined(separator: ","))")
if let box = chip(in: rep, matching: tint, scale: scale) {
    print("chip \(box.0),\(box.1),\(box.2),\(box.3)")
} else {
    print("chip none")
}
