import Flutter
import UIKit
import UniformTypeIdentifiers

final class AppleFileTransferBridge: NSObject, UIDocumentPickerDelegate {
  private static let channelName =
    "com.crossdesktopremote.cross_desktop_remote/ios_file_transfer"

  private enum PickerOperation {
    case importFiles
    case exportFiles
  }

  private let fileManager = FileManager.default
  private var methodChannel: FlutterMethodChannel?
  private var pickerResult: FlutterResult?
  private var pickerOperation: PickerOperation?

  init(binaryMessenger: FlutterBinaryMessenger) {
    super.init()
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    methodChannel = channel
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(FlutterError(code: "bridge_unavailable", message: nil, details: nil))
        return
      }
      do {
        switch call.method {
        case "pickOutgoingFiles":
          try self.presentImportPicker(result: result)
        case "cleanupOutgoingFiles":
          try self.cleanupOutgoingFiles(arguments: call.arguments)
          result(nil)
        case "createReceiveDirectory":
          result(try self.createReceiveDirectory(arguments: call.arguments).path)
        case "exportReceivedFiles":
          try self.presentExportPicker(arguments: call.arguments, result: result)
        case "shareReceivedFiles":
          try self.presentShareSheet(arguments: call.arguments, result: result)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        if self.pickerResult != nil {
          self.finishPicker(with: error)
        } else {
          result(self.flutterError(error))
        }
      }
    }
  }

  private func presentImportPicker(result: @escaping FlutterResult) throws {
    try beginPicker(operation: .importFiles, result: result)
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [.data],
        asCopy: false
      )
    } else {
      picker = UIDocumentPickerViewController(
        documentTypes: ["public.data"],
        in: .open
      )
    }
    picker.delegate = self
    picker.allowsMultipleSelection = true
    try present(picker)
  }

  private func presentExportPicker(
    arguments: Any?,
    result: @escaping FlutterResult
  ) throws {
    let urls = try receivedURLs(arguments: arguments)
    try beginPicker(operation: .exportFiles, result: result)
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    } else {
      picker = UIDocumentPickerViewController(urls: urls, in: .exportToService)
    }
    picker.delegate = self
    try present(picker)
  }

  private func presentShareSheet(
    arguments: Any?,
    result: @escaping FlutterResult
  ) throws {
    guard pickerResult == nil else { throw BridgeError.busy }
    let urls = try receivedURLs(arguments: arguments)
    let controller = UIActivityViewController(
      activityItems: urls,
      applicationActivities: nil
    )
    if let popover = controller.popoverPresentationController,
       let view = topViewController()?.view {
      popover.sourceView = view
      popover.sourceRect = CGRect(
        x: view.bounds.midX,
        y: view.bounds.midY,
        width: 1,
        height: 1
      )
      popover.permittedArrowDirections = []
    }
    controller.completionWithItemsHandler = { _, _, _, _ in result(nil) }
    try present(controller)
  }

  private func beginPicker(
    operation: PickerOperation,
    result: @escaping FlutterResult
  ) throws {
    guard pickerResult == nil else { throw BridgeError.busy }
    pickerOperation = operation
    pickerResult = result
  }

  private func present(_ controller: UIViewController) throws {
    guard let presenter = topViewController() else {
      throw BridgeError.noPresenter
    }
    presenter.present(controller, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    switch pickerOperation {
    case .importFiles:
      do {
        let staged = try stageOutgoingFiles(urls)
        finishPicker(value: staged.map(\.path))
      } catch {
        finishPicker(with: error)
      }
    case .exportFiles:
      finishPicker(value: nil)
    case nil:
      break
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    switch pickerOperation {
    case .importFiles:
      finishPicker(value: [String]())
    case .exportFiles:
      finishPicker(value: nil)
    case nil:
      break
    }
  }

  private func stageOutgoingFiles(_ urls: [URL]) throws -> [URL] {
    guard !urls.isEmpty else { return [] }
    let transferRoot = try outgoingRoot()
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(
      at: transferRoot,
      withIntermediateDirectories: true
    )
    var staged: [URL] = []
    do {
      for source in urls {
        let accessGranted = source.startAccessingSecurityScopedResource()
        defer {
          if accessGranted { source.stopAccessingSecurityScopedResource() }
        }
        var coordinationError: NSError?
        var copyError: Error?
        var destination: URL?
        NSFileCoordinator().coordinate(
          readingItemAt: source,
          options: .withoutChanges,
          error: &coordinationError
        ) { coordinatedURL in
          do {
            let values = try coordinatedURL.resourceValues(
              forKeys: [.isDirectoryKey]
            )
            guard values.isDirectory != true else {
              throw BridgeError.directoryUnsupported
            }
            let target = self.uniqueDestination(
              directory: transferRoot,
              preferredName: coordinatedURL.lastPathComponent
            )
            try self.fileManager.copyItem(at: coordinatedURL, to: target)
            destination = target
          } catch {
            copyError = error
          }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard let destination else { throw BridgeError.copyFailed }
        staged.append(destination)
      }
      return staged
    } catch {
      try? fileManager.removeItem(at: transferRoot)
      throw error
    }
  }

  private func cleanupOutgoingFiles(arguments: Any?) throws {
    let paths = try stringPaths(arguments: arguments)
    let base = try outgoingRoot().standardizedFileURL
    let roots = Set(paths.compactMap { path -> URL? in
      let item = URL(fileURLWithPath: path).standardizedFileURL
      guard isDescendant(item, of: base) else { return nil }
      let parent = item.deletingLastPathComponent().standardizedFileURL
      return isDescendant(parent, of: base) ? parent : nil
    })
    for root in roots { try? fileManager.removeItem(at: root) }
  }

  private func createReceiveDirectory(arguments: Any?) throws -> URL {
    guard let arguments = arguments as? [String: Any],
          let transferID = arguments["transferId"] as? String,
          !transferID.isEmpty,
          transferID.count <= 128,
          transferID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    else { throw BridgeError.invalidArguments }
    let root = try incomingRoot()
    let destination = root.appendingPathComponent(transferID, isDirectory: true)
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    return destination
  }

  private func receivedURLs(arguments: Any?) throws -> [URL] {
    let paths = try stringPaths(arguments: arguments)
    guard !paths.isEmpty else { throw BridgeError.invalidArguments }
    let base = try incomingRoot().standardizedFileURL
    return try paths.map { path in
      let url = URL(fileURLWithPath: path).standardizedFileURL
      guard isDescendant(url, of: base),
            fileManager.fileExists(atPath: url.path) else {
        throw BridgeError.pathOutsideManagedStorage
      }
      return url
    }
  }

  private func stringPaths(arguments: Any?) throws -> [String] {
    guard let arguments = arguments as? [String: Any],
          let paths = arguments["paths"] as? [String]
    else { throw BridgeError.invalidArguments }
    return paths
  }

  private func outgoingRoot() throws -> URL {
    guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { throw BridgeError.storageUnavailable }
    let root = caches
      .appendingPathComponent("CrossDesktopRemote", isDirectory: true)
      .appendingPathComponent("Outgoing", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func incomingRoot() throws -> URL {
    guard let support = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else { throw BridgeError.storageUnavailable }
    let root = support
      .appendingPathComponent("CrossDesktopRemote", isDirectory: true)
      .appendingPathComponent("Incoming", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func uniqueDestination(directory: URL, preferredName: String) -> URL {
    let cleanName = preferredName.isEmpty ? "file" : preferredName
    var candidate = directory.appendingPathComponent(cleanName)
    var suffix = 2
    let extensionName = candidate.pathExtension
    let stem = candidate.deletingPathExtension().lastPathComponent
    while fileManager.fileExists(atPath: candidate.path) {
      let name = extensionName.isEmpty
        ? "\(stem) (\(suffix))"
        : "\(stem) (\(suffix)).\(extensionName)"
      candidate = directory.appendingPathComponent(name)
      suffix += 1
    }
    return candidate
  }

  private func isDescendant(_ child: URL, of base: URL) -> Bool {
    let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
    return child.path.hasPrefix(prefix)
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap {
      $0 as? UIWindowScene
    }
    let root = scenes
      .flatMap(\.windows)
      .first(where: { $0.isKeyWindow })?
      .rootViewController
    return visibleController(from: root)
  }

  private func visibleController(from controller: UIViewController?) -> UIViewController? {
    if let presented = controller?.presentedViewController {
      return visibleController(from: presented)
    }
    if let navigation = controller as? UINavigationController {
      return visibleController(from: navigation.visibleViewController)
    }
    if let tabs = controller as? UITabBarController {
      return visibleController(from: tabs.selectedViewController)
    }
    return controller
  }

  private func finishPicker(value: Any?) {
    let result = pickerResult
    pickerResult = nil
    pickerOperation = nil
    result?(value)
  }

  private func finishPicker(with error: Error) {
    let result = pickerResult
    pickerResult = nil
    pickerOperation = nil
    result?(flutterError(error))
  }

  private func flutterError(_ error: Error) -> FlutterError {
    FlutterError(
      code: "ios_file_transfer_failed",
      message: error.localizedDescription,
      details: nil
    )
  }
}

private enum BridgeError: LocalizedError {
  case busy
  case noPresenter
  case invalidArguments
  case storageUnavailable
  case directoryUnsupported
  case copyFailed
  case pathOutsideManagedStorage

  var errorDescription: String? {
    switch self {
    case .busy: return "已有文件选择或导出窗口正在显示"
    case .noPresenter: return "无法显示系统文件窗口"
    case .invalidArguments: return "文件操作参数无效"
    case .storageUnavailable: return "应用暂存目录不可用"
    case .directoryUnsupported: return "iPad 当前只支持选择文件"
    case .copyFailed: return "无法将所选文件复制到安全暂存区"
    case .pathOutsideManagedStorage: return "拒绝访问应用接收目录之外的文件"
    }
  }
}
