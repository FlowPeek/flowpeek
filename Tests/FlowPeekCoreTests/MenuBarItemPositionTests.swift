import XCTest
@testable import FlowPeekCore

/// Carrying the reader's own placement of the menu bar icon across a hiding. Tested because the
/// bug it fixes was invisible from the code: AppKit deletes the placement as the item is removed,
/// so the icon came back at the far left every time and undid an arrangement somebody had made on
/// purpose.
final class MenuBarItemPositionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "flowpeek.tests.menubarposition"
    private let key = MenuBarItemPosition.appKitPrefix + "Item-0"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    /// The whole cycle, in the order it really happens: read it while the item is still there,
    /// watch AppKit throw its own copy away, and put it back before the item returns.
    func testAPlacementSurvivesAppKitDeletingIt() {
        defaults.set(400, forKey: key)
        MenuBarItemPosition.remember(in: defaults)
        defaults.removeObject(forKey: key)
        XCTAssertNil(defaults.object(forKey: key))
        MenuBarItemPosition.restore(in: defaults)
        XCTAssertEqual(defaults.double(forKey: key), 400)
    }

    /// A whole number comes out of a property list as an `Int`, and a cast straight to `Double`
    /// answers nil for one. Getting this wrong loses every placement that is not a fraction, which
    /// is all of them.
    func testAWholeNumberIsNotDroppedOnTheWayThrough() {
        defaults.set(Int(302), forKey: key)
        MenuBarItemPosition.remember(in: defaults)
        defaults.removeObject(forKey: key)
        MenuBarItemPosition.restore(in: defaults)
        XCTAssertEqual(defaults.double(forKey: key), 302)
    }

    func testEveryItemUnderThePrefixIsCarried() {
        let second = MenuBarItemPosition.appKitPrefix + "Item-1"
        defaults.set(400, forKey: key)
        defaults.set(120.5, forKey: second)
        MenuBarItemPosition.remember(in: defaults)
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: second)
        MenuBarItemPosition.restore(in: defaults)
        XCTAssertEqual(defaults.double(forKey: key), 400)
        XCTAssertEqual(defaults.double(forKey: second), 120.5)
    }

    /// The reader moved the icon since. AppKit's answer is the newer one and must win.
    func testAFresherPlacementIsNeverOverwritten() {
        defaults.set(400, forKey: key)
        MenuBarItemPosition.remember(in: defaults)
        defaults.set(900, forKey: key)
        MenuBarItemPosition.restore(in: defaults)
        XCTAssertEqual(defaults.double(forKey: key), 900)
    }

    func testRememberingNothingLeavesNothingBehind() {
        MenuBarItemPosition.remember(in: defaults)
        XCTAssertNil(defaults.object(forKey: MenuBarItemPosition.storeKey))
        // And restoring from nothing is a no-op rather than a crash or a zero.
        MenuBarItemPosition.restore(in: defaults)
        XCTAssertNil(defaults.object(forKey: key))
    }

    /// Hiding twice in a row must not overwrite a good copy with the empty one AppKit leaves after
    /// the first hiding -- that would lose the placement on the second use of the gesture.
    func testASecondHidingDoesNotWipeTheCopy() {
        defaults.set(400, forKey: key)
        MenuBarItemPosition.remember(in: defaults)
        defaults.removeObject(forKey: key)
        MenuBarItemPosition.remember(in: defaults)
        MenuBarItemPosition.restore(in: defaults)
        XCTAssertEqual(defaults.double(forKey: key), 400)
    }
}
