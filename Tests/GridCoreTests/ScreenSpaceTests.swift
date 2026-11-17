import CoreGraphics
import Testing
@testable import GridCore

@Suite struct ScreenSpaceTests {
    private let primaryHeight: CGFloat = 900

    @Test func roundTripOnPrimaryScreen() {
        let rect = CGRect(x: 100, y: 50, width: 400, height: 300)
        let ax = ScreenSpace.toAX(rect, primaryHeight: primaryHeight)
        #expect(ax == CGRect(x: 100, y: 550, width: 400, height: 300))
        #expect(ScreenSpace.fromAX(ax, primaryHeight: primaryHeight) == rect)
    }

    @Test func roundTripOnScreenToTheLeftWithNegativeX() {
        let rect = CGRect(x: -1440, y: 0, width: 1440, height: 875)
        let ax = ScreenSpace.toAX(rect, primaryHeight: primaryHeight)
        #expect(ax.minX == -1440)
        #expect(ScreenSpace.fromAX(ax, primaryHeight: primaryHeight) == rect)
    }

    @Test func roundTripOnScreenAboveWithNegativeAXY() {
        let rect = CGRect(x: 0, y: 900, width: 1440, height: 800)
        let ax = ScreenSpace.toAX(rect, primaryHeight: primaryHeight)
        #expect(ax.minY == -800)
        #expect(ScreenSpace.fromAX(ax, primaryHeight: primaryHeight) == rect)
    }
}
