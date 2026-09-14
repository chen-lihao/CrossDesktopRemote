import CryptoKit
import Flutter
import Foundation
import Security

final class AppleDeviceIdentityBridge {
  private static let channelName =
    "com.crossdesktopremote.cross_desktop_remote/device_identity"
  private static let rootTag =
    Data("com.crossdesktopremote.device-identity.root.v3".utf8)
  private static let authenticationTagPrefix =
    "com.crossdesktopremote.device-identity.authentication.v3."
  private static let authenticationMetadataKey =
    "crossdesktop.device-identity.authentication.metadata.v3"
  private static let rootFingerprintKey =
    "crossdesktop.device-identity.root-fingerprint.v3"
  private static let legacyRootTag =
    Data("com.crossdesktopremote.device-identity.root.v1".utf8)
  private static let legacyAuthenticationTagPrefix =
    "com.crossdesktopremote.device-identity.authentication.v2."
  private static let legacyAuthenticationMetadataKey =
    "crossdesktop.device-identity.authentication.metadata.v2"
  private static let legacyRootFingerprintKey =
    "crossdesktop.device-identity.root-fingerprint.v2"
  private static let authenticationLifetime: TimeInterval = 30 * 24 * 60 * 60
  private static let authenticationRotationWindow: TimeInterval = 7 * 24 * 60 * 60

  private let secrets = AppleApplicationSecretStore()
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
      case "upgradeToHardwareIdentity":
        result(try replaceLegacyIdentity())
      case "resetIdentity":
        result(try resetIdentity())
      case "signWithRoot":
        result(try sign(arguments: call.arguments, tag: Self.rootTag))
      case "signWithAuthenticationKey":
        result(try sign(arguments: call.arguments, tag: try currentAuthenticationTag()))
      case "verifyP256Signature":
        result(try verify(arguments: call.arguments))
      case "loadOrCreateSecret":
        result(try secrets.loadOrCreate(arguments: call.arguments))
      case "deleteSecret":
        try secrets.delete(arguments: call.arguments)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      let protectedError = DeviceIdentityError.from(error)
      result(
        FlutterError(
          code: "protected_storage_failed",
          message: protectedError.localizedDescription,
          details: protectedError.details
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
      if let authentication, !isHardwareBacked(authentication) {
        throw DeviceIdentityError.migrationRequired
      }
    }
    let shouldRotate =
      forceAuthenticationRotation ||
      authentication == nil ||
      metadata == nil ||
      metadata!.expiresAt <= now.timeIntervalSince1970 + Self.authenticationRotationWindow
    if shouldRotate {
      let keyId = UUID().uuidString.lowercased()
      let tag = authenticationTag(keyId: keyId)
      let previous = metadata?.keyId
      let created = try createHardwareKey(tag: tag)
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
      if let previous, previous != keyId {
        try deleteKeyIfPresent(tag: authenticationTag(keyId: previous))
      }
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

    guard isHardwareBacked(root) && isHardwareBacked(authentication) else {
      throw DeviceIdentityError.migrationRequired
    }
    return [
      "rootKeyHandle": "apple-secure-enclave:root:v3",
      "rootPublicKey": rootPublic.base64EncodedString(),
      "authenticationKeyHandle":
        "apple-secure-enclave:authentication:v3:\(metadata.keyId)",
      "authenticationPublicKey": authenticationPublic.base64EncodedString(),
      "authenticationNotBeforeUnixMs": UInt64(metadata.notBefore * 1000),
      "authenticationExpiresAtUnixMs": UInt64(metadata.expiresAt * 1000),
      "authenticationCertificate": certificate.base64EncodedString(),
      "hardwareBacked": true,
      "protection": "secureHardware",
      "securityState": "readyHardwareProtected"
    ]
  }

  private func replaceLegacyIdentity() throws -> [String: Any] {
    try deleteLegacyIdentityIfPresent()
    return try resetIdentity()
  }

  private func resetIdentity() throws -> [String: Any] {
    if let metadata = authenticationMetadata() {
      try deleteKeyIfPresent(tag: authenticationTag(keyId: metadata.keyId))
    }
    try deleteKeyIfPresent(tag: Self.rootTag)
    UserDefaults.standard.removeObject(forKey: Self.authenticationMetadataKey)
    UserDefaults.standard.removeObject(forKey: Self.rootFingerprintKey)
    return try identity(forceAuthenticationRotation: false)
  }

  private func sign(arguments: Any?, tag: Data) throws -> String {
    guard
      let values = arguments as? [String: Any],
      let encoded = values["message"] as? String,
      let message = Data(base64Encoded: encoded),
      message.count <= 32 * 1024
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

  private func loadRootKey() throws -> SecKey {
    if let existing = try loadKey(tag: Self.rootTag) {
      guard isHardwareBacked(existing) else {
        throw DeviceIdentityError.migrationRequired
      }
      return existing
    }
    // A persisted binding without its private key means the protected identity
    // was lost. Never create a replacement under the same installation and
    // silently inherit existing trust grants.
    if UserDefaults.standard.string(forKey: Self.rootFingerprintKey) != nil {
      throw DeviceIdentityError.keyMissing
    }
    if legacyIdentityExists() {
      throw DeviceIdentityError.migrationRequired
    }
    return try createHardwareKey(tag: Self.rootTag)
  }

  private func requiredKey(tag: Data) throws -> SecKey {
    guard let key = try loadKey(tag: tag) else {
      throw DeviceIdentityError.keyMissing
    }
    guard isHardwareBacked(key) else {
      throw DeviceIdentityError.migrationRequired
    }
    return key
  }

  private func loadKey(tag: Data) throws -> SecKey? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: tag,
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef: true,
      kSecUseDataProtectionKeychain: true,
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

  private func createHardwareKey(tag: Data) throws -> SecKey {
    var accessError: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      .privateKeyUsage,
      &accessError
    ) else {
      throw DeviceIdentityError.from(
        accessError?.takeRetainedValue() ?? DeviceIdentityError.keyCreationFailed
      )
    }
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits: 256,
      kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
      kSecUseDataProtectionKeychain: true,
      kSecPrivateKeyAttrs: [
        kSecAttrIsPermanent: true,
        kSecAttrApplicationTag: tag,
        kSecAttrAccessControl: access,
      ],
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error)
    else {
      throw DeviceIdentityError.from(
        error?.takeRetainedValue() ?? DeviceIdentityError.keyCreationFailed
      )
    }
    guard isHardwareBacked(key) else {
      try deleteKeyIfPresent(tag: tag)
      throw DeviceIdentityError.secureEnclaveUnavailable
    }
    let challenge = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    let signature = try createSignature(key: key, message: challenge)
    guard try verifySignature(key: key, message: challenge, signature: signature)
    else {
      try deleteKeyIfPresent(tag: tag)
      throw DeviceIdentityError.keySelfTestFailed
    }
    return key
  }

