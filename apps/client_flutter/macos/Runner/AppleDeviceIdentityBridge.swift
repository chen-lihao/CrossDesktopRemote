import CryptoKit
import FlutterMacOS
import Foundation
import Security

final class AppleDeviceIdentityBridge {
  private static let channelName =
    "com.crossdesktopremote.cross_desktop_remote/device_identity"

  private let identity = AppleProtectedIdentityProvider()
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
        result(try identity.load(forceAuthenticationRotation: false))
      case "rotateAuthenticationKey":
        result(try identity.load(forceAuthenticationRotation: true))
      case "upgradeToHardwareIdentity":
        result(try identity.replaceLegacyIdentity())
      case "resetIdentity":
        result(try identity.resetIdentity())
      case "signWithRoot":
        result(try identity.signWithRoot(arguments: call.arguments))
      case "signWithAuthenticationKey":
        result(try identity.signWithAuthenticationKey(arguments: call.arguments))
      case "verifyP256Signature":
        result(try identity.verify(arguments: call.arguments))
      case "loadOrCreateSecret":
        result(try secrets.loadOrCreate(arguments: call.arguments))
      case "deleteSecret":
        try secrets.delete(arguments: call.arguments)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      let protectedError = AppleProtectedStorageError.from(error)
      result(
        FlutterError(
          code: "protected_storage_failed",
          message: protectedError.localizedDescription,
          details: protectedError.details
        )
      )
    }
  }
}

/// Secure Enclave keys are persistent Keychain objects in the application's
/// default access group. No explicit access group is used, so the identity is
/// bound to the stable Team ID + bundle identifier selected by Xcode.
private final class AppleProtectedIdentityProvider {
  private static let rootTag =
    Data("com.crossdesktopremote.device-identity.root.v3".utf8)
  private static let authenticationTagPrefix =
    "com.crossdesktopremote.device-identity.authentication.v3."
  private static let metadataKey =
    "crossdesktop.device-identity.authentication.metadata.v3"
  private static let rootFingerprintKey =
    "crossdesktop.device-identity.root-fingerprint.v3"
  private static let legacyRootTag =
    Data("com.crossdesktopremote.device-identity.root.v1".utf8)
  private static let legacyMetadataKey =
    "crossdesktop.device-identity.authentication.metadata.v2"
  private static let legacyFingerprintKey =
    "crossdesktop.device-identity.root-fingerprint.v2"
  private static let lifetime: TimeInterval = 30 * 24 * 60 * 60
  private static let rotationWindow: TimeInterval = 7 * 24 * 60 * 60

