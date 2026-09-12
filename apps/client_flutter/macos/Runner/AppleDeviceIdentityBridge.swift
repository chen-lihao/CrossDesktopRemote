import CryptoKit
import FlutterMacOS
import Foundation
import Security

final class AppleDeviceIdentityBridge {
  private static let channelName =
    "com.crossdesktopremote.cross_desktop_remote/device_identity"
  private static let rootTag =
    "com.crossdesktopremote.device-identity.root.v1".data(using: .utf8)!
  private static let authenticationTagPrefix =
    "com.crossdesktopremote.device-identity.authentication.v2."
  private static let authenticationMetadataKey =
    "crossdesktop.device-identity.authentication.metadata.v2"
  private static let rootFingerprintKey =
    "crossdesktop.device-identity.root-fingerprint.v2"
  private static let authenticationLifetime: TimeInterval = 30 * 24 * 60 * 60
  private static let authenticationRotationWindow: TimeInterval = 7 * 24 * 60 * 60

  private var channel: FlutterMethodChannel?

  init(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    self.channel = channel
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "loadOrCreateIdentity":
        result(try identity(forceAuthenticationRotation: false))
      case "rotateAuthenticationKey":
        result(try identity(forceAuthenticationRotation: true))
      case "signWithRoot":
        result(try sign(arguments: call.arguments, tag: Self.rootTag))
      case "signWithAuthenticationKey":
        result(try sign(arguments: call.arguments, tag: try currentAuthenticationTag()))
      case "verifyP256Signature":
        result(try verify(arguments: call.arguments))
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(
        FlutterError(
          code: "device_identity_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func identity(forceAuthenticationRotation: Bool) throws -> [String: Any] {
    let root = try loadRootKey()
    let rootPublic = try publicKeyData(root)
    let fingerprint = Data(SHA256.hash(data: rootPublic))
    let encodedFingerprint = fingerprint.base64EncodedString()
    if let bound = UserDefaults.standard.string(forKey: Self.rootFingerprintKey) {
      guard bound == encodedFingerprint else {
        throw DeviceIdentityError.rootIdentityChanged
      }
    } else {
      UserDefaults.standard.set(encodedFingerprint, forKey: Self.rootFingerprintKey)
    }
    let now = Date()
    var metadata = authenticationMetadata()
    var authentication: SecKey?
    if let metadata {
      authentication = try loadKey(tag: authenticationTag(keyId: metadata.keyId))
    }
    let shouldRotate =
      forceAuthenticationRotation ||
      authentication == nil ||
      metadata == nil ||
      metadata!.expiresAt <= now.timeIntervalSince1970 + Self.authenticationRotationWindow
    if shouldRotate {
      let keyId = UUID().uuidString.lowercased()
      let tag = authenticationTag(keyId: keyId)
      let created = try loadOrCreateKey(tag: tag, preferHardware: true)
      let notBefore = now.timeIntervalSince1970
      let expiresAt = notBefore + Self.authenticationLifetime
      let next = AuthenticationMetadata(
        keyId: keyId,
        notBefore: notBefore,
        expiresAt: expiresAt
      )
      UserDefaults.standard.set(next.dictionary, forKey: Self.authenticationMetadataKey)
      metadata = next
      authentication = created
    }
    guard let metadata, let authentication else {
      throw DeviceIdentityError.keyMissing
    }
    let authenticationPublic = try publicKeyData(authentication)
    let certificateBody = authenticationCertificateBody(
      rootFingerprint: fingerprint,
      authenticationPublicKey: authenticationPublic,
      notBeforeUnixMs: UInt64(metadata.notBefore * 1000),
      expiresAtUnixMs: UInt64(metadata.expiresAt * 1000)
    )
    let certificate = try createSignature(key: root, message: certificateBody)

    return [
      "rootKeyHandle": "apple-keychain:root:v1",
      "rootPublicKey": rootPublic.base64EncodedString(),
      "authenticationKeyHandle": "apple-keychain:authentication:\(metadata.keyId)",
      "authenticationPublicKey": authenticationPublic.base64EncodedString(),
      "authenticationNotBeforeUnixMs": UInt64(metadata.notBefore * 1000),
      "authenticationExpiresAtUnixMs": UInt64(metadata.expiresAt * 1000),
      "authenticationCertificate": certificate.base64EncodedString(),
      "hardwareBacked": isHardwareBacked(root) && isHardwareBacked(authentication)
    ]
  }

  private func sign(arguments: Any?, tag: Data) throws -> String {
    guard
      let values = arguments as? [String: Any],
      let encoded = values["message"] as? String,
      let message = Data(base64Encoded: encoded)
    else {
      throw DeviceIdentityError.invalidArguments
    }
    return try createSignature(key: requiredKey(tag: tag), message: message)
      .base64EncodedString()
  }

  private func verify(arguments: Any?) throws -> Bool {
    guard
      let values = arguments as? [String: Any],
      let publicKeyValue = values["publicKey"] as? String,
      let messageValue = values["message"] as? String,
      let signatureValue = values["signature"] as? String,
      let publicKeyData = Data(base64Encoded: publicKeyValue),
      let message = Data(base64Encoded: messageValue),
      let signature = Data(base64Encoded: signatureValue)
    else {
      throw DeviceIdentityError.invalidArguments
    }
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeyClass: kSecAttrKeyClassPublic,
      kSecAttrKeySizeInBits: 256
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(
      publicKeyData as CFData,
      attributes as CFDictionary,
      &error
    ) else {
      throw error?.takeRetainedValue() ?? DeviceIdentityError.invalidPublicKey
    }
    return SecKeyVerifySignature(
      key,
      .ecdsaSignatureMessageX962SHA256,
      message as CFData,
      signature as CFData,
      &error
    )
  }

  private func loadOrCreateKey(tag: Data, preferHardware: Bool) throws -> SecKey {
    if let existing = try loadKey(tag: tag) {
      return existing
    }
    if preferHardware, let key = try? createKey(tag: tag, secureEnclave: true) {
      return key
    }
    return try createKey(tag: tag, secureEnclave: false)
  }

  private func loadRootKey() throws -> SecKey {
    if let existing = try loadKey(tag: Self.rootTag) {
      return existing
    }
    // A persisted binding without its private key means the protected identity
    // was lost. Never create a replacement under the same installation and
    // silently inherit existing trust grants.
    if UserDefaults.standard.string(forKey: Self.rootFingerprintKey) != nil {
      throw DeviceIdentityError.keyMissing
    }
    return try loadOrCreateKey(tag: Self.rootTag, preferHardware: true)
  }

  private func requiredKey(tag: Data) throws -> SecKey {
    guard let key = try loadKey(tag: tag) else {
      throw DeviceIdentityError.keyMissing
    }
    return key
  }

  private func loadKey(tag: Data) throws -> SecKey? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: tag,
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef: true
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw DeviceIdentityError.keyLookupFailed(status) }
    return item as! SecKey?
  }

