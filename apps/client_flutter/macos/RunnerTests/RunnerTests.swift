import Cocoa
import FlutterMacOS
import XCTest
@testable import cross_desktop_remote

class RunnerTests: XCTestCase {

  func testAbsolutePointerMappingUsesTheLastValidDisplayPixel() {
    let bounds = CGRect(x: -1920, y: 120, width: 1920, height: 1080)

    XCTAssertEqual(
      crossDesktopRemoteAbsolutePointerPosition(
        normalizedX: 0,
        normalizedY: 0,
        displayBounds: bounds
      ),
      CGPoint(x: -1920, y: 120)
    )
    XCTAssertEqual(
      crossDesktopRemoteAbsolutePointerPosition(
        normalizedX: 1,
        normalizedY: 1,
        displayBounds: bounds
      ),
      CGPoint(x: -1, y: 1199)
    )
  }

  func testAbsolutePointerMappingClampsOutOfRangeInput() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)

    XCTAssertEqual(
      crossDesktopRemoteAbsolutePointerPosition(
        normalizedX: -0.5,
        normalizedY: 2,
        displayBounds: bounds
      ),
      CGPoint(x: 0, y: 49)
    )
  }

}
