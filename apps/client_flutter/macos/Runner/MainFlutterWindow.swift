import Cocoa
import ApplicationServices
import FlutterMacOS
import dnssd

class MainFlutterWindow: NSWindow {
  private var inputChannel: FlutterMethodChannel?
  private var lanDiscoveryBridge: AppleLanDiscoveryBridge?
  private var pressedMouseButtons: Set<String> = []

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerInputChannel(binaryMessenger: flutterViewController.engine.binaryMessenger)
    lanDiscoveryBridge = AppleLanDiscoveryBridge(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }

  private func registerInputChannel(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.crossdesktopremote.cross_desktop_remote/input",
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "window_unavailable", message: "Mac window is unavailable", details: nil))
        return
      }

      switch call.method {
      case "requestInputAccess":
        result(self.requestInputAccess())
      case "checkInputAccess":
        result(self.hasInputAccess())
      case "openInputSettings":
        result(self.openInputSettings())
      case "listDisplays":
        result(self.listDisplays())
      case "pointer":
        self.handlePointer(arguments: call.arguments, result: result)
      case "keyboard":
        self.handleKeyboard(arguments: call.arguments, result: result)
      case "releasePointerButtons":
        self.releasePointerButtons()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    inputChannel = channel
  }

  private func hasInputAccess() -> Bool {
    if #available(macOS 10.15, *) {
      return CGPreflightPostEventAccess()
    }
    return AXIsProcessTrusted()
  }

  private func requestInputAccess() -> Bool {
    if #available(macOS 10.15, *) {
      return CGRequestPostEventAccess()
    }
    let options: NSDictionary = [
      kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ]
    return AXIsProcessTrustedWithOptions(options)
  }

  private func openInputSettings() -> Bool {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ) else {
      return false
    }
    return NSWorkspace.shared.open(url)
  }

  private func handlePointer(arguments: Any?, result: FlutterResult) {
    guard hasInputAccess() else {
      result(FlutterError(
        code: "input_permission_required",
        message: "请在系统设置中允许本机发布鼠标和键盘事件",
        details: nil
      ))
      return
    }
    guard
      let values = arguments as? [String: Any],
      let phase = values["phase"] as? String,
      let normalizedX = values["x"] as? Double,
      let normalizedY = values["y"] as? Double,
      let displayIdValue = values["displayId"] as? String,
      let displayId = UInt32(displayIdValue),
      activeDisplayIds().contains(displayId)
    else {
      result(FlutterError(code: "invalid_pointer", message: "Invalid pointer event", details: nil))
      return
    }

    let displayBounds = CGDisplayBounds(displayId)
    let mode = values["mode"] as? String ?? "absolute"
    let position: CGPoint
    if mode == "relative" {
      let current = CGEvent(source: nil)?.location ?? CGPoint(
        x: displayBounds.midX,
        y: displayBounds.midY
      )
      let movementX = values["movementX"] as? Double ?? 0
      let movementY = values["movementY"] as? Double ?? 0
      position = CGPoint(
        x: min(max(current.x + movementX, displayBounds.minX), displayBounds.maxX - 1),
        y: min(max(current.y + movementY, displayBounds.minY), displayBounds.maxY - 1)
      )
    } else {
      position = CGPoint(
        x: displayBounds.origin.x + displayBounds.width * min(max(normalizedX, 0), 1),
        y: displayBounds.origin.y + displayBounds.height * min(max(normalizedY, 0), 1)
      )
    }

    if phase == "scroll" {
      let deltaX = (values["deltaX"] as? Double) ?? 0
      let deltaY = (values["deltaY"] as? Double) ?? 0
      let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 2,
        wheel1: Int32(deltaY.rounded()),
        wheel2: Int32(deltaX.rounded()),
        wheel3: 0
      )
      event?.post(tap: .cghidEventTap)
      result(nil)
      return
    }

    let buttonName = values["button"] as? String ?? "left"
    let button: CGMouseButton = buttonName == "right" ? .right : .left
    let mouseType: CGEventType
    switch phase {
    case "down":
      pressedMouseButtons.insert(buttonName)
      mouseType = button == .right ? .rightMouseDown : .leftMouseDown
    case "up":
      pressedMouseButtons.remove(buttonName)
      mouseType = button == .right ? .rightMouseUp : .leftMouseUp
    default:
      if pressedMouseButtons.contains("right") {
        mouseType = .rightMouseDragged
      } else if pressedMouseButtons.contains("left") {
        mouseType = .leftMouseDragged
      } else {
        mouseType = .mouseMoved
      }
    }
    let event = CGEvent(
      mouseEventSource: nil,
      mouseType: mouseType,
      mouseCursorPosition: position,
      mouseButton: button
    )
    event?.setIntegerValueField(
      .mouseEventClickState,
      value: Int64(values["clickCount"] as? Int ?? 1)
    )
    event?.post(tap: .cghidEventTap)
    result(nil)
  }

  private func handleKeyboard(arguments: Any?, result: FlutterResult) {
    guard hasInputAccess() else {
      result(FlutterError(
        code: "input_permission_required",
        message: "请在系统设置中允许本机发布鼠标和键盘事件",
        details: nil
      ))
      return
    }
    guard let values = arguments as? [String: Any], let type = values["type"] as? String else {
      result(FlutterError(code: "invalid_keyboard", message: "Invalid keyboard event", details: nil))
      return
    }

    if type == "text" {
      guard let text = values["text"] as? String, !text.isEmpty, text.utf16.count <= 256 else {
        result(FlutterError(code: "invalid_text", message: "Invalid text input", details: nil))
        return
      }
      postUnicodeText(text)
      result(nil)
      return
    }

    guard
      let keyName = values["key"] as? String,
      let keyCode = macKeyCode(for: keyName),
      let phase = values["phase"] as? String
    else {
      result(FlutterError(code: "unsupported_key", message: "Unsupported keyboard key", details: nil))
      return
    }
    let event = CGEvent(
      keyboardEventSource: nil,
      virtualKey: keyCode,
      keyDown: phase == "down"
    )
    event?.flags = modifierFlags(values["modifiers"] as? [String] ?? [])
    event?.post(tap: .cghidEventTap)
    result(nil)
  }

  private func releasePointerButtons() {
    let position = CGEvent(source: nil)?.location ?? .zero
    if pressedMouseButtons.contains("left") {
      CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: position,
        mouseButton: .left
      )?.post(tap: .cghidEventTap)
    }
    if pressedMouseButtons.contains("right") {
      CGEvent(
        mouseEventSource: nil,
        mouseType: .rightMouseUp,
        mouseCursorPosition: position,
        mouseButton: .right
      )?.post(tap: .cghidEventTap)
    }
    pressedMouseButtons.removeAll()
  }

  private func postUnicodeText(_ text: String) {
    let utf16 = Array(text.utf16)
    for isKeyDown in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isKeyDown)
      utf16.withUnsafeBufferPointer { buffer in
        guard let address = buffer.baseAddress else { return }
        event?.keyboardSetUnicodeString(
          stringLength: buffer.count,
          unicodeString: address
        )
      }
      event?.post(tap: .cghidEventTap)
    }
  }

  private func modifierFlags(_ modifiers: [String]) -> CGEventFlags {
    var flags: CGEventFlags = []
    for modifier in modifiers {
      switch modifier {
      case "command": flags.insert(.maskCommand)
      case "control": flags.insert(.maskControl)
      case "option": flags.insert(.maskAlternate)
      case "shift": flags.insert(.maskShift)
      default: break
      }
    }
    return flags
  }

  private func macKeyCode(for key: String) -> CGKeyCode? {
    let codes: [String: CGKeyCode] = [
      "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5,
      "KeyZ": 6, "KeyX": 7, "KeyC": 8, "KeyV": 9, "KeyB": 11, "KeyQ": 12,
      "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16, "KeyT": 17,
      "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit6": 22,
      "Digit5": 23, "Equal": 24, "Digit9": 25, "Digit7": 26, "Minus": 27,
      "Digit8": 28, "Digit0": 29, "BracketRight": 30, "KeyO": 31, "KeyU": 32,
      "BracketLeft": 33, "KeyI": 34, "KeyP": 35, "Enter": 36, "KeyL": 37,
      "KeyJ": 38, "Quote": 39, "KeyK": 40, "Semicolon": 41, "Backslash": 42,
      "Comma": 43, "Slash": 44, "KeyN": 45, "KeyM": 46, "Period": 47,
      "Tab": 48, "Space": 49, "Backquote": 50, "Backspace": 51, "Escape": 53,
      "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100, "F9": 101,
      "F11": 103, "F10": 109, "F12": 111, "Home": 115, "PageUp": 116,
      "Delete": 117, "F4": 118, "End": 119, "F2": 120, "PageDown": 121,
      "F1": 122, "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125,
      "ArrowUp": 126
    ]
    return codes[key]
  }

  private func activeDisplayIds() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
      return []
    }
    var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
      return []
    }
    return Array(displays.prefix(Int(count)))
  }

  private func listDisplays() -> [[String: Any]] {
    var names: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
      if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber {
        names[number.uint32Value] = screen.localizedName
      }
    }
    return activeDisplayIds().map { displayId in
      let bounds = CGDisplayBounds(displayId)
      return [
        "id": String(displayId),
        "name": names[displayId] ?? "Display \(displayId)",
        "width": Int(bounds.width),
        "height": Int(bounds.height),
        "isPrimary": displayId == CGMainDisplayID()
      ]
    }
  }
}