  private func authenticationTag(keyId: String) -> Data {
    Data("\(Self.authenticationTagPrefix)\(keyId)".utf8)
  }

  private func currentAuthenticationTag() throws -> Data {
    guard let metadata = authenticationMetadata() else {
      throw DeviceIdentityError.keyMissing
    }
    return authenticationTag(keyId: metadata.keyId)
  }

  private func authenticationMetadata() -> AuthenticationMetadata? {
    guard
      let value = UserDefaults.standard.dictionary(forKey: Self.authenticationMetadataKey),
      let keyId = value["keyId"] as? String,
      let notBefore = value["notBefore"] as? Double,
      let expiresAt = value["expiresAt"] as? Double,
      !keyId.isEmpty,
      expiresAt > notBefore
    else { return nil }
    return AuthenticationMetadata(
      keyId: keyId,
      notBefore: notBefore,
      expiresAt: expiresAt
    )
  }

  private func createKey(tag: Data, secureEnclave: Bool) throws -> SecKey {
    var privateAttributes: [CFString: Any] = [
      kSecAttrIsPermanent: true,
      kSecAttrApplicationTag: tag,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    if secureEnclave {
      var accessError: Unmanaged<CFError>?
      guard let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        .privateKeyUsage,
        &accessError
      ) else {
        throw accessError?.takeRetainedValue() ?? DeviceIdentityError.keyCreationFailed
      }
      privateAttributes[kSecAttrAccessControl] = access
      privateAttributes.removeValue(forKey: kSecAttrAccessible)
    }
    var attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits: 256,
      kSecPrivateKeyAttrs: privateAttributes
    ]
    if secureEnclave {
      attributes[kSecAttrTokenID] = kSecAttrTokenIDSecureEnclave
    }
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error)
    else {
      throw error?.takeRetainedValue() ?? DeviceIdentityError.keyCreationFailed
    }
    return key
  }

  private func publicKeyData(_ privateKey: SecKey) throws -> Data {
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
      throw DeviceIdentityError.publicKeyUnavailable
    }
    var error: Unmanaged<CFError>?
    guard let value = SecKeyCopyExternalRepresentation(publicKey, &error)
    else {
      throw error?.takeRetainedValue() ?? DeviceIdentityError.publicKeyUnavailable
    }
    return value as Data
  }

  private func createSignature(key: SecKey, message: Data) throws -> Data {
    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(
      key,
      .ecdsaSignatureMessageX962SHA256,
      message as CFData,
      &error
    ) else {
      throw error?.takeRetainedValue() ?? DeviceIdentityError.signatureFailed
    }
    return signature as Data
  }

  private func isHardwareBacked(_ key: SecKey) -> Bool {
    guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any] else {
      return false
    }
    return attributes[kSecAttrTokenID] as? String ==
      (kSecAttrTokenIDSecureEnclave as String)
  }

  private func authenticationCertificateBody(
    rootFingerprint: Data,
    authenticationPublicKey: Data,
    notBeforeUnixMs: UInt64,
    expiresAtUnixMs: UInt64
  ) -> Data {
    var output = Data()
    appendLengthPrefixed(
      Data("CrossDesktopRemote/AuthKeyCertificate/v1".utf8),
      to: &output
    )
    appendLengthPrefixed(rootFingerprint, to: &output)
    appendLengthPrefixed(authenticationPublicKey, to: &output)
    appendUInt64(notBeforeUnixMs, to: &output)
    appendUInt64(expiresAtUnixMs, to: &output)
    return output
  }

  private func appendLengthPrefixed(_ value: Data, to output: inout Data) {
    var length = UInt32(value.count).bigEndian
    withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
    output.append(value)
  }

  private func appendUInt64(_ value: UInt64, to output: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
  }
}

private struct AuthenticationMetadata {
  let keyId: String
  let notBefore: Double
  let expiresAt: Double

  var dictionary: [String: Any] {
    ["keyId": keyId, "notBefore": notBefore, "expiresAt": expiresAt]
  }
}

private enum DeviceIdentityError: LocalizedError {
  case invalidArguments
  case invalidPublicKey
  case keyLookupFailed(OSStatus)
  case keyMissing
  case rootIdentityChanged
  case keyCreationFailed
  case publicKeyUnavailable
  case signatureFailed

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "Invalid device identity arguments"
    case .invalidPublicKey:
      return "Invalid P-256 public key"
    case .keyLookupFailed(let status):
      return "Unable to access protected device key (OSStatus \(status))"
    case .keyMissing:
      return "Protected device key is missing"
    case .rootIdentityChanged:
      return "Protected root identity no longer matches this installation"
    case .keyCreationFailed:
      return "Unable to create protected device key"
    case .publicKeyUnavailable:
      return "Unable to export device public key"
    case .signatureFailed:
      return "Unable to sign device authentication message"
    }
  }
}
