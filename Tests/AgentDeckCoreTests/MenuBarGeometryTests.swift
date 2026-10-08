import AgentDeckCore
import CoreGraphics
import Testing

@Suite struct MenuBarGeometryTests {
    /// A 1512-point-wide MacBook screen: the notch spans x 656–856 at the top.
    let notched = MenuBarGeometry.Display(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        leftOfNotch: CGRect(x: 0, y: 950, width: 656, height: 32),
        rightOfNotch: CGRect(x: 856, y: 950, width: 656, height: 32)
    )
    let external = MenuBarGeometry.Display(frame: CGRect(x: 1512, y: 0, width: 2048, height: 864))

    @Test func anItemRightOfTheNotchIsVisible() {
        #expect(!MenuBarGeometry.isHidden(item: CGRect(x: 1100, y: 950, width: 30, height: 32), displays: [notched]))
    }

    @Test func anItemBehindTheNotchIsHidden() {
        #expect(MenuBarGeometry.isHidden(item: CGRect(x: 700, y: 950, width: 30, height: 32), displays: [notched]))
        // Mostly behind the notch still counts as hidden.
        #expect(MenuBarGeometry.isHidden(item: CGRect(x: 840, y: 950, width: 30, height: 32), displays: [notched]))
    }

    @Test func anItemOffEveryScreenIsHidden() {
        #expect(MenuBarGeometry.isHidden(item: CGRect(x: -40, y: 950, width: 30, height: 32), displays: [notched, external]))
    }

    @Test func screensWithoutANotchOnlyNeedTheItemOnScreen() {
        #expect(!MenuBarGeometry.isHidden(item: CGRect(x: 2000, y: 832, width: 30, height: 32), displays: [notched, external]))
    }
}
