import ApplicationServices
import CoreGraphics
import Foundation

/// The accessibility reads FlowPeek's two AX routes share, each one checked against a wall clock.
///
/// Every call here is a synchronous message to another process, and an application that is wedged
/// answers only when its messaging timeout expires -- so the clock is read immediately before each
/// message rather than once per node. That is the whole reason these take a deadline: the pointer
/// route bounds a descent through hundreds of nodes with it, and the terminal route bounds a
/// binary search over a scrollback.
///
/// Free functions rather than a reader object because the deadline belongs to one read, not to a
/// long-lived thing: each route computes its own budget when it starts and spends it as it goes.
enum AccessibilityRead {
    /// The raw value, for the attributes FlowPeek hands straight back as a parameter -- a text
    /// marker range is opaque and is only ever passed to `AXBoundsForTextMarkerRange`.
    static func attribute(_ element: AXUIElement, _ attribute: String, before deadline: Date) -> CFTypeRef? {
        guard Date() < deadline else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ name: String, before deadline: Date) -> AXUIElement? {
        guard let value = attribute(element, name, before: deadline),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func string(_ element: AXUIElement, _ name: String, before deadline: Date) -> String? {
        guard let value = attribute(element, name, before: deadline) else { return nil }
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }

    /// `AXNumberOfCharacters` arrives as a `CFNumber`, and is the one way to ask how big a buffer
    /// is without asking for the buffer.
    static func number(_ element: AXUIElement, _ name: String, before deadline: Date) -> Int? {
        guard let value = attribute(element, name, before: deadline) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func double(_ element: AXUIElement, _ name: String, before deadline: Date) -> Double? {
        guard let value = attribute(element, name, before: deadline) else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    static func rect(_ element: AXUIElement, _ name: String, before deadline: Date) -> CGRect? {
        cgRect(attribute(element, name, before: deadline))
    }

    static func size(_ element: AXUIElement, _ name: String, before deadline: Date) -> CGSize? {
        guard let value = attribute(element, name, before: deadline),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// A character range arrives as a `CFRange` counting UTF-16 code units of the element's own
    /// value, which is the unit every offset in this app's text handling is expressed in.
    static func range(_ element: AXUIElement, _ name: String, before deadline: Date) -> CFRange? {
        guard let value = attribute(element, name, before: deadline),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        // A negative location is not a position in any buffer.
        guard range.location >= 0 else { return nil }
        return range
    }

    // MARK: - Parameterized

    static func attribute(
        _ element: AXUIElement,
        parameterized name: String,
        argument: CFTypeRef,
        before deadline: Date
    ) -> CFTypeRef? {
        guard Date() < deadline else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            name as CFString,
            argument,
            &value
        ) == .success else { return nil }
        return value
    }

    static func string(
        _ element: AXUIElement,
        parameterized name: String,
        argument: CFTypeRef,
        before deadline: Date
    ) -> String? {
        guard let value = attribute(element, parameterized: name, argument: argument, before: deadline) else {
            return nil
        }
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }

    static func number(
        _ element: AXUIElement,
        parameterized name: String,
        argument: CFTypeRef,
        before deadline: Date
    ) -> Int? {
        guard let value = attribute(element, parameterized: name, argument: argument, before: deadline) else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    static func rect(
        _ element: AXUIElement,
        parameterized name: String,
        argument: CFTypeRef,
        before deadline: Date
    ) -> CGRect? {
        cgRect(attribute(element, parameterized: name, argument: argument, before: deadline))
    }

    static func range(
        _ element: AXUIElement,
        parameterized name: String,
        argument: CFTypeRef,
        before deadline: Date
    ) -> CFRange? {
        guard let value = attribute(element, parameterized: name, argument: argument, before: deadline),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        guard range.location >= 0 else { return nil }
        return range
    }

    // MARK: - Arguments

    /// The DOM classes a web-view element carries, which is how a terminal's row list is told apart
    /// from every other list in an Electron window.
    static func classList(_ element: AXUIElement, before deadline: Date) -> [String] {
        attribute(element, "AXDOMClassList", before: deadline) as? [String] ?? []
    }

    /// All the text an element spans, read through the marker range it reports for itself.
    ///
    /// Chromium's own text protocol, and the only one that answers here. A web-view container
    /// reports `AXNumberOfCharacters` as zero -- its text lives in descendants -- so the
    /// range-and-offset reads the other terminals use come back empty, while two marker calls come
    /// back with the lot. Measured against Orca: 0.33 ms for a whole viewport, against 4.1 ms to
    /// walk the same rows child by child.
    static func markerText(_ element: AXUIElement, before deadline: Date) -> String? {
        guard let range = attribute(
            element,
            parameterized: "AXTextMarkerRangeForUIElement",
            argument: element,
            before: deadline
        ) else { return nil }
        return string(element, parameterized: "AXStringForTextMarkerRange", argument: range, before: deadline)
    }

    static func argument(_ range: NSRange) -> CFTypeRef? {
        var value = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &value)
    }

    static func argument(_ point: CGPoint) -> CFTypeRef? {
        var value = point
        return AXValueCreate(.cgPoint, &value)
    }

    // MARK: - Unwrapping

    static func cgRect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
