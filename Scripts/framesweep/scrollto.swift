import ApplicationServices
import Foundation

// Moves a terminal's view by its own scroll bar, which is how a reader looks back at something that
// has gone past. Synthetic wheel events do not move Ghostty; this does.
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? {
    var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute as String) as? [AnyObject] ?? [])
        .filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
        .map { unsafeDowncast($0, to: AXUIElement.self) }
}
let pid = pid_t(CommandLine.arguments[1])!
let value = Double(CommandLine.arguments[2])!
let app = AXUIElementCreateApplication(pid)
guard let windows = attr(app, kAXWindowsAttribute as String) as? [AnyObject], let first = windows.first
else { print("no window"); exit(1) }
var queue = [unsafeDowncast(first, to: AXUIElement.self)]
while let element = queue.popLast() {
    if (attr(element, kAXRoleAttribute as String) as? String) == "AXScrollArea",
       let bar = attr(element, "AXVerticalScrollBar") {
        let target = unsafeDowncast(bar, to: AXUIElement.self)
        let set = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, value as CFTypeRef)
        print("scroll bar set to \(value): \(set == .success ? "ok" : "err \(set.rawValue)")")
        exit(set == .success ? 0 : 1)
    }
    queue.append(contentsOf: children(element))
}
print("no scroll bar")
exit(1)