  func load(forceAuthenticationRotation: Bool) throws -> [String: Any] {
    try requireHardwareIdentityMode()
    let root = try loadRootKey()
    guard isHardwareBacked(root) else {
      throw AppleProtectedStorageError.migrationRequired
    }
    let rootPublic = try publicKeyData(root)
    let fingerprint = Data(SHA256.hash(data: rootPublic))
    let encodedFingerprint = fingerprint.base64EncodedString()
    if let bound = UserDefaults.standard.string(forKey: Self.rootFingerprintKey) {
      guard bound == encodedFingerprint else {
        throw AppleProtectedStorageError.rootIdentityChanged
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
        throw AppleProtectedStorageError.migrationRequired
      }
    }
    let shouldRotate =
      forceAuthenticationRotation || authentication == nil || metadata == nil
      || metadata!.expiresAt <= now.timeIntervalSince1970 + Self.rotationWindow
    if shouldRotate {
      let previous = metadata?.keyId
      let keyId = UUID().uuidString.lowercased()
      let created = try createHardwareKey(tag: authenticationTag(keyId: keyId))
      let next = AuthenticationMetadata(
        keyId: keyId,
        notBefore: now.timeIntervalSince1970,
        expiresAt: now.timeIntervalSince1970 + Self.lifetime
      )
      UserDefaults.standard.set(next.dictionary, forKey: Self.metadataKey)
      metadata = next
      authentication = created
      if let previous, previous != keyId {
        try deleteKeyIfPresent(tag: authenticationTag(keyId: previous))
      }
    }
    guard let metadata, let authentication else {
      throw AppleProtectedStorageError.keyMissing
    }
    let authenticationPublic = try publicKeyData(authentication)
    let certificateBody = authenticationCertificateBody(
      rootFingerprint: fingerprint,
      authenticationPublicKey: authenticationPublic,
      notBeforeUnixMs: UInt64(metadata.notBefore * 1000),
      expiresAtUnixMs: UInt64(metadata.expiresAt * 1000)
    )
    let certificate = try signature(key: root, message: certificateBody)
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
      "securityState": "readyHardwareProtected",
    ]
  }

  func replaceLegacyIdentity() throws -> [String: Any] {
    try requireHardwareIdentityMode()
    try deleteLegacyIdentityIfPresent()
    return try resetIdentity()
  }

  func resetIdentity() throws -> [String: Any] {
    try requireHardwareIdentityMode()
    if let metadata = authenticationMetadata() {
      try deleteKeyIfPresent(tag: authenticationTag(keyId: metadata.keyId))
    }
    try deleteKeyIfPresent(tag: Self.rootTag)
    UserDefaults.standard.removeObject(forKey: Self.metadataKey)
    UserDefaults.standard.removeObject(forKey: Self.rootFingerprintKey)
    return try load(forceAuthenticationRotation: false)
  }

  func signWithRoot(arguments: Any?) throws -> String {
    try requireHardwareIdentityMode()
    return try signature(
      key: requiredKey(tag: Self.rootTag),
      message: message(arguments)
    ).base64EncodedString()
  }

  func signWithAuthenticationKey(arguments: Any?) throws -> String {
    try requireHardwareIdentityMode()
    guard let metadata = authenticationMetadata() else {
      throw AppleProtectedStorageError.keyMissing
    }
    return try signature(
      key: requiredKey(tag: authenticationTag(keyId: metadata.keyId)),
      message: message(arguments)
    ).base64EncodedString()
  }

  func verify(arguments: Any?) throws -> Bool {
    guard
      let values = arguments as? [String: Any],
      let publicKeyValue = values["publicKey"] as? String,
      let messageValue = values["message"] as? String,
      let signatureValue = values["signature"] as? String,
      let publicKeyData = Data(base64Encoded: publicKeyValue),
      let message = Data(base64Encoded: messageValue),
      let signatureData = Data(base64Encoded: signatureValue)
    else {
      throw AppleProtectedStorageError.invalidArguments
    }
    do {
      let publicKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)
      let signature = try P256.Signing.ECDSASignature(
        derRepresentation: signatureData
      )
      return publicKey.isValidSignature(signature, for: message)
    } catch {
      throw AppleProtectedStorageError.invalidSignature
    }
  }

  private func loadRootKey() throws -> SecKey {
    if let existing = try loadKey(tag: Self.rootTag) { return existing }
    if UserDefaults.standard.string(forKey: Self.rootFingerprintKey) != nil {
      throw AppleProtectedStorageError.keyMissing
    }
    if legacyIdentityExists() {
      throw AppleProtectedStorageError.migrationRequired
    }
    return try createHardwareKey(tag: Self.rootTag)
  }

  private func legacyIdentityExists() -> Bool {
    if UserDefaults.standard.object(forKey: Self.legacyFingerprintKey) != nil {
      return true
    }
    do { return try loadKey(tag: Self.legacyRootTag) != nil } catch { return true }
  }

  private func deleteLegacyIdentityIfPresent() throws {
    if
      let value = UserDefaults.standard.dictionary(forKey: Self.legacyMetadataKey),
      let keyId = value["keyId"] as? String
    {
      let tag = Data(
        "com.crossdesktopremote.device-identity.authentication.v2.\(keyId)".utf8
      )
      try deleteKeyIfPresent(tag: tag)
    }
    try deleteKeyIfPresent(tag: Self.legacyRootTag)
    UserDefaults.standard.removeObject(forKey: Self.legacyMetadataKey)
    UserDefaults.standard.removeObject(forKey: Self.legacyFingerprintKey)
  }

  private func loadKey(tag: Data) throws -> SecKey? {
    var item: CFTypeRef?
    let status = SecItemCopyMatching([
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: tag,
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef: true,
      kSecUseDataProtectionKeychain: true,
    ] as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let key = item else {
      throw AppleProtectedStorageError.security(status)
    }
    return (key as! SecKey)
  }

  private func requiredKey(tag: Data) throws -> SecKey {
    guard let key = try loadKey(tag: tag) else {
      throw AppleProtectedStorageError.keyMissing
    }
    guard isHardwareBacked(key) else {
      throw AppleProtectedStorageError.migrationRequired
    }
    return key
  }

  private func createHardwareKey(tag: Data) throws -> SecKey {
    var accessError: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      .privateKeyUsage,
      &accessError
    ) else {
      throw AppleProtectedStorageError.from(
        accessError?.takeRetainedValue()
          ?? AppleProtectedStorageError.keyCreationFailed
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
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      throw AppleProtectedStorageError.from(
        error?.takeRetainedValue() ?? AppleProtectedStorageError.keyCreationFailed
      )
    }
    guard isHardwareBacked(key) else {
      try deleteKeyIfPresent(tag: tag)
      throw AppleProtectedStorageError.secureEnclaveUnavailable
    }
    let challenge = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    let signed = try signature(key: key, message: challenge)
    guard try verifySignature(key: key, message: challenge, signature: signed) else {
      try deleteKeyIfPresent(tag: tag)
      throw AppleProtectedStorageError.keySelfTestFailed
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
      throw AppleProtectedStorageError.security(status)
    }
  }

  private func publicKeyData(_ privateKey: SecKey) throws -> Data {
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
      throw AppleProtectedStorageError.publicKeyUnavailable
    }
    var error: Unmanaged<CFError>?
    guard let value = SecKeyCopyExternalRepresentation(publicKey, &error) else {
      throw AppleProtectedStorageError.from(
        error?.takeRetainedValue()
          ?? AppleProtectedStorageError.publicKeyUnavailable
      )
    }
    return value as Data
  }

  private func signature(key: SecKey, message: Data) throws -> Data {
    var error: Unmanaged<CFError>?
    guard let value = SecKeyCreateSignature(
      key,
      .ecdsaSignatureMessageX962SHA256,
      message as CFData,
      &error
    ) else {
      throw AppleProtectedStorageError.from(
        error?.takeRetainedValue() ?? AppleProtectedStorageError.signatureFailed
      )
    }
    return value as Data
  }

  private func verifySignature(
    key: SecKey,
    message: Data,
    signature: Data
  ) throws -> Bool {
    guard let publicKey = SecKeyCopyPublicKey(key) else {
      throw AppleProtectedStorageError.publicKeyUnavailable
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
      throw AppleProtectedStorageError.from(error)
    }
    return valid
  }

  private func isHardwareBacked(_ key: SecKey) -> Bool {
    guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any] else {
      return false
    }
    return attributes[kSecAttrTokenID] as? String
      == (kSecAttrTokenIDSecureEnclave as String)
  }

  private func authenticationMetadata() -> AuthenticationMetadata? {
    guard
      let value = UserDefaults.standard.dictionary(forKey: Self.metadataKey),
      let keyId = value["keyId"] as? String,
      let notBefore = value["notBefore"] as? Double,
      let expiresAt = value["expiresAt"] as? Double,
      UUID(uuidString: keyId) != nil,
      expiresAt > notBefore
    else { return nil }
    return AuthenticationMetadata(
      keyId: keyId,
      notBefore: notBefore,
      expiresAt: expiresAt
    )
  }

  private func authenticationTag(keyId: String) -> Data {
    Data("\(Self.authenticationTagPrefix)\(keyId)".utf8)
  }

  private func message(_ arguments: Any?) throws -> Data {
    guard
      let values = arguments as? [String: Any],
      let encoded = values["message"] as? String,
      let message = Data(base64Encoded: encoded),
      message.count <= 32 * 1024
    else {
      throw AppleProtectedStorageError.invalidArguments
    }
    return message
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
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
  }
}

