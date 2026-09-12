import CoreGraphics
import Foundation
// The rectangle FlowPeek is drawing right now, and the window under it.
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
func rect(_ w: [String: Any]) -> String {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return "\(b["X"] ?? 0),\(b["Y"] ?? 0),\(b["Width"] ?? 0),\(b["Height"] ?? 0)"
}
for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").contains("FlowPeek") {
    let name = w[kCGWindowName as String] as? String ?? ""
    guard name.isEmpty else { continue }   // the outline panel has no title
    print("outline \(rect(w))")
}
for w in list where (w[kCGWindowName as String] as? String ?? "").hasPrefix("FPSWEEP") {
    print("window \(rect(w))")
}