  private func deleteKeyIfPresent(tag: Data) throws {
    let status = SecItemDelete([
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: tag,
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecUseDataProtectionKeychain: true,
    ] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw DeviceIdentityError.security(status)
    }
  }

  private func legacyIdentityExists() -> Bool {
    if UserDefaults.standard.object(forKey: Self.legacyRootFingerprintKey) != nil {
      return true
    }
    do { return try loadKey(tag: Self.legacyRootTag) != nil } catch { return true }
  }

  private func deleteLegacyIdentityIfPresent() throws {
    if
      let value = UserDefaults.standard.dictionary(
        forKey: Self.legacyAuthenticationMetadataKey
      ),
      let keyId = value["keyId"] as? String
    {
      try deleteKeyIfPresent(
        tag: Data("\(Self.legacyAuthenticationTagPrefix)\(keyId)".utf8)
      )
    }
    try deleteKeyIfPresent(tag: Self.legacyRootTag)
    UserDefaults.standard.removeObject(
      forKey: Self.legacyAuthenticationMetadataKey
    )
    UserDefaults.standard.removeObject(forKey: Self.legacyRootFingerprintKey)
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

  private func verifySignature(
    key: SecKey,
    message: Data,
    signature: Data
  ) throws -> Bool {
    guard let publicKey = SecKeyCopyPublicKey(key) else {
      throw DeviceIdentityError.publicKeyUnavailable
    }
    var error: Unmanaged<CFError>?
    let valid = SecKeyVerifySignature(
      publicKey,
      .ecdsaSignatureMessageX962SHA256,
      message as CFData,
      signature as CFData,
      &error
    )
    if !valid, let error = error?.takeRetainedValue() {
      throw DeviceIdentityError.from(error)
    }
    return valid
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

private final class AppleApplicationSecretStore {
  private static let service = "com.crossdesktopremote.local-secrets.v1"

  func loadOrCreate(arguments: Any?) throws -> String {
    let request = try parseRequest(arguments)
    if let existing = try read(name: request.name) {
      guard existing.count == request.length else {
        throw DeviceIdentityError.invalidArguments
      }
      return existing.base64EncodedString()
    }
    var value = Data(count: request.length)
    let randomStatus = value.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, request.length, bytes.baseAddress!)
    }
    guard randomStatus == errSecSuccess else {
      throw DeviceIdentityError.keyLookupFailed(randomStatus)
    }
    let status = SecItemAdd([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: request.name,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: true,
      kSecValueData: value,
    ] as CFDictionary, nil)
    if status == errSecDuplicateItem,
      let raced = try read(name: request.name), raced.count == request.length
    {
      return raced.base64EncodedString()
    }
    guard status == errSecSuccess else {
      throw DeviceIdentityError.keyLookupFailed(status)
    }
    return value.base64EncodedString()
  }

  func delete(arguments: Any?) throws {
    let name = try parseName(arguments)
    let status = SecItemDelete(baseQuery(name: name) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw DeviceIdentityError.keyLookupFailed(status)
    }
  }

  private func read(name: String) throws -> Data? {
    var query = baseQuery(name: name)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let value = item as? Data else {
      throw DeviceIdentityError.keyLookupFailed(status)
    }
    return value
  }

  private func baseQuery(name: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: name,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: true,
    ]
  }