private final class AppleLanDiscoveryBridge: NSObject, FlutterStreamHandler {
  private static let serviceType = "_cdrremote._tcp"
  private static let methodChannelName =
    "com.crossdesktopremote.cross_desktop_remote/lan_discovery"
  private static let eventChannelName =
    "com.crossdesktopremote.cross_desktop_remote/lan_discovery_events"

  private let queue = DispatchQueue(label: "com.crossdesktopremote.lan-discovery")
  private var registration: DNSServiceRef?
  private var browser: DNSServiceRef?
  private var resolutions: [String: DNSServiceRef] = [:]
  private var resolvedIds: [String: String] = [:]
  private var discovered: [String: [String: Any]] = [:]
  private var eventSink: FlutterEventSink?
  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?

  init(binaryMessenger: FlutterBinaryMessenger) {
    super.init()
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
    switch call.method {
    case "publishHost":
      guard
        let values = call.arguments as? [String: Any],
        let deviceId = values["deviceId"] as? String,
        let name = values["name"] as? String,
        let port = values["port"] as? Int,
        port > 0,
        port <= Int(UInt16.max)
      else {
        result(FlutterError(
          code: "invalid_advertisement",
          message: "Invalid LAN host advertisement",
          details: nil
        ))
        return
      }
      let metadata = [
        "id": deviceId,
        "v": values["version"] as? String ?? "1",
        "path": values["path"] as? String ?? "/ws/signaling",
        "cap": values["capabilities"] as? String ?? "screen,pointer,keyboard,quality,displays"
      ]
      result(runDNSOperation {
        try self.publish(name: name, port: port, metadata: metadata)
      })
    case "stopPublishing":
      queue.sync { stopRegistration() }
      result(nil)
    case "startBrowsing":
      result(runDNSOperation { try self.startBrowser() })
    case "stopBrowsing":
      queue.sync { stopBrowser() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func runDNSOperation(_ operation: () throws -> Void) -> FlutterError? {
    do {
      try queue.sync(execute: operation)
      return nil
    } catch let error as LanDiscoveryError {
      return FlutterError(
        code: "bonjour_error",
        message: error.description,
        details: error.code
      )
    } catch {
      return FlutterError(
        code: "bonjour_error",
        message: error.localizedDescription,
        details: nil
      )
    }
  }

  private func publish(name: String, port: Int, metadata: [String: String]) throws {
    stopRegistration()
    var serviceRef: DNSServiceRef?
    let txt = encodeTXT(metadata)
    let error = txt.withUnsafeBytes { bytes in
      DNSServiceRegister(
        &serviceRef,
        0,
        0,
        name,
        Self.serviceType,
        nil,
        nil,
        UInt16(port).bigEndian,
        UInt16(txt.count),
        bytes.baseAddress,
        registrationCallback,
        Unmanaged.passUnretained(self).toOpaque()
      )
    }
    try schedule(serviceRef: serviceRef, initialError: error)
    registration = serviceRef
  }

  private func startBrowser() throws {
    stopBrowser()
    var serviceRef: DNSServiceRef?
    let error = DNSServiceBrowse(
      &serviceRef,
      0,
      0,
      Self.serviceType,
      nil,
      browseCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
    try schedule(serviceRef: serviceRef, initialError: error)
    browser = serviceRef
  }

  private func schedule(
    serviceRef: DNSServiceRef?,
    initialError: DNSServiceErrorType
  ) throws {
    guard initialError == kDNSServiceErr_NoError, let serviceRef else {
      throw LanDiscoveryError(code: initialError)
    }
    let queueError = DNSServiceSetDispatchQueue(serviceRef, queue)
    guard queueError == kDNSServiceErr_NoError else {
      DNSServiceRefDeallocate(serviceRef)
      throw LanDiscoveryError(code: queueError)
    }
  }

  fileprivate func handleRegistration(error: DNSServiceErrorType) {
    if error != kDNSServiceErr_NoError {
      emitError(code: error)
    }
  }

  fileprivate func handleBrowse(
    flags: DNSServiceFlags,
    interfaceIndex: UInt32,
    error: DNSServiceErrorType,
    serviceName: String,
    registrationType: String,
    domain: String
  ) {
    guard error == kDNSServiceErr_NoError else {
      emitError(code: error)
      return
    }
    let key = "\(interfaceIndex)|\(serviceName)|\(registrationType)|\(domain)"
    if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
      startResolution(
        key: key,
        interfaceIndex: interfaceIndex,
        serviceName: serviceName,
        registrationType: registrationType,
        domain: domain
      )
    } else {
      removeResolution(key: key)
      if let id = resolvedIds.removeValue(forKey: key),
         !resolvedIds.values.contains(id) {
        discovered.removeValue(forKey: id)
      }
      emitDevices()
    }
  }

  private func startResolution(
    key: String,
    interfaceIndex: UInt32,
    serviceName: String,
    registrationType: String,
    domain: String
  ) {
    removeResolution(key: key)
    var serviceRef: DNSServiceRef?
    let error = DNSServiceResolve(
      &serviceRef,
      0,
      interfaceIndex,
      serviceName,
      registrationType,
      domain,
      resolveCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
    do {
      try schedule(serviceRef: serviceRef, initialError: error)
      resolutions[key] = serviceRef
    } catch let error as LanDiscoveryError {
      emitError(code: error.code)
    } catch {
      emitError(code: DNSServiceErrorType(kDNSServiceErr_Unknown))
    }
  }

  fileprivate func handleResolve(
    serviceRef: DNSServiceRef,
    error: DNSServiceErrorType,
    fullName: String,
    host: String,
    port: UInt16,
    txtRecord: UnsafePointer<UInt8>?,
    txtLength: UInt16
  ) {
    guard let entry = resolutions.first(where: { $0.value == serviceRef }) else {
      return
    }
    let key = entry.key
    resolutions.removeValue(forKey: key)
    DNSServiceRefDeallocate(serviceRef)
    guard error == kDNSServiceErr_NoError else {
      emitError(code: error)
      return
    }
    let metadata = decodeTXT(pointer: txtRecord, length: Int(txtLength))
    let id = metadata["id"] ?? fullName
    resolvedIds[key] = id
    discovered[id] = [
      "id": id,
      "name": serviceInstanceName(from: fullName),
      "host": host,
      "port": Int(UInt16(bigEndian: port)),
      "path": metadata["path"] ?? "/ws/signaling",
      "version": metadata["v"] ?? "1",
      "capabilities": metadata["cap"] ?? ""
    ]
    emitDevices()
  }

  private func removeResolution(key: String) {
    if let serviceRef = resolutions.removeValue(forKey: key) {
      DNSServiceRefDeallocate(serviceRef)
    }
  }

  private func stopRegistration() {
    if let registration {
      DNSServiceRefDeallocate(registration)
      self.registration = nil
    }
  }

  private func stopBrowser() {
    for serviceRef in resolutions.values {
      DNSServiceRefDeallocate(serviceRef)
    }
    resolutions.removeAll()
    resolvedIds.removeAll()
    discovered.removeAll()
    if let browser {
      DNSServiceRefDeallocate(browser)
      self.browser = nil
    }
    emitDevices()
  }

  private func emitDevices() {
    let values = Array(discovered.values)
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(values)
    }
  }

  private func emitError(code: DNSServiceErrorType) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(FlutterError(
        code: "bonjour_error",
        message: LanDiscoveryError(code: code).description,
        details: code
      ))
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    queue.async { [weak self] in self?.emitDevices() }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

private struct LanDiscoveryError: Error {
  let code: DNSServiceErrorType

  var description: String {
    "Bonjour operation failed with DNS-SD error \(code)"
  }
}

private func encodeTXT(_ values: [String: String]) -> Data {
  var data = Data()
  for (key, value) in values.sorted(by: { $0.key < $1.key }) {
    let bytes = Array("\(key)=\(value)".utf8.prefix(255))
    data.append(UInt8(bytes.count))
    data.append(contentsOf: bytes)
  }
  return data
}

private func decodeTXT(
  pointer: UnsafePointer<UInt8>?,
  length: Int
) -> [String: String] {
  guard let pointer, length > 0 else { return [:] }
  let bytes = UnsafeBufferPointer(start: pointer, count: length)
  var result: [String: String] = [:]
  var index = 0
  while index < bytes.count {
    let itemLength = Int(bytes[index])
    index += 1
    guard itemLength > 0, index + itemLength <= bytes.count else { break }
    let item = String(decoding: bytes[index..<(index + itemLength)], as: UTF8.self)
    index += itemLength
    if let separator = item.firstIndex(of: "=") {
      result[String(item[..<separator])] = String(item[item.index(after: separator)...])
    }
  }
  return result
}

private func serviceInstanceName(from fullName: String) -> String {
  fullName.split(separator: ".", maxSplits: 1).first.map(String.init) ?? fullName
}

private let registrationCallback: DNSServiceRegisterReply = {
  _, _, errorCode, _, _, _, context in
  guard let context else { return }
  Unmanaged<AppleLanDiscoveryBridge>
    .fromOpaque(context)
    .takeUnretainedValue()
    .handleRegistration(error: errorCode)
}

private let browseCallback: DNSServiceBrowseReply = {
  _, flags, interfaceIndex, errorCode, serviceName, registrationType, domain, context in
  guard
    let context,
    let serviceName,
    let registrationType,
    let domain
  else { return }
  Unmanaged<AppleLanDiscoveryBridge>
    .fromOpaque(context)
    .takeUnretainedValue()
    .handleBrowse(
      flags: flags,
      interfaceIndex: interfaceIndex,
      error: errorCode,
      serviceName: String(cString: serviceName),
      registrationType: String(cString: registrationType),
      domain: String(cString: domain)
    )
}

private let resolveCallback: DNSServiceResolveReply = {
  serviceRef, _, _, errorCode, fullName, host, port, txtLength, txtRecord, context in
  guard
    let context,
    let serviceRef,
    let fullName,
    let host
  else { return }
  Unmanaged<AppleLanDiscoveryBridge>
    .fromOpaque(context)
    .takeUnretainedValue()
    .handleResolve(
      serviceRef: serviceRef,
      error: errorCode,
      fullName: String(cString: fullName),
      host: String(cString: host),
      port: port,
      txtRecord: txtRecord,
      txtLength: txtLength
    )
}
