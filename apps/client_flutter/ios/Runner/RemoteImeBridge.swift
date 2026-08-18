import Flutter
import UIKit

final class AppleRemoteImeBridge: NSObject, FlutterStreamHandler {
  private static let methodChannelName =
    "com.crossdesktopremote.cross_desktop_remote/remote_ime"
  private static let eventChannelName =
    "com.crossdesktopremote.cross_desktop_remote/remote_ime_events"

  private let inputView = RemoteImeTextView()
  private var activeClientId: String?
  private var eventSink: FlutterEventSink?
  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?

  init(binaryMessenger: FlutterBinaryMessenger) {
    super.init()
    inputView.onEvent = { [weak self] event in
      guard let self, let clientId = self.activeClientId else { return }
      var payload = event
      payload["clientId"] = clientId
      self.eventSink?(payload)
    }

    let methodChannel = FlutterMethodChannel(
      name: Self.methodChannelName,
      binaryMessenger: binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    let eventChannel = FlutterEventChannel(
      name: Self.eventChannelName,
      binaryMessenger: binaryMessenger
    )
    eventChannel.setStreamHandler(self)
    self.methodChannel = methodChannel
    self.eventChannel = eventChannel
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let clientId = arguments["clientId"] as? String,
          !clientId.isEmpty else {
      result(FlutterError(
        code: "invalid_client",
        message: "Remote IME clientId is required",
        details: nil
      ))
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(FlutterError(
          code: "bridge_unavailable",
          message: "Remote IME bridge is unavailable",
          details: nil
        ))
        return
      }
      switch call.method {
      case "show":
        guard let hostView = self.currentHostView() else {
          result(FlutterError(
            code: "host_view_unavailable",
            message: "Cannot locate the active Flutter view",
            details: nil
          ))
          return
        }
        self.activeClientId = clientId
        self.inputView.immediatePinyinCommit =
          arguments["immediatePinyinCommit"] as? Bool ?? true
        self.inputView.attach(to: hostView)
        self.inputView.cancelComposition()
        result(self.inputView.becomeFirstResponder())
      case "hide":
        guard self.activeClientId == clientId else {
          result(nil)
          return
        }
        self.inputView.cancelComposition()
        self.inputView.resignFirstResponder()
        self.activeClientId = nil
        result(nil)
      case "reset":
        guard self.activeClientId == clientId else {
          result(nil)
          return
        }
        self.inputView.cancelComposition()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func currentHostView() -> UIView? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    let window = windows.first(where: { $0.isKeyWindow })
      ?? windows.first(where: { !$0.isHidden && $0.windowLevel == .normal })
    return window?.rootViewController?.view
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

private final class RemoteImeTextView: UITextView {
  var immediatePinyinCommit = true
  var onEvent: (([String: Any]) -> Void)?

  private var suppressUnmarkCommit = false
  private var compositionGeneration = 0

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    backgroundColor = .clear
    textColor = .clear
    tintColor = .clear
    alpha = 0.01
    isEditable = true
    isSelectable = true
    isScrollEnabled = false
    autocorrectionType = .yes
    spellCheckingType = .yes
    smartDashesType = .no
    smartQuotesType = .no
    smartInsertDeleteType = .no
    keyboardType = .default
    returnKeyType = .default
    enablesReturnKeyAutomatically = false
    accessibilityElementsHidden = true
  }

  func attach(to hostView: UIView) {
    if superview !== hostView {
      removeFromSuperview()
      hostView.addSubview(self)
    }
    frame = CGRect(
      x: max(0, hostView.bounds.maxX - 1),
      y: max(0, hostView.bounds.maxY - 1),
      width: 1,
      height: 1
    )
    autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
  }

  override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    let previous = currentMarkedText
    super.setMarkedText(markedText, selectedRange: selectedRange)
    compositionGeneration += 1
    let generation = compositionGeneration
    let current = currentMarkedText ?? ""
    emitComposition(current)
    emitDiagnostic(name: "setMarkedText", markedText: current)

    guard immediatePinyinCommit,
          RemoteImeClassifier.shouldCommitPinyinCandidate(
            previous: previous,
            current: current
          ) else { return }

    DispatchQueue.main.async { [weak self] in
      guard let self,
            self.isFirstResponder,
            self.compositionGeneration == generation,
            self.currentMarkedText == current else { return }
      self.commitCurrentMarkedText(reason: "pinyinCandidate")
    }
  }

  override func unmarkText() {
    let committed = currentMarkedText
    super.unmarkText()
    compositionGeneration += 1
    emitDiagnostic(name: "unmarkText", markedText: committed ?? "")
    guard !suppressUnmarkCommit,
          let committed,
          !committed.isEmpty else {
      emitComposition("")
      return
    }
    emitCommit(committed, reason: "unmarkText")
    clearEditingBuffer()
  }

  override func insertText(_ text: String) {
    super.insertText(text)
    compositionGeneration += 1
    emitDiagnostic(name: "insertText", markedText: text)
    if text == "\n" {
      emitKey("Enter")
    } else if text == "\t" {
      emitKey("Tab")
    } else if !text.isEmpty {
      emitCommit(text, reason: "insertText")
    }
    clearEditingBuffer()
  }

  override func deleteBackward() {
    if markedTextRange != nil {
      super.deleteBackward()
      compositionGeneration += 1
      let current = currentMarkedText ?? ""
      emitComposition(current)
      emitDiagnostic(name: "deleteMarkedText", markedText: current)
      return
    }
    clearEditingBuffer()
    emitDiagnostic(name: "deleteBackward", markedText: "")
    emitKey("Backspace")
  }

  func cancelComposition() {
    compositionGeneration += 1
    suppressUnmarkCommit = true
    if markedTextRange != nil {
      super.unmarkText()
    }
    suppressUnmarkCommit = false
    clearEditingBuffer()
  }

  private func commitCurrentMarkedText(reason: String) {
    guard let committed = currentMarkedText, !committed.isEmpty else { return }
    suppressUnmarkCommit = true
    super.unmarkText()
    suppressUnmarkCommit = false
    compositionGeneration += 1
    emitDiagnostic(name: reason, markedText: committed)
    emitCommit(committed, reason: reason)
    clearEditingBuffer()
  }

  private var currentMarkedText: String? {
    guard let range = markedTextRange else { return nil }
    return text(in: range)
  }

  private func clearEditingBuffer() {
    text = ""
    selectedRange = NSRange(location: 0, length: 0)
    emitComposition("")
  }

  private func emitComposition(_ text: String) {
    onEvent?([
      "type": "composition",
      "compositionLength": text.utf16.count
    ])
  }

  private func emitCommit(_ text: String, reason: String) {
    onEvent?([
      "type": "commit",
      "text": text,
      "reason": reason
    ])
  }

  private func emitKey(_ key: String) {
    onEvent?([
      "type": "key",
      "key": key
    ])
  }

  private func emitDiagnostic(name: String, markedText: String) {
    onEvent?([
      "type": "diagnostic",
      "name": name,
      "markedLength": markedText.utf16.count,
      "containsCjk": RemoteImeClassifier.containsCjk(markedText)
    ])
  }
}

enum RemoteImeClassifier {
  static func shouldCommitPinyinCandidate(
    previous: String?,
    current: String
  ) -> Bool {
    guard let previous, !previous.isEmpty else { return false }
    return containsAsciiLetter(previous)
      && !containsCjk(previous)
      && containsCjk(current)
      && !containsAsciiLetter(current)
  }

  static func containsAsciiLetter(_ text: String) -> Bool {
    text.unicodeScalars.contains(where: { scalar in
      (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    })
  }

  static func containsCjk(_ text: String) -> Bool {
    text.unicodeScalars.contains(where: { scalar in
      switch scalar.value {
      case 0x3400...0x9FFF, 0xF900...0xFAFF,
           0x20000...0x2A6DF, 0x2A700...0x2FA1F:
        true
      default:
        false
      }
    })
  }
}