  private func parseRequest(_ arguments: Any?) throws -> (name: String, length: Int) {
    guard
      let values = arguments as? [String: Any],
      let length = values["length"] as? Int,
      length >= 16,
      length <= 64
    else { throw DeviceIdentityError.invalidArguments }
    return (try parseName(arguments), length)
  }

  private func parseName(_ arguments: Any?) throws -> String {
    guard
      let values = arguments as? [String: Any],
      let name = values["name"] as? String,
      name.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression)
        != nil
    else { throw DeviceIdentityError.invalidArguments }
    return name
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
  case migrationRequired
  case keyMissing
  case rootIdentityChanged
  case keyCreationFailed
  case secureEnclaveUnavailable
  case keySelfTestFailed
  case publicKeyUnavailable
  case signatureFailed
  case nativeFailure(String)

  static func security(_ status: OSStatus) -> DeviceIdentityError {
    .keyLookupFailed(status)
  }

  static func from(_ error: Error) -> DeviceIdentityError {
    if let identityError = error as? DeviceIdentityError {
      return identityError
    }
    let nsError = error as NSError
    if nsError.domain == NSOSStatusErrorDomain {
      return .keyLookupFailed(OSStatus(nsError.code))
    }
    return .nativeFailure(error.localizedDescription)
  }

  var diagnosticCode: String {
    switch self {
    case .invalidArguments: return "invalid_arguments"
    case .invalidPublicKey: return "invalid_public_key"
    case .keyLookupFailed(let status):
      if status == errSecMissingEntitlement {
        return "missing_application_identifier"
      }
      if status == errSecInteractionNotAllowed { return "keychain_locked" }
      return "identity_storage_failure"
    case .migrationRequired: return "legacy_keychain_identity_detected"
    case .keyMissing: return "key_missing"
    case .rootIdentityChanged: return "root_identity_changed"
    case .keyCreationFailed: return "secure_enclave_creation_failed"
    case .secureEnclaveUnavailable: return "secure_enclave_unavailable"
    case .keySelfTestFailed: return "secure_enclave_self_test_failed"
    case .publicKeyUnavailable: return "public_key_unavailable"
    case .signatureFailed: return "signature_failed"
    case .nativeFailure: return "native_identity_failure"
    }
  }

  var details: [String: Any] {
    var value: [String: Any] = ["diagnosticCode": diagnosticCode]
    if case .keyLookupFailed(let status) = self { value["osStatus"] = status }
    return value
  }

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "Invalid device identity arguments"
    case .invalidPublicKey:
      return "Invalid P-256 public key"
    case .keyLookupFailed(let status):
      return "Unable to access protected device key (OSStatus \(status))"
    case .migrationRequired:
      return "The previous device identity requires explicit replacement"
    case .keyMissing:
      return "Protected device key is missing"
    case .rootIdentityChanged:
      return "Protected root identity no longer matches this installation"
    case .keyCreationFailed:
      return "Unable to create a Secure Enclave key"
    case .secureEnclaveUnavailable:
      return "Secure Enclave is unavailable"
    case .keySelfTestFailed:
      return "Secure Enclave signing self-test failed"
    case .publicKeyUnavailable:
      return "Unable to export device public key"
    case .signatureFailed:
      return "Unable to sign device authentication message"
    case .nativeFailure(let message):
      return message
    }
  }
}
