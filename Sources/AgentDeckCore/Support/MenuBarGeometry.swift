import CoreGraphics

/// Where a menu bar item ended up. On a display with a notch, macOS places items that do not fit
/// behind the notch or off the screen instead of dropping them, so they exist but cannot be seen.
public enum MenuBarGeometry {
    public struct Display: Equatable, Sendable {
        public var frame: CGRect
        /// The menu bar area left and right of the notch (`NSScreen.auxiliaryTopLeftArea` and
        /// `auxiliaryTopRightArea`), or nil without a notch.
        public var leftOfNotch: CGRect?
        public var rightOfNotch: CGRect?

        public init(frame: CGRect, leftOfNotch: CGRect? = nil, rightOfNotch: CGRect? = nil) {
            self.frame = frame
            self.leftOfNotch = leftOfNotch
            self.rightOfNotch = rightOfNotch
        }

        /// The notch, as the gap between the two menu bar areas.
        var notch: CGRect? {
            guard let left = leftOfNotch, let right = rightOfNotch, right.minX > left.maxX else { return nil }
            return CGRect(x: left.maxX, y: min(left.minY, right.minY), width: right.minX - left.maxX,
                          height: max(left.height, right.height))
        }
    }

    /// True when the item is mostly behind a notch or beside every display. Only horizontal
    /// position counts: a menu bar that hides itself (auto-hide, full screen) moves its items above
    /// the screen, which is not what this is about. Without a notch there is nothing to check.
    public static func isHidden(item: CGRect, displays: [Display]) -> Bool {
        guard displays.contains(where: { $0.notch != nil }) else { return false }
        guard item.width > 0 else { return true }
        func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat { max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) }
        let visible = displays.map { display in
            overlap(display.frame, item) - (display.notch.map { overlap($0, item) } ?? 0)
        }.max() ?? 0
        return visible < item.width / 2
    }
}
