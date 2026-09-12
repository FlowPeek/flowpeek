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
if CommandLine.arguments.contains("--sample") {
    if let d = rep.bitmapData {
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 40)) {
            let o = y * rep.bytesPerRow + (rep.pixelsWide / 2) * rep.samplesPerPixel
            print("y=\(y) rgb=\(d[o]),\(d[o+1]),\(d[o+2]) samples=\(rep.samplesPerPixel)")
        }
    }
}
let magenta = bands(in: rep, matching: (255, 0, 255), scale: scale)
let cyan = bands(in: rep, matching: (0, 255, 255), scale: scale)
let yellow = bands(in: rep, matching: (255, 255, 0), scale: scale)
print("magenta \(magenta.map { "\($0.top)-\($0.bottom)" }.joined(separator: ","))")
print("cyan \(cyan.map { "\($0.top)-\($0.bottom)" }.joined(separator: ","))")
print("yellow \(yellow.map { "\($0.top)-\($0.bottom)" }.joined(separator: ","))")