private final class AppleApplicationSecretStore {
  private static let service = "com.crossdesktopremote.local-secrets.v1"

  func loadOrCreate(arguments: Any?) throws -> String {
    try requireHardwareIdentityMode()
    let request = try secretRequest(arguments)
    if let existing = try read(name: request.name) {
      guard existing.count == request.length else {
        throw AppleProtectedStorageError.secretLengthMismatch
      }
      return existing.base64EncodedString()
    }
    var value = Data(count: request.length)
    let status = value.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, request.length, bytes.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw AppleProtectedStorageError.security(status)
    }
    let addStatus = SecItemAdd([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: request.name,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: true,
      kSecValueData: value,
    ] as CFDictionary, nil)
    if addStatus == errSecDuplicateItem,
      let raced = try read(name: request.name), raced.count == request.length
    {
      return raced.base64EncodedString()
    }
    guard addStatus == errSecSuccess else {
      throw AppleProtectedStorageError.security(addStatus)
    }
    return value.base64EncodedString()
  }

  func delete(arguments: Any?) throws {
    try requireHardwareIdentityMode()
    let name = try secretName(arguments)
    let status = SecItemDelete(baseQuery(name: name) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AppleProtectedStorageError.security(status)
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
      throw AppleProtectedStorageError.security(status)
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

  private func secretRequest(_ arguments: Any?) throws -> (name: String, length: Int) {
    guard
      let values = arguments as? [String: Any],
      let length = values["length"] as? Int,
      length >= 16,
      length <= 64
    else {
      throw AppleProtectedStorageError.invalidArguments
    }
    return (try secretName(arguments), length)
  }

  private func secretName(_ arguments: Any?) throws -> String {
    guard
      let values = arguments as? [String: Any],
      let name = values["name"] as? String,
      name.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression)
        != nil
    else {
      throw AppleProtectedStorageError.invalidArguments
    }
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

private func requireHardwareIdentityMode() throws {
  let mode = Bundle.main.object(forInfoDictionaryKey: "CDRTrustedIdentityMode")
    as? String
  guard mode == "hardware" else {
    throw AppleProtectedStorageError.identityDisabled
  }
}

private enum AppleProtectedStorageError: LocalizedError {
  case invalidArguments
  case identityDisabled
  case missingEntitlement
  case keychainLocked
  case migrationRequired
  case rootIdentityChanged
  case secureEnclaveUnavailable
  case keyMissing
  case keyCreationFailed
  case keySelfTestFailed
  case publicKeyUnavailable
  case signatureFailed
  case invalidSignature
  case secretLengthMismatch
  case keychainFailure(OSStatus)
  case nativeFailure(String)

  static func security(_ status: OSStatus) -> AppleProtectedStorageError {
    switch status {
    case errSecMissingEntitlement: return .missingEntitlement
    case errSecInteractionNotAllowed: return .keychainLocked
    default: return .keychainFailure(status)
    }
  }

  static func from(_ error: Error) -> AppleProtectedStorageError {
    if let protected = error as? AppleProtectedStorageError { return protected }
    let nsError = error as NSError
    if nsError.domain == NSOSStatusErrorDomain {
      return security(OSStatus(nsError.code))
    }
    return .nativeFailure(error.localizedDescription)
  }

  var diagnosticCode: String {
    switch self {
    case .invalidArguments: return "invalid_arguments"
    case .identityDisabled: return "trusted_identity_disabled"
    case .missingEntitlement: return "missing_application_identifier"
    case .keychainLocked: return "keychain_locked"
    case .migrationRequired: return "legacy_keychain_identity_detected"
    case .rootIdentityChanged: return "root_identity_changed"
    case .secureEnclaveUnavailable: return "secure_enclave_unavailable"
    case .keyMissing: return "key_missing"
    case .keyCreationFailed: return "secure_enclave_creation_failed"
    case .keySelfTestFailed: return "secure_enclave_self_test_failed"
    case .publicKeyUnavailable: return "public_key_unavailable"
    case .signatureFailed: return "signature_failed"
    case .invalidSignature: return "invalid_signature"
    case .secretLengthMismatch: return "platform_secret_length_mismatch"
    case .keychainFailure: return "keychain_failure"
    case .nativeFailure: return "native_identity_failure"
    }
  }

  var details: [String: Any] {
    var value: [String: Any] = ["diagnosticCode": diagnosticCode]
    if case .keychainFailure(let status) = self { value["osStatus"] = status }
    if case .missingEntitlement = self { value["osStatus"] = errSecMissingEntitlement }
    return value
  }

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "Invalid protected storage arguments"
    case .identityDisabled:
      return "Trusted identity is disabled for this unsigned build"
    case .missingEntitlement:
      return "The signed app has no provisioning-authorized Keychain access group"
    case .keychainLocked:
      return "The protected system key store is locked"
    case .migrationRequired:
      return "The previous device identity requires explicit replacement"
    case .rootIdentityChanged:
      return "The protected root identity changed"
    case .secureEnclaveUnavailable:
      return "Secure Enclave is unavailable"
    case .keyMissing:
      return "The protected device key is missing"
    case .keyCreationFailed:
      return "Unable to create a Secure Enclave key"
    case .keySelfTestFailed:
      return "Secure Enclave signing self-test failed"
    case .publicKeyUnavailable:
      return "Unable to read the public device key"
    case .signatureFailed:
      return "Unable to sign the authentication message"
    case .invalidSignature:
      return "Invalid P-256 signature"
    case .secretLengthMismatch:
      return "The stored local secret has an unexpected length"
    case .keychainFailure(let status):
      return "Protected system key store failed (OSStatus \(status))"
    case .nativeFailure(let message):
      return message
    }
  }
}
