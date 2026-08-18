import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testPinyinCandidateTransitionCommitsImmediately() {
    XCTAssertTrue(
      RemoteImeClassifier.shouldCommitPinyinCandidate(
        previous: "nihao",
        current: "你好"
      )
    )
  }

  func testPartialPinyinCandidateDoesNotCommitEarly() {
    XCTAssertFalse(
      RemoteImeClassifier.shouldCommitPinyinCandidate(
        previous: "nihao",
        current: "你hao"
      )
    )
  }

  func testRepeatedCjkCompositionDoesNotDuplicateCommit() {
    XCTAssertFalse(
      RemoteImeClassifier.shouldCommitPinyinCandidate(
        previous: "你好",
        current: "你好"
      )
    )
  }

  func testExtendedCjkScalarIsDetected() {
    XCTAssertTrue(RemoteImeClassifier.containsCjk("𠀀"))
  }

}
