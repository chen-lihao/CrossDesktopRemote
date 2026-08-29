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

  func testMaterializedFileURLsRoundTripThroughPasteboard() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let firstURL = temporaryDirectory.appendingPathComponent("报告.txt")
    let secondURL = temporaryDirectory.appendingPathComponent("资料", isDirectory: true)
    try Data("clipboard".utf8).write(to: firstURL)
    try FileManager.default.createDirectory(
      at: secondURL,
      withIntermediateDirectories: false
    )

    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    XCTAssertTrue(
      crossDesktopRemoteWriteFileURLs(
        [firstURL, secondURL],
        to: pasteboard
      )
    )
    let fileURLs = try XCTUnwrap(
      pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL]
    )
    XCTAssertEqual(
      fileURLs.map(\.standardizedFileURL),
      [firstURL, secondURL].map(\.standardizedFileURL)
    )
    XCTAssertTrue(
      pasteboard.types?.contains(.fileURL) == true
    )
  }

}
