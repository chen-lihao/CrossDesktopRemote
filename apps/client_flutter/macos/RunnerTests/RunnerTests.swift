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

  func testCommandShortcutPostsBalancedModifierSequence() {
    let keyboard = CrossDesktopRemoteSyntheticKeyboard()
    var strokes: [CrossDesktopRemoteSyntheticKeyStroke] = []

    XCTAssertTrue(
      keyboard.performShortcut(
        keyCode: 9,
        modifiers: ["command"],
        post: {
          strokes.append($0)
          return true
        }
      )
    )
    XCTAssertEqual(
      strokes,
      [
        .init(keyCode: 55, keyDown: true, flags: .maskCommand),
        .init(keyCode: 9, keyDown: true, flags: .maskCommand),
        .init(keyCode: 9, keyDown: false, flags: .maskCommand),
        .init(keyCode: 55, keyDown: false, flags: []),
      ]
    )
    XCTAssertTrue(keyboard.pressedKeyCodes.isEmpty)
    XCTAssertTrue(keyboard.pressedModifierKeyCodes.isEmpty)
  }

  func testKeyPairReleasesSyntheticModifier() {
    let keyboard = CrossDesktopRemoteSyntheticKeyboard()
    var strokes: [CrossDesktopRemoteSyntheticKeyStroke] = []
    let recorder: CrossDesktopRemoteSyntheticKeyboard.Poster = {
      strokes.append($0)
      return true
    }

    XCTAssertTrue(
      keyboard.handleKey(
        keyCode: 8,
        phase: "down",
        modifiers: ["command"],
        post: recorder
      )
    )
    XCTAssertTrue(
      keyboard.handleKey(
        keyCode: 8,
        phase: "up",
        modifiers: ["command"],
        post: recorder
      )
    )
    XCTAssertEqual(
      strokes,
      [
        .init(keyCode: 55, keyDown: true, flags: .maskCommand),
        .init(keyCode: 8, keyDown: true, flags: .maskCommand),
        .init(keyCode: 8, keyDown: false, flags: .maskCommand),
        .init(keyCode: 55, keyDown: false, flags: []),
      ]
    )
  }

  func testReleaseClosesInterruptedKeyChord() {
    let keyboard = CrossDesktopRemoteSyntheticKeyboard()
    var strokes: [CrossDesktopRemoteSyntheticKeyStroke] = []
    let recorder: CrossDesktopRemoteSyntheticKeyboard.Poster = {
      strokes.append($0)
      return true
    }

    XCTAssertTrue(
      keyboard.handleKey(
        keyCode: 9,
        phase: "down",
        modifiers: ["command"],
        post: recorder
      )
    )
    XCTAssertTrue(keyboard.release(post: recorder))
    XCTAssertEqual(
      Array(strokes.suffix(2)),
      [
        .init(keyCode: 9, keyDown: false, flags: .maskCommand),
        .init(keyCode: 55, keyDown: false, flags: []),
      ]
    )
    XCTAssertTrue(keyboard.pressedKeyCodes.isEmpty)
    XCTAssertTrue(keyboard.pressedModifierKeyCodes.isEmpty)
  }

  func testShortcutPostingFailureStillReleasesCommand() {
    let keyboard = CrossDesktopRemoteSyntheticKeyboard()
    var strokes: [CrossDesktopRemoteSyntheticKeyStroke] = []

    XCTAssertFalse(
      keyboard.performShortcut(
        keyCode: 9,
        modifiers: ["command"],
        post: { stroke in
          strokes.append(stroke)
          return !(stroke.keyCode == 9 && stroke.keyDown)
        }
      )
    )
    XCTAssertEqual(
      strokes.last,
      .init(keyCode: 55, keyDown: false, flags: [])
    )
    XCTAssertTrue(keyboard.pressedKeyCodes.isEmpty)
    XCTAssertTrue(keyboard.pressedModifierKeyCodes.isEmpty)
  }

  func testPointerModifierSnapshotCanBeReconciledIndependently() {
    let keyboard = CrossDesktopRemoteSyntheticKeyboard()
    var strokes: [CrossDesktopRemoteSyntheticKeyStroke] = []
    let recorder: CrossDesktopRemoteSyntheticKeyboard.Poster = {
      strokes.append($0)
      return true
    }

    XCTAssertTrue(keyboard.setModifiers(["command", "shift"], post: recorder))
    XCTAssertEqual(keyboard.pressedModifierKeyCodes, Set([55, 56]))
    XCTAssertTrue(keyboard.setModifiers([], post: recorder))
    XCTAssertTrue(keyboard.pressedModifierKeyCodes.isEmpty)
    XCTAssertEqual(
      strokes,
      [
        .init(keyCode: 55, keyDown: true, flags: .maskCommand),
        .init(
          keyCode: 56,
          keyDown: true,
          flags: [.maskCommand, .maskShift]
        ),
        .init(keyCode: 56, keyDown: false, flags: .maskCommand),
        .init(keyCode: 55, keyDown: false, flags: []),
      ]
    )
  }

}
