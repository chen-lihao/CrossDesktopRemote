import Flutter
import UIKit
import dnssd

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var lanDiscoveryBridge: AppleLanDiscoveryBridge?
  private var remoteImeBridge: AppleRemoteImeBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "CrossDesktopRemoteLanDiscovery"
    ) {
      lanDiscoveryBridge = AppleLanDiscoveryBridge(
        binaryMessenger: registrar.messenger()
      )
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "CrossDesktopRemoteIme"
    ) {
      remoteImeBridge = AppleRemoteImeBridge(
        binaryMessenger: registrar.messenger()
      )
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
    case "startBrowsing":
      result(runDNSOperation { try self.startBrowser() })
    case "stopBrowsing":
      queue.sync { stopBrowser() }
      result(nil)
    case "stopPublishing":
      result(nil)
    case "publishHost":
      result(FlutterError(
        code: "unsupported_role",
        message: "iOS/iPadOS only supports LAN discovery browsing",
        details: nil
      ))
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
