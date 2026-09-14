import Foundation

/// Where the reader put the menu bar icon, kept across a hiding.
///
/// Taking a status item out of the menu bar is, as far as AppKit is concerned, the same thing as
/// the reader dragging it away for good. Measured: while the icon is in the bar the app's defaults
/// hold `NSStatusItem Preferred Position Item-0 = 302`, and the moment it is taken out that key is
/// gone and a `NSStatusItem VisibleCC Item-0 = 0` stands in its place. Nothing is left to restore,
/// so the icon comes back wherever there is room -- the far left -- every single time.
///
/// That is not a small thing. A reader who has arranged their menu bar has done it deliberately,
/// and a feature that silently undoes the arrangement each time it is used is worse than one that
/// does not exist. So the position is copied out before the item goes and written back before it
/// returns.
///
/// Every key under that prefix is carried rather than the one that has been seen, because the part
/// after it names the status item and is AppKit's to choose, not ours to predict.
public enum MenuBarItemPosition {
    /// What AppKit files a status item's placement under. The part after it names the item and is
    /// AppKit's to choose, which is why everything under the prefix is carried rather than one key.
    public static let appKitPrefix = "NSStatusItem Preferred Position "
    /// Where the copy is kept: a key of ours, which nothing but this deletes.
    public static let storeKey = "flowpeek.menuBar.position"

    /// Copy what AppKit believes into somewhere it will not be deleted from. Must be called while
    /// the item is still in the menu bar: after it goes there is nothing left to read.
    public static func remember(in defaults: UserDefaults = .standard) {
        var found: [String: Double] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(appKitPrefix) {
            // Through `NSNumber` rather than a cast to `Double`: a whole number comes back out of a
            // property list as an `Int`, and `as? Double` on one of those quietly answers nil.
            guard let number = value as? NSNumber else { continue }
            found[key] = number.doubleValue
        }
        guard !found.isEmpty else { return }
        defaults.set(found, forKey: storeKey)
    }

    /// Put it back. Must be called before the item is created again, which is what AppKit reads it.
    public static func restore(in defaults: UserDefaults = .standard) {
        guard let stored = defaults.dictionary(forKey: storeKey) else { return }
        for (key, value) in stored {
            guard let number = value as? NSNumber else { continue }
            // Never over an answer AppKit already has: that one is newer, and would be the reader
            // having moved the icon since.
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(number.doubleValue, forKey: key)
        }
    }
}
